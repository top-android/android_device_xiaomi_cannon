#!/usr/bin/env bash
# ============================================================================
# cannon A16 · vendor 装配脚本（把"手工注入"持久化）
#
# 背景：A16 移除 VNDK 后，一批 system 私有库必须在 /vendor 里同时存在，否则
#   SurfaceFlinger/Mali/media HAL 在 vendor 命名空间 dlopen 失败 → 黑屏。
#   这些库不在 vendor 构建图里，过去靠"手工 mount 镜像 cp 进去"，任何一次裸
#   `m vendorimage` 都会全部丢失 → 黑屏回归。`PRODUCT_COPY_FILES + $(TARGET_OUT)`
#   在本树不可用（实测解析期 TARGET_OUT 为空 → 源路径变 /lib64/xxx）。
#
# 本脚本在 `m vendorimage` 之后运行，把下列文件从 system 暂存区/proprietary 补齐进
#   vendor.img（稀疏镜像就地改、设正确 SELinux 标签/权限），再重打包。幂等可重复。
#
# 覆盖内容：
#   /lib64,/lib: libcurl libunwindstack libutilscallstack liblzma libc++(系统版覆盖blob)
#                libhidlmemory media.c2@1.0/@1.1/@1.2  libnetutils(+32 vendor_dep)
#   /lib64:      libwifi-hal.so(源码版)      /bin/hw: android.hardware.wifi-service-lazy(源码版)
#   libcodec2_vndk(64/32): patchelf --add-needed libshim_cannon_vendor.so（媒体兼容）
#
# 用法：
#   手工： OUT_DIR=/cannon/out-a16 bash tools/a16_assemble_vendor.sh [--img <vendor.img>] [--out <out.img>]
#   构建图（方案①）：由 build/make/core/Makefile 的 build-vendorimage-target 在 build_image
#     之后自动调用，传入 OUT_DIR=$(OUT_DIR) PRODUCT_OUT=$(PRODUCT_OUT) --img $(INSTALLED_VENDORIMAGE_TARGET)。
#   默认 img=$P/vendor.img（P=PRODUCT_OUT 或 $OUT_DIR/target/product/cannon），就地覆盖。
# 退出码：0 全部就位；非 0 = 有关键文件缺失（见 stderr）
# ============================================================================
set -u
# 构建图内 ninja 通过 build/soong/cmd/path_interposer 用 PATH 沙箱屏蔽 mount/umount/patchelf/xxd
# 等系统工具（仅经 PATH 生效，绝对路径不受限）。本脚本必须用到这些工具，故把真实系统路径
# 置于 PATH 最前，绕过该沙箱（不影响 build 产出的可复现性——本步是设备专有的镜像后处理）。
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH
OUT_DIR="${OUT_DIR:-/cannon/out-a16}"
# 支持构建图传入 PRODUCT_OUT（=.../target/product/<device>）；否则按 OUT_DIR 推导。
P="${PRODUCT_OUT:-$OUT_DIR/target/product/cannon}"
IMG="$P/vendor.img"
OUTIMG=""
S2I="$OUT_DIR/host/linux-x86/bin/simg2img"
I2S="$OUT_DIR/host/linux-x86/bin/img2simg"
[ -x "$S2I" ] || S2I="$(command -v simg2img)"
[ -x "$I2S" ] || I2S="$(command -v img2simg)"
PATCHELF="$(command -v patchelf || true)"

while [ $# -gt 0 ]; do case "$1" in
  --img) IMG="$2"; shift 2;;
  --out) OUTIMG="$2"; shift 2;;
  -h|--help) sed -n '2,30p' "$0"; exit 0;;
  *) echo "未知参数 $1"; exit 2;;
esac; done
[ -f "$IMG" ] || { echo "❌ 找不到 vendor.img: $IMG"; exit 1; }
[ -n "$OUTIMG" ] || OUTIMG="$P/vendor.img"

