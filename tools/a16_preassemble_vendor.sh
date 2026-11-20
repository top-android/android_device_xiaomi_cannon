#!/usr/bin/env bash
# ============================================================================
# cannon A16 · vendor staging 预装配（build 图内、**不用 mount**）
#
# 背景：A16 去 VNDK 后，一批 system 私有库必须在 /vendor 里同时存在，否则
#   SurfaceFlinger/media HAL 在 vendor 命名空间 dlopen 失败 → 黑屏。
#   旧方案 a16_assemble_vendor.sh 是"出镜像后 mount 灌库"，但 build 图的 ninja
#   跑在 nsjail user+mount namespace 里（实测 uid=65534(nobody)、capEff=0），
#   内核禁止 user namespace 内 loop mount → mount 版无法在 build 内运行。
#
# 本脚本改在 build_image **之前**运行：
#   1) 把 system staging 的库直接拷进 vendor staging（$P/vendor）；
#   2) 就地对 vendor blob（libutils / libhidlbase / libcodec2_vndk）打二进制补丁；
#   2b) libcutils.so 用 system 版覆盖 blob：V13 blob 缺 uevent_create_socket 等
#       新符号，health-service.mediatek(AIDL) 链接失败 → system_server 卡死在
#       BatteryService 等 AIDL IHealth。
#   3) 把新增文件的相对路径追加进 file_list.txt；
#   4) 幂等补 /etc/vintf/manifest.xml 的 camera.provider 声明。
#   随后 build_image 一并打包，并由 file_contexts.bin **自动赋予正确 SELinux 标签**
#   —— 无需 chcon/chown/root（这些在沙箱内本就没有权限，且不该做）。
#
# 用法：
#   构建图（由 Makefile build-vendorimage-target 调）：
#     OUT_DIR=... PRODUCT_OUT=... a16_preassemble_vendor.sh <file_list.txt>
#   手工：
#     OUT_DIR=/cannon/out-a16 PRODUCT_OUT=/cannon/out-a16/target/product/cannon \
#       bash tools/a16_preassemble_vendor.sh <file_list.txt>
# 退出码：0 全部就位；非 0 = 关键文件缺失
# ============================================================================
set -u
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH
OUT_DIR="${OUT_DIR:-/cannon/out-a16}"
P="${PRODUCT_OUT:-$OUT_DIR/target/product/cannon}"
STG="$P/vendor"
FL="${1:-$OUT_DIR/target/product/cannon/obj/PACKAGING/vendor_intermediates/file_list.txt}"
PATCHELF="$(command -v patchelf || true)"

[ -d "$STG" ] || { echo "[preasm] ❌ staging 不存在: $STG"; exit 1; }
[ -f "$FL" ]  || { echo "[preasm] ❌ file_list 不存在: $FL"; exit 1; }

# [cannon][A17] 清除 V13 残留的 vendor linker.config.pb：其 provideLibs
# (libcamera_metadata.so) 与 system provideLibs 在 [system] 段造成
# "duplicate provider" → linkerconfig LOG(FATAL) → 开机无 ld.config →
# 全部 APEX 库加载失败。V14 上游已无此文件。
rm -f "$P/vendor/etc/linker.config.pb"
sed -i "/linker.config.pb/d" "$FL"
echo "[preasm] 已清除 V13 残留 linker.config.pb（staging+file_list）"

MISS=0
say(){ echo "[preasm] $*"; }
WORK="$(mktemp -d /tmp/preasm.XXXXXX)" || { echo "mktemp 失败"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

fl_add(){ if ! grep -qxF "$1" "$FL" 2>/dev/null; then echo "$1" >> "$FL"; say "  +filelist $1"; fi; }

# 从 system staging 拷库到 vendor staging，并登记 file_list（64/32 各按存在性）
put_sys(){
  local b="$1" d s
  for d in lib64 lib; do
    s="$P/system/$d/$b"
    [ -f "$s" ] || continue
    mkdir -p "$STG/$d"
    cp -f "$s" "$STG/$d/$b"
    fl_add "$d/$b"
    say "  +/$d/$b ← system"
  done
}

# ---- 1. 库：system → vendor staging（含 media.c2 / libc++ 用 A16 system 版覆盖 blob）----
for b in libcurl.so libunwindstack.so libutilscallstack.so liblzma.so \
         libhidlmemory.so android.hardware.media.c2@1.0.so \
         android.hardware.media.c2@1.1.so android.hardware.media.c2@1.2.so \
         libc++.so libcamera_metadata.so libexif.so libpng.so libexpat.so \
         libcutils.so; do
  put_sys "$b"
done

# ---- 2. libutils.so incStrongRequireStrong 容忍补丁（staging blob，原位二进制）----
LU="$STG/lib64/libutils.so"
LU_ORIG="1f05007104a1497a40000054c0035fd6fd7bbfa9fd030091a0ffff9000502491"
LU_PATCH="0900a2521f01096ba10000540a00a252ea030a4b7f002ab8c0035fd6c0035fd6"
if [ -f "$LU" ]; then
  if command -v xxd >/dev/null 2>&1; then
    cur=$(dd if="$LU" bs=1 skip=$((0x15e80)) count=32 status=none | xxd -p | tr -d '\n')
    case "$cur" in
      "$LU_PATCH") say "  = libutils 已是 incStrong 补丁态";;
      "$LU_ORIG")
        printf '%s' "$LU_PATCH" | xxd -r -p > "$WORK/lu.bin"
        dd if="$WORK/lu.bin" of="$LU" bs=1 seek=$((0x15e80)) conv=notrunc status=none
        say "  ✎ libutils 打 incStrong 容忍补丁";;
      *) say "  ⚠ libutils 0x15e80 非预期，跳过（不改以免损坏）";;
    esac
  else say "  ⚠ 无 xxd，跳过 libutils 补丁"; MISS=$((MISS+1)); fi
