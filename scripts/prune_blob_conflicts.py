#!/usr/bin/env python3
"""源码优先：把 cannon-vendor.mk 里与 soong 模块撞车的原厂 blob 条目剔除。

规则来源：kati 的 `warning: overriding commands for target ...` ——
PRODUCT_COPY_FILES 的 copy 规则会覆盖 soong 的 install 规则，导致 A17 源码产物
被 A12 blob 顶掉（libbinder / libutils / bin/sh / codec2 ...）。

用法:
  python3 prune_blob_conflicts.py --dry-run     # 只打印
  python3 prune_blob_conflicts.py --apply       # 改写 cannon-vendor.mk
  python3 prune_blob_conflicts.py --list FILE   # 用给定清单（默认取构建日志）

被剔除的条目会集中追加到文件末尾的注释块，便于逐条回滚。
"""
import argparse
import os
import re
import sys

MK = "/cannon/rom/vendor/xiaomi/cannon/cannon-vendor.mk"
LOG = "/cannon/build.log"
MARK = "# ===== [src-over-blob] 以下原厂 blob 与 soong 源码模块同路径，已剔除 ====="
PROPRIETARY = "vendor/xiaomi/cannon/proprietary/"

# 需要保留 blob 的例外（Niclan 用 -v31 改名 + patchelf 解决，见 TODO）
KEEP = {
    "lib/libcodec2_vndk.so",
    "lib64/libcodec2_vndk.so",
    "lib/libcodec2_hidl@1.0.so",
    "lib64/libcodec2_hidl@1.0.so",
}

# 安全剔除白名单：只删这些，其余一律保留。
# 依据 docs/playbooks/A17_BLOB_VS_SOURCE.md §3/§4.2：
#   - AOSP 命令、自建 HAL、AOSP .default.so 实现、3 条 init rc、2 条 wifi VINTF、
#     AOSP 接口库（android.hardware/frameworks/hidl/system，排除 mediatek 专有）。
# 明确不删（曾有事故）：MTK/Xiaomi 专有库（libaedv/libladder/libladder 等）、
# lib*/hw/*-impl.so（温控/音频/相机的 MTK 实现，删了行为会变）、平台库（binder/utils/base…）、
# codec2 全套（需 -v31 改名）。
BIN_SAFE = {
    "bin/sh", "bin/toolbox", "bin/toybox_vendor", "bin/dumpsys", "bin/awk",
    "bin/logwrapper", "bin/vndservice", "bin/vndservicemanager",
    "bin/wlan_assistant", "bin/boringssl_self_test32", "bin/boringssl_self_test64",
    "bin/hw/android.hardware.light-service.cannon",
    "bin/hw/android.hardware.sensors@2.1-service.cannon-multihal",
}
ETC_SAFE = {
    "etc/init/hostapd.android.rc",
    "etc/init/wlan_assistant.rc",
    "etc/init/vndservicemanager.rc",
    "etc/vintf/manifest/android.hardware.wifi.hostapd.xml",
    "etc/vintf/manifest/android.hardware.wifi.supplicant.xml",
}
AOSP_IFACE = re.compile(
    r"^lib(64)?/(android\.(hardware|frameworks|hidl|system)\.[^/]*-?[^/]*\.so|"
    r"[^/]*-V[0-9]+-ndk\.so)$")
AOSP_DEFAULT_IMPL = re.compile(r"^lib(64)?/hw/(.*\.default\.so)$")
MTK_HINT = re.compile(r"mediatek|mtk|xiaomi|libaedv|libladder|ls_client|libmnl|libthha|"
                      r"thermalalgo|thermal_hal|codec2|firmware|thh/|\.tp/|audio_param",
                      re.I)


def safe_to_drop(rel: str) -> bool:
    if rel in KEEP or MTK_HINT.search(rel):
        return False
    # 2026-11-11 实测：这些删掉后源码不会安装到 vendor，运行期 dlopen 会失败：
    #   -NDK 接口库装到 system/apex，不在 vendor；audio.r_submix/usb default 默认不进
    #   vendor；wlan_assistant 是 vendor 私有工具（无源码模块）。
    if re.search(r"-V[0-9]+-ndk\.so$", rel):
        return False
    if re.search(r"audio\.(r_submix|usb)\.default\.so$", rel):
        return False
    if rel in ("bin/wlan_assistant", "etc/init/wlan_assistant.rc"):
        return False
    if rel in BIN_SAFE or rel in ETC_SAFE:
        return True
    if AOSP_DEFAULT_IMPL.match(rel):
        return True
    if AOSP_IFACE.match(rel):
        return True
    return False


def targets_from_log(path):
    if not os.path.exists(path):
        sys.exit("找不到构建日志: %s" % path)
    pat = re.compile(r"overriding commands for target `out/target/product/cannon/vendor/([^']*)'")
    out = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = pat.search(line.replace("\x00", "").replace("\r", ""))
            if m:
                out.add(m.group(1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list")
    a = ap.parse_args()
    if not (a.apply or a.dry_run):
        ap.error("需要 --apply 或 --dry-run")

    if a.list:
        want = {l.strip() for l in open(a.list) if l.strip()}
    else:
        want = targets_from_log(LOG)
    want_all = {w for w in want if w not in KEEP}
    want = {w for w in want_all if safe_to_drop(w)}
    hold = sorted(want_all - want)
    print("冲突目标 %d：可安全剔除 %d，强制保留(MTK/需 -v31/需验证) %d"
          % (len(want_all), len(want), len(hold)))

    lines = open(MK, "r", errors="replace").read().split("\n")
    kept, removed, i = [], [], 0
    dst_re = re.compile(r"\$\(TARGET_COPY_OUT_VENDOR\)/(\S+?)(?:\s|$)")
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        cont = s.endswith("\\")
        body = s[:-1].strip() if cont else s
        src = dst = None
        if body and not body.startswith("#") and ":" in body and not body.startswith("PRODUCT_"):
            src, _, dst = body.partition(":")
            if not dst.startswith("$(TARGET_COPY_OUT_VENDOR)/"):
                src = None
        if src and src.startswith(PROPRIETARY):
            rel = dst.split("$(TARGET_COPY_OUT_VENDOR)/", 1)[1]
            if rel in want:
                removed.append((rel, src, cont))
                if not cont:
                    # 块尾：把它前面幸存行的续行符去掉
                    for k in range(len(kept) - 1, -1, -1):
                        if kept[k].strip():
                            if kept[k].rstrip().endswith("\\"):
                                kept[k] = kept[k].rstrip()[:-1].rstrip()
                            break
                i += 1
                continue
        kept.append(line)
        i += 1

    print("剔除 %d 条" % len(removed))
    if a.dry_run:
        for rel, src, _ in removed[:20]:
            print("  - %s" % rel)
        if len(removed) > 20:
            print("  ... 共 %d" % len(removed))
        return

    # 去掉文件末尾多余空行后追加注释块
    while kept and not kept[-1].strip():
        kept.pop()
    out = kept + ["", MARK]
    for rel, src, _ in sorted(removed):
        out.append("#   %s:%s$(TARGET_COPY_OUT_VENDOR)/%s" % (src, "", rel) if False else
                   "#   %s:$(TARGET_COPY_OUT_VENDOR)/%s" % (src, rel))
    out.append("# ===== [src-over-blob] end =====")
    with open(MK, "w") as f:
        f.write("\n".join(out) + "\n")
    print("已写入 %s" % MK)


if __name__ == "__main__":
    main()