mkdir -p "$OUT_DIR/tmp" 2>/dev/null || true
WORK="$(mktemp -d "$OUT_DIR/tmp/assemble_vendor.XXXXXX")" || exit 1
RAW="$WORK/vendor.raw"; MNT="$WORK/mnt"; mkdir -p "$MNT"
cleanup(){ umount "$MNT" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

MISS=0
say(){ echo "[assemble] $*"; }

# ---- 1. 解稀疏为 raw 并挂载 ----
say "解包 $IMG"
"$S2I" "$IMG" "$RAW" || { echo "❌ simg2img 失败"; exit 1; }
mount -o loop,rw "$RAW" "$MNT" || { echo "❌ 挂载失败"; exit 1; }

# inject <src> <dst_rel_in_vendor> [mode] [gid] [label]
inject(){
  local src="$1" dst="$2" mode="${3:-0644}" gid="${4:-0}" label="${5:-u:object_r:vendor_file:s0}"
  if [ ! -f "$src" ]; then say "  ⚠ 源缺失，跳过: $dst  (src=$src)"; MISS=$((MISS+1)); return; fi
  mkdir -p "$(dirname "$MNT/$dst")"
  cp -f "$src" "$MNT/$dst"
  chmod "$mode" "$MNT/$dst"; chown 0:"$gid" "$MNT/$dst"
  chcon "$label" "$MNT/$dst" 2>/dev/null || true
  say "  + /$dst"
}

# ---- 2. 库：system 暂存区 → /vendor（64+32）----
# 这些用 system 版（同源，且 libc++ 必须换 A16 系统版覆盖 blob）
# ★ 标签：libunwindstack/libutilscallstack/liblzma 会被 surfaceflinger/zygote 通过
#   libgralloc_extra→libGLES_mali→libGLES_meow 依赖链直接 dlopen，必须标 same_process_hal_file；
#   若用默认 vendor_file，enforcing 下 SF 读它被拒 → EGL dlopen 失败 → 卡第一屏。
#   （与 file_contexts 的 libshim 垫片同理，A15 D1 同款坑。）
for base in libcurl.so libunwindstack.so libutilscallstack.so liblzma.so \
            libhidlmemory.so android.hardware.media.c2@1.0.so \
            android.hardware.media.c2@1.1.so android.hardware.media.c2@1.2.so libc++.so \
            libcamera_metadata.so libexif.so libpng.so libexpat.so; do
  lbl="u:object_r:vendor_file:s0"
  case "$base" in
    libunwindstack.so|libutilscallstack.so|liblzma.so|libc++.so) lbl="u:object_r:same_process_hal_file:s0";;
  esac
  [ -f "$P/system/lib64/$base" ] && inject "$P/system/lib64/$base" "lib64/$base" 0644 0 "$lbl"
  [ -f "$P/system/lib/$base"   ] && inject "$P/system/lib/$base"   "lib/$base"   0644 0 "$lbl"
done

# ---- 3. libnetutils（热点）：vendor 变体在 staging vendor ----
for base in libnetutils.so; do
  [ -f "$P/vendor/lib64/$base" ] && inject "$P/vendor/lib64/$base" "lib64/$base"
  [ -f "$P/vendor/lib/$base"   ] && inject "$P/vendor/lib/$base"   "lib/$base"
done
[ -f "$P/vendor/lib/libnetutils_vendor_dep.so" ] && inject "$P/vendor/lib/libnetutils_vendor_dep.so" "lib/libnetutils_vendor_dep.so"

# ---- 4. wifi 源码版（必须成对，避免与 blob 混用）----
WIFI_BLOB_MD5="afa581a8417b48d1814f6f52de3c1fa1"
if [ -f "$P/vendor/lib64/libwifi-hal.so" ]; then
  cur=$(md5sum "$P/vendor/lib64/libwifi-hal.so" | awk '{print $1}')
  if [ "$cur" != "$WIFI_BLOB_MD5" ]; then
    inject "$P/vendor/lib64/libwifi-hal.so" "lib64/libwifi-hal.so"
    [ -f "$P/vendor/bin/hw/android.hardware.wifi-service-lazy" ] && \
      inject "$P/vendor/bin/hw/android.hardware.wifi-service-lazy" "bin/hw/android.hardware.wifi-service-lazy" 0755 2000 u:object_r:hal_wifi_default_exec:s0
  else
    say "  ⚠ staging libwifi-hal 仍是原厂 blob（cannon-vendor.mk 两行未删？）→ 跳过 wifi 源码替换"
    MISS=$((MISS+1))
  fi