else say "  ⚠ staging 缺 lib64/libutils.so"; MISS=$((MISS+1)); fi

# ---- 3. libhidlbase.so 去 getService sleep(1)（64:0x5b050 bl→nop；32:0x350ce blx→nop nop）----
patch_bytes(){
  local f="$1" off="$2" orig="$3" pat="$4"
  [ -f "$f" ] || return 0
  command -v xxd >/dev/null 2>&1 || { say "  ⚠ 无 xxd"; return 0; }
  local cur; cur=$(dd if="$f" bs=1 skip=$((off)) count=$(( ${#orig} / 2 )) status=none | xxd -p | tr -d '\n')
  case "$cur" in
    "$pat") say "  = $(basename "$f")@0x$(printf %x "$off") 已补丁态";;
    "$orig") printf '%s' "$pat" | xxd -r -p > "$WORK/p.bin"; dd if="$WORK/p.bin" of="$f" bs=1 seek=$((off)) conv=notrunc status=none; say "  ✎ $(basename "$f")@0x$(printf %x "$off") 打补丁";;
    *) say "  ⚠ $(basename "$f")@0x$(printf %x "$off") 非预期，跳过";;
  esac
}
patch_bytes "$STG/lib64/libhidlbase.so" $((0x5b050)) "70430194" "1f2003d5"
patch_bytes "$STG/lib/libhidlbase.so"   $((0x350ce)) "3af0b0ed" "00bf00bf"

# ---- 4. libcodec2_vndk patchelf --add-needed libshim_cannon_vendor.so ----
if [ -n "$PATCHELF" ]; then
  for f in lib64/libcodec2_vndk.so lib/libcodec2_vndk.so; do
    t="$STG/$f"; [ -f "$t" ] || continue
    if ! "$PATCHELF" --print-needed "$t" 2>/dev/null | grep -q libshim_cannon_vendor; then
      "$PATCHELF" --add-needed libshim_cannon_vendor.so "$t" 2>/dev/null && say "  ✎ patched /$f (+libshim_cannon_vendor)" || say "  ⚠ patchelf 失败 /$f"
    else say "  = /$f 已含 libshim_cannon_vendor"; fi
  done
else say "  ⚠ 无 patchelf，跳过 codec2 补丁（不影响开机）"; fi

# ---- 5. /etc/vintf/manifest.xml 幂等补 camera.provider ----
MV="$STG/etc/vintf/manifest.xml"
if [ -f "$MV" ]; then
  if grep -q 'android.hardware.camera.provider' "$MV"; then
    say "  = manifest.xml 已声明 camera.provider"
  else
    awk 'BEGIN{ins=0} /^<\/manifest>/{ if(!ins){ print "    <hal format=\"hidl\">"; print "        <name>android.hardware.camera.provider</name>"; print "        <transport>hwbinder</transport>"; print "        <fqname>@2.6::ICameraProvider/internal/0</fqname>"; print "    </hal>"; ins=1 } } {print}' "$MV" > "$WORK/manifest.new"
    cat "$WORK/manifest.new" > "$MV"
    say "  + manifest.xml 注入 camera.provider"
  fi
else say "  ⚠ staging 缺 etc/vintf/manifest.xml"; MISS=$((MISS+1)); fi

# ---- 6. 校验关键文件在 staging 就位 ----
say "校验 staging 关键文件(/lib64)："
for f in libcurl.so libunwindstack.so libutilscallstack.so liblzma.so libc++.so \
         libhidlmemory.so android.hardware.media.c2@1.2.so libcamera_metadata.so libexpat.so; do
  [ -f "$STG/lib64/$f" ] && say "  ✓ $f" || { echo "  ❌ 缺 $f"; MISS=$((MISS+1)); }
done

if [ "$MISS" -ne 0 ]; then echo "[preasm] ⚠ 有 $MISS 项缺失/跳过（见上）"; exit 3; fi
echo "[preasm] ✅ 完成：staging 预装配就位，file_list 已登记（build_image 将自动打标签）"
