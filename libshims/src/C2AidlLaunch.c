/*
 * [cannon][A17] 以 mediacodec 域启动 codec2 AIDL 服务。
 *
 * 为什么需要它：服务不是由 init 拉起的（Magisk 模块无法新增 init service，
 * init 在 Magisk 挂载模块之前就解析完 rc 了），而是 service.sh 以 root 启动。
 * 直接用 runcon 的话 LD_PRELOAD 会作用到 runcon 自己（system 二进制进不了
 * vendor 命名空间）；用 shell 包一层又会因为 mediacodec 的
 * neverallow execute_no_trans 失败。
 *
 * 这个 launcher 做四件事：设好 LD_PRELOAD → setexeccon(mediacodec) →
 * 降到厂商 HAL 的 uid/gid → exec。
 *
 * 为什么要降 uid：/dev/video* 是 media:system 0660，而 mediacodec 域没有
 * capability dac_override。以 root 跑（gid 0）照样 EACCES，MTK vdec 枚举
 * 设备时打不开任何节点 → initVCodec failed → 硬解组件全部消失。
 * 厂商 HIDL HAL（/vendor/etc/init/android.hardware.media.c2@1.2-mediatek.rc）
 * 用的是 user mediacodec + 一串 group，这里照抄它的实际 uid/gid（取自
 * /proc/<pid>/status）：uid 1046、gid 1006、补充组见 kGroups。
 */
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
#include <selinux/selinux.h>

#define AID_MEDIA_CODEC 1046 /* mediacodec 用户 */
#define AID_CAMERA 1006      /* 主组（init 取 group 列表第一个） */

/* 与厂商 HAL 进程 /proc/<pid>/status 的 Groups 完全一致 */
static const gid_t kGroups[] = {
    1000, /* system */
    1005, /* audio */
    1013, /* media */
    1015, /* sdcard_rw */
    1023, /* media_rw */
    1026, /* drmrpc */
    1028, /* sdcard_r */
    1031, /* mediadrm */
    3001, /* net_bt_admin */
    3002, /* net_bt */
    3003, /* inet */
    3007, /* net_bw_acct */
};

int main(int argc, char **argv) {
    (void)argc;
    /* 基础 preload；C2AIDL_EXTRA_PRELOAD 可追加一个（用于把打过补丁的
     * libstagefright_foundation.so 只注入本进程，做单进程验证）。 */
    const char *base =
            "/vendor/lib64/libshim_no_vintf.so:"
            "/vendor/lib64/libc2_bq_stub.so:"
            "/vendor/lib64/libshim_gbm_only.so:"
            "/vendor/lib64/libshim_dmabuf_alloc.so";
    const char *extra = getenv("C2AIDL_EXTRA_PRELOAD");
    if (extra != NULL && extra[0] != '\0') {
        static char buf[1024];
        snprintf(buf, sizeof(buf), "%s:%s", base, extra);
        setenv("LD_PRELOAD", buf, 1);
    } else {
        setenv("LD_PRELOAD", base, 1);
    }
    /* 先设 exec 上下文：此时还在 magisk 域，有权限写 /proc/self/attr/exec */
    if (setexeccon("u:r:mediacodec:s0") < 0) {
        perror("setexeccon");
    }
    if (setgroups(sizeof(kGroups) / sizeof(kGroups[0]), kGroups) < 0) {
        perror("setgroups");
    }
    if (setgid(AID_CAMERA) < 0) {
        perror("setgid");
    }
    if (setuid(AID_MEDIA_CODEC) < 0) {
        perror("setuid");
    }
    execv("/vendor/bin/hw/android.hardware.media.c2-default-service", argv);
    perror("execv");
    return 1;
}