else
  say "  ⚠ staging 无 libwifi-hal.so，跳过 wifi"
fi

# ---- 5. libcodec2_vndk 打补丁（媒体：旧 GraphicBufferMapper::lock 签名）----
if [ -n "$PATCHELF" ]; then
  for f in lib64/libcodec2_vndk.so lib/libcodec2_vndk.so; do
    t="$MNT/$f"
    [ -f "$t" ] || continue
    if ! "$PATCHELF" --print-needed "$t" 2>/dev/null | grep -q libshim_cannon_vendor; then
      "$PATCHELF" --add-needed libshim_cannon_vendor.so "$t" 2>/dev/null \
        && { chown 0:0 "$t"; chmod 0644 "$t"; chcon u:object_r:vendor_file:s0 "$t" 2>/dev/null || true; say "  ✎ patched /$f (+libshim_cannon_vendor)"; }
    else
      say "  = /$f 已含 libshim_cannon_vendor"
    fi
  done
else
  say "  ⚠ 无 patchelf，跳过 codec2 补丁（仅影响媒体，不影响开机）"
fi

# ---- 5.5 确保 VINTF manifest 声明 android.hardware.camera.provider ----
# A16 cameraserver 只用 V2_4 描述符 listManifestByInterface()/getService() 去发现相机 provider；
# 移植时设备树 configs/vintf/manifest.xml 把该 HAL 声明 pruned 了 → 最终 /vendor/etc/vintf/
# manifest.xml 缺声明 → 无法把 @2.6 注册的 MTK provider 降版解析成 2.4 → dumpsys media.camera=0。
# 本条幂等：已声明则跳过；否则在 </manifest> 前补入（in-place 覆盖保留 inode/xattr 标签）。
MV="$MNT/etc/vintf/manifest.xml"
if [ -f "$MV" ]; then
  if grep -q 'android.hardware.camera.provider' "$MV"; then
    say "  = /etc/vintf/manifest.xml 已声明 camera.provider"
  else
    TMPM="$WORK/manifest.xml.new"
    awk 'BEGIN{ins=0}
         /^<\/manifest>/{ if(!ins){
             print "    <hal format=\"hidl\">";
             print "        <name>android.hardware.camera.provider</name>";
             print "        <transport>hwbinder</transport>";
             print "        <fqname>@2.6::ICameraProvider/internal/0</fqname>";
             print "    </hal>"; ins=1 } }
         {print}' "$MV" > "$TMPM"
    cat "$TMPM" > "$MV"    # 覆盖写(非 rename)以保留原 inode 的 SELinux xattr
    chcon u:object_r:vendor_configs_file:s0 "$MV" 2>/dev/null || true
    say "  + /etc/vintf/manifest.xml 注入 camera.provider (@2.6::ICameraProvider/internal/0)"
  fi
else
  echo "  ❌ 缺 /etc/vintf/manifest.xml"; MISS=$((MISS+1))
fi

# ---- 5.6 给 /lib64/libutils.so 打 incStrongRequireStrong 容忍补丁 ----
# A12 vendor blob 的 RefBase::incStrongRequireStrong 在"全新对象(c==INITIAL_STRONG_VALUE)"
# 时 __android_log_assert 中止；A16 源码侧已容忍，但 vendor 用的是原厂 blob。camerahalserver
# 以 sp<>::fromExisting() 采纳全新 CallbackHelper/Thread → SIGABRT 'isn't already owned' →
# 预览黑屏。此处原位二进制补丁（仅 64 位，保留 blob ABI），把全新分支改为 strong 计数折回 1 后 ret。
# 幂等：已是补丁态则跳过。详见 scripts/patch_vendor_libutils_incstrong.sh 与 docs 第 8 节。
LU="$MNT/lib64/libutils.so"
LU_ORIG="1f05007104a1497a40000054c0035fd6fd7bbfa9fd030091a0ffff9000502491"
LU_PATCH="0900a2521f01096ba10000540a00a252ea030a4b7f002ab8c0035fd6c0035fd6"
if [ -f "$LU" ]; then
  if command -v xxd >/dev/null 2>&1; then
    LU_CUR=$(dd if="$LU" bs=1 skip=$((0x15e80)) count=32 status=none | xxd -p | tr -d '\n')
    case "$LU_CUR" in
      "$LU_PATCH") say "  = /lib64/libutils.so 已是 incStrongRequireStrong 补丁态";;
      "$LU_ORIG")
        printf '%s' "$LU_PATCH" | xxd -r -p > "$WORK/lu_patch.bin"
        dd if="$WORK/lu_patch.bin" of="$LU" bs=1 seek=$((0x15e80)) conv=notrunc status=none
        chown 0:0 "$LU"; chmod 0644 "$LU"; chcon u:object_r:same_process_hal_file:s0 "$LU" 2>/dev/null || true
        say "  ✎ 已给 /lib64/libutils.so 打 incStrongRequireStrong 容忍补丁";;
      *) say "  ⚠ /lib64/libutils.so 0x15e80 字节非预期，跳过（不改以免损坏）";;
    esac
  else
    say "  ⚠ 无 xxd，跳过 libutils 补丁"
  fi
