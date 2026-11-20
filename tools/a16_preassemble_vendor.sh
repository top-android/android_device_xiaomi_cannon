#!/usr/bin/env bash
# ============================================================================
# cannon · vendor staging 预装配（build 图内、**不用 mount**）
#
# 背景：A16 去 VNDK 后，build 图的 ninja 跑在 nsjail user+mount namespace 里
#   （实测 uid=65534(nobody)、capEff=0），内核禁止 user namespace 内 loop mount，
#   所以"出镜像后 mount 灌库"的方案在 build 内跑不了。
#   本脚本改在 build_image **之前**运行，直接改 staging 目录。
#
# [cannon][A17][2026-11-21] 精简后只剩三件事（其余都已被源码化取代）：
#   1) 删掉 /vendor/etc/linker.config.pb
#      —— 这是 soong 的 vendor android_filesystem(Gen_linker_config=true) 自动生成的，
#         内容只有一行 provideLibs: libcamera_metadata.so。而 /system/etc/linker.config.pb
#         的 provideLibs 里也有 libcamera_metadata.so，于是 system 段里 system 和 sphal
#         两个 namespace 同时 provide 同一个库 → linkerconfig 在 Section::Resolve() 里
#         LOG(FATAL) "duplicate: libcamera_metadata.so is provided by ..."
#         → 没有 ld.config.txt → 所有 APEX 库加载失败 → 开不了机。
#         而 /vendor 又必须留 libcamera_metadata.so（一堆 MTK camera blob DT_NEEDED 它）。
#   2) libc++.so 用 system 版覆盖 blob
#      —— soong 的 vendor 变体是精简版（nm -D 2159 vs system 2331，缺 std::filesystem /
#         std::pmr / __cxa_* 等），而 AOSP 自己编的 vendor 二进制（vndservicemanager、
#         graphics.composer 服务等）是按完整 libc++ 链接的 → "cannot locate symbol"，
#         287 个 vendor 二进制全部加载失败，adbd 都起不来。MTK blob 是按精简版链的，
#         所以 /vendor 只能放完整的 system 版。
#   3) /etc/vintf/manifest.xml 幂等补 camera.provider 声明（防 blob manifest 缺项）
#
#   已删除（2026-11-21）：libutils/libhidlbase 二进制补丁、libcodec2_vndk patchelf、
#   以及 libcurl/libexpat/libpng/liblzma/libexif/libunwindstack/libutilscallstack/
#   libhidlmemory/libcutils/media.c2@1.x/libcamera_metadata 的 system 版覆盖
#   —— 这些库已通过 device/xiaomi/cannon/Android.bp 的 cannon_vendor_src_deps_* 桩
#      走源码构建进 /vendor，symbol 与 system 版一致，再覆盖就是白忙。
#
# 用法：
#   构建图（由 Makefile build-vendorimage-target 调）：
#     OUT_DIR=... PRODUCT_OUT=... a16_preassemble_vendor.sh <file_list.txt>
# 退出码：0 全部就位；非 0 = 关键文件缺失
# ============================================================================
set -u
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH
OUT_DIR="${OUT_DIR:-/cannon/out-user}"
P="${PRODUCT_OUT:-$OUT_DIR/target/product/cannon}"
STG="$P/vendor"
FL="${1:-$OUT_DIR/target/product/cannon/obj/PACKAGING/vendor_intermediates/file_list.txt}"

[ -d "$STG" ] || { echo "[preasm] ❌ staging 不存在: $STG"; exit 1; }
[ -f "$FL" ]  || { echo "[preasm] ❌ file_list 不存在: $FL"; exit 1; }

MISS=0
say(){ echo "[preasm] $*"; }
WORK="$(mktemp -d /tmp/preasm.XXXXXX)" || { echo "mktemp 失败"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

fl_add(){ if ! grep -qxF "$1" "$FL" 2>/dev/null; then echo "$1" >> "$FL"; say "  +filelist $1"; fi; }

# ---- 1. 清除 soong 生成的 vendor linker.config.pb（重复 provideLibs → linkerconfig FATAL）----
if [ -f "$P/vendor/etc/linker.config.pb" ]; then
  rm -f "$P/vendor/etc/linker.config.pb"
  sed -i "/^etc\/linker.config.pb$/d" "$FL"
  say "已清除 vendor/etc/linker.config.pb（staging+file_list）"
else
  say "= vendor/etc/linker.config.pb 不存在，跳过"
fi

# ---- 2. libc++.so：system 版覆盖 vendor blob ----
for d in lib64 lib; do
  s="$P/system/$d/libc++.so"
  [ -f "$s" ] || continue
  mkdir -p "$STG/$d"
  cp -f "$s" "$STG/$d/libc++.so"
  fl_add "$d/libc++.so"
  say "  +/$d/libc++.so ← system（完整版，替换 vendor 精简 blob）"
done
[ -f "$STG/lib64/libc++.so" ] || { echo "[preasm] ❌ staging 缺 lib64/libc++.so"; MISS=$((MISS+1)); }

# ---- 3. /etc/vintf/manifest.xml 幂等补 camera.provider ----
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

if [ "$MISS" -ne 0 ]; then echo "[preasm] ⚠ 有 $MISS 项缺失/跳过（见上）"; exit 3; fi
echo "[preasm] ✅ 完成：staging 预装配就位，file_list 已登记（build_image 将自动打标签）"