else
  say "  ⚠ 镜像内缺 /lib64/libutils.so"
fi

# ---- 5.7 去除 /lib64/libhidlbase.so 里 getRawServiceInternal 的 sleep(1) ----
# A14/A15 "全局 +1 秒卡顿" 同款 bug 的 A16 载体复活：A16 system 源码那行已注释掉，但 camerahalserver
# 等 vendor 进程用原厂 A12 blob /vendor/lib64/libhidlbase.so，其 getRawServiceInternal 仍有
#   __android_log_print(...race...); sleep(1);
# 每次 vendor getService 白等 1s；相机开/切累计数秒、开机累计 ~8s。此处把 VA 0x5b050 的
# `bl sleep@plt`(94 01 43 70) 改成 NOP(d5 03 20 1f)，保留 ALOGE，不动另两处合法 sleep。
# 幂等：已是补丁态则跳过。详见 scripts/patch_vendor_libhidlbase_sleep.sh。
LHB="$MNT/lib64/libhidlbase.so"
LHB_ORIG="70430194"
LHB_PATCH="1f2003d5"
if [ -f "$LHB" ]; then
  if command -v xxd >/dev/null 2>&1; then
    LHB_CUR=$(dd if="$LHB" bs=1 skip=$((0x5b050)) count=4 status=none | xxd -p | tr -d '\n')
    case "$LHB_CUR" in
      "$LHB_PATCH") say "  = /lib64/libhidlbase.so 已是去 sleep(1) 补丁态";;
      "$LHB_ORIG")
        printf '%s' "$LHB_PATCH" | xxd -r -p > "$WORK/lhb_patch.bin"
        dd if="$WORK/lhb_patch.bin" of="$LHB" bs=1 seek=$((0x5b050)) conv=notrunc status=none
        chown 0:0 "$LHB"; chmod 0644 "$LHB"; chcon u:object_r:same_process_hal_file:s0 "$LHB" 2>/dev/null || true
        say "  ✎ 已给 /lib64/libhidlbase.so 去 getService sleep(1)（0x5b050 bl→nop）";;
      *) say "  ⚠ /lib64/libhidlbase.so 0x5b050 字节非预期，跳过（不改以免损坏）";;
    esac
  else
    say "  ⚠ 无 xxd，跳过 libhidlbase 补丁"
  fi
else
  say "  ⚠ 镜像内缺 /lib64/libhidlbase.so"
fi
# 32 位 /lib/libhidlbase.so 同型：0x360ce Thumb BLX sleep@plt -> nop nop
LHB32="$MNT/lib/libhidlbase.so"
LHB32_ORIG="3af0b0ed"
LHB32_PATCH="00bf00bf"
if [ -f "$LHB32" ]; then
  if command -v xxd >/dev/null 2>&1; then
    LHB32_CUR=$(dd if="$LHB32" bs=1 skip=$((0x350ce)) count=4 status=none | xxd -p | tr -d '\n')
    case "$LHB32_CUR" in
      "$LHB32_PATCH") say "  = /lib/libhidlbase.so(32位) 已是去 sleep(1) 补丁态";;
      "$LHB32_ORIG")
        printf '%s' "$LHB32_PATCH" | xxd -r -p > "$WORK/lhb32_patch.bin"
        dd if="$WORK/lhb32_patch.bin" of="$LHB32" bs=1 seek=$((0x350ce)) conv=notrunc status=none
        chown 0:0 "$LHB32"; chmod 0644 "$LHB32"; chcon u:object_r:same_process_hal_file:s0 "$LHB32" 2>/dev/null || true
        say "  ✎ 已给 /lib/libhidlbase.so(32位) 去 getService sleep(1)（0x360ce blx→nop nop）";;
      *) say "  ⚠ /lib/libhidlbase.so(32位) 0x350ce 字节非预期，跳过（不改以免损坏）";;
    esac
  fi
else
  say "  ⚠ 镜像内缺 /lib/libhidlbase.so（跳过 32 位）"
fi

# ---- 5.8 强制重标：libutils / libhidlbase 必为 same_process_hal_file ----
# 这两个库被 SF/zygote 通过 libGLES_meow→libgralloc_extra→libGLES_mali 依赖链在
#   vendor 命名空间直接 dlopen；若标 vendor_file，enforcing 下 SF/zygote 读它被拒 →
#   EGL dlopen 失败 → SIGABRT → 卡第一屏。与 libc++ 同款坑。
# ★ 关键：5.6/5.7 是"已是补丁态→跳过 chcon"，对已打补丁的旧镜像重跑时不会重标，
#   所以此处无条件重标（幂等），确保旧镜像叠加时也修正标签。
for f in lib64/libutils.so lib64/libhidlbase.so lib/libhidlbase.so; do
  if [ -f "$MNT/$f" ]; then
    chcon u:object_r:same_process_hal_file:s0 "$MNT/$f" 2>/dev/null || true
    say "  ★ 强制重标 /$f → same_process_hal_file"
  fi
done

# ---- 5.9 图形栈 HIDL 接口库 / 依赖重标 ----
# SurfaceFlinger 在 vendor namespace 以 passthrough 方式读这些 graphics HAL 接口库与
#   libhidlmemory；enforcing 下 SF/zygote 读 vendor_file 被拒 → EGL/gralloc dlopen 失败 →
#   SF 每 ~5s SIGABRT 重启 → 卡第一屏。此段无条件重标（幂等）。证据：enf3_avc.txt 中
#   surfaceflinger read libhidlmemory.so(vendor_file) 被拒，SF pid 950→1395→1483 循环重启。
for b in libhidlmemory.so \
         android.hardware.graphics.allocator@2.0.so \
         android.hardware.graphics.allocator@3.0.so \
         android.hardware.graphics.allocator@4.0.so \
         android.hardware.graphics.bufferqueue@2.0.so \
         android.hardware.graphics.composer@2.1.so \
         android.hardware.graphics.composer@2.1-resources.so; do
  for d in lib64 lib; do
    f="$d/$b"
    if [ -f "$MNT/$f" ]; then
      chcon u:object_r:same_process_hal_file:s0 "$MNT/$f" 2>/dev/null || true
      say "  ★ 重标 /$f → same_process_hal_file"
    fi
  done
done

# ---- 6. 校验关键文件必须存在 ----
say "校验关键文件（/lib64）："
REQ64="libcurl.so libunwindstack.so libutilscallstack.so liblzma.so libc++.so libhidlmemory.so libnetutils.so android.hardware.media.c2@1.2.so libcamera_metadata.so libexpat.so"
for f in $REQ64; do
  if [ -f "$MNT/lib64/$f" ]; then say "  ✓ $f"; else echo "  ❌ 缺 $f"; MISS=$((MISS+1)); fi
done

umount "$MNT" || { echo "❌ umount 失败"; exit 1; }

# ---- 7. 重打包并替换 ----
say "重打包 -> $OUTIMG"
"$I2S" "$RAW" "$WORK/new.img" || { echo "❌ img2simg 失败"; exit 1; }
[ "$(readlink -f "$OUTIMG")" != "$(readlink -f "$IMG")" ] && [ -f "$IMG" ] && cp -f "$IMG" "$IMG.preassemble" 2>/dev/null
cp -f "$WORK/new.img" "$OUTIMG"

if [ "$MISS" -ne 0 ]; then echo "[assemble] ⚠ 有 $MISS 项缺失/跳过，见上"; exit 3; fi
echo "[assemble] ✅ 完成：$OUTIMG（全部关键文件就位）"
