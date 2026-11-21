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

# ---- 2.5 libcamera_metadata.so：必须用 system 版（LLNDK）----
# [cannon][A17][2026-11-21] libcamera_metadata 是 LLNDK 库，vendor 里那份必须和
# system 里那份逐字节相同。源码构建的 vendor 变体只有 41KB（system 版 90KB），
# cameraserver 解析 HAL 传回的 static metadata 会失败（"Not initialized"），
# 相机 app 直接卡死。所以这里强制用 system 版覆盖 staging。
for d in lib64 lib; do
  s="$P/system/$d/libcamera_metadata.so"
  [ -f "$s" ] || continue
  mkdir -p "$STG/$d"
  cp -f "$s" "$STG/$d/libcamera_metadata.so"
  fl_add "$d/libcamera_metadata.so"
  say "  +/$d/libcamera_metadata.so ← system（LLNDK，必须与 system 一致）"
done
[ -f "$STG/lib64/libcamera_metadata.so" ] || { echo "[preasm] ❌ staging 缺 lib64/libcamera_metadata.so"; MISS=$((MISS+1)); }

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


# ---- 4. blob / 预编译件覆盖 staging（原 PRODUCT_COPY_FILES 迁移至此）----
# 这些路径 soong 也会装一份 vendor 变体，两条 make 规则抢同一 target 会刷一堆
# "overriding commands for target" 警告。改成 build_image 前在这里覆盖：
# 最终字节与原来的 COPY 结果一致，警告消失。
ROOT="${SRC_ROOT:-/cannon/rom}"
DEV="$ROOT/device/xiaomi/cannon"
put() {
  src="$1"; dst="$2"
  if [ ! -f "$src" ]; then echo "[preasm] ❌ 源缺失: $src"; MISS=$((MISS+1)); return; fi
  mkdir -p "$STG/$(dirname "$dst")"
  cp -f "$src" "$STG/$dst"
  fl_add "$dst"
}
put "$DEV/prebuilts/c2aidl/android.hardware.media.c2-default-seccomp_policy" "etc/seccomp_policy/android.hardware.media.c2-default-seccomp_policy"
put "$DEV/prebuilts/c2aidl/libcodec2_aidl.so" "lib64/libcodec2_aidl.so"
put "$DEV/prebuilts/c2aidl/libcodec2_vndk.so" "lib64/libcodec2_vndk.so"
put "$DEV/prebuilts/c2aidl/libcodec2_hidl_plugin.so" "lib64/libcodec2_hidl_plugin.so"
put "$DEV/prebuilts/c2aidl/libstagefright_bufferqueue_helper.so" "lib64/libstagefright_bufferqueue_helper.so"
put "$DEV/prebuilts/c2aidl/libstagefright_foundation.so" "lib64/libstagefright_foundation.so"
put "$ROOT/prebuilts/vndk/v32/arm64/arch-arm-armv8-a/shared/vndk-sp/libutils.so" "lib/libutils-v32.so"
put "$ROOT/prebuilts/vndk/v32/arm64/arch-arm64-armv8-a/shared/vndk-sp/libutils.so" "lib64/libutils-v32.so"
put "$ROOT/device/xiaomi/cannon/prebuilt/lib64/pixel-power-ext-V1-ndk.so" "lib64/pixel-power-ext-V1-ndk.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/etc/init/hostapd.android.rc" "etc/init/hostapd.android.rc"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/etc/init/wlan_assistant.rc" "etc/init/wlan_assistant.rc"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/ls_client.so" "lib/ls_client.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libmnl.so" "lib64/libmnl.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/ls_client.so" "lib64/ls_client.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/etc/init/vndservicemanager.rc" "etc/init/vndservicemanager.rc"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/android.hardware.bluetooth.audio-impl.so" "lib64/android.hardware.bluetooth.audio-impl.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/ese_spi_nxp.so" "lib64/ese_spi_nxp.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/nfc_nci_nxp.so" "lib64/nfc_nci_nxp.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/android.hardware.audio@7.0-util.so" "lib/android.hardware.audio@7.0-util.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/hw/android.hardware.audio@7.0-impl.so" "lib/hw/android.hardware.audio@7.0-impl.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libmedia_omx.so" "lib/libmedia_omx.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libprotobuf-cpp-lite-21.12.so" "lib/libprotobuf-cpp-lite-21.12.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libstagefright_omx.so" "lib/libstagefright_omx.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libstagefright_omx_utils.so" "lib/libstagefright_omx_utils.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libstagefright_xmlparser.so" "lib/libstagefright_xmlparser.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/vendor.xiaomi.hardware.mlipay@1.1.so" "lib/vendor.xiaomi.hardware.mlipay@1.1.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libcodec2_hidl@1.0.so" "lib64/libcodec2_hidl@1.0.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libcodec2_hidl@1.0.so" "lib/libcodec2_hidl@1.0.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libcodec2_hidl@1.1.so" "lib64/libcodec2_hidl@1.1.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libcodec2_hidl@1.1.so" "lib/libcodec2_hidl@1.1.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libcodec2_hidl@1.2.so" "lib64/libcodec2_hidl@1.2.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libcodec2_hidl@1.2.so" "lib/libcodec2_hidl@1.2.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libtinyxml2.so" "lib64/libtinyxml2.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libtinyxml2.so" "lib/libtinyxml2.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libprocessgroup.so" "lib64/libprocessgroup.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib64/libpcap.so" "lib64/libpcap.so"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/lib/libpcap.so" "lib/libpcap.so"
# installable:false 的 HAL 模块不再装自己的 init rc，用快照补回。
# （VINTF 片段不受 installable 控制，仍由 Soong 正常安装，这里不处理。）
put "$DEV/configs/init/android.hardware.media.c2-default-service.rc" "etc/init/android.hardware.media.c2-default-service.rc"
put "$DEV/configs/init/android.hardware.power-service-mediatek.rc" "etc/init/android.hardware.power-service-mediatek.rc"
put "$DEV/configs/init/android.hardware.nfc@1.2-service.rc" "etc/init/android.hardware.nfc@1.2-service.rc"
put "$DEV/configs/init/android.hardware.audio.service.mediatek.rc" "etc/init/android.hardware.audio.service.mediatek.rc"
# VINTF 片段：vendor/xiaomi/cannon 的 prebuilt_etc_xml 与 external/wpa_supplicant_8
# 各装一份同一路径（soong 内部抢规则）。把前者置 installable:false，这里用
# blob 原件覆盖，内容与原来一致。
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/etc/vintf/manifest/android.hardware.wifi.hostapd.xml" "etc/vintf/manifest/android.hardware.wifi.hostapd.xml"
put "$ROOT/vendor/xiaomi/cannon/proprietary/vendor/etc/vintf/manifest/android.hardware.wifi.supplicant.xml" "etc/vintf/manifest/android.hardware.wifi.supplicant.xml"
say "  + 覆盖 37 个 blob/prebuilt 文件（迁移自 PRODUCT_COPY_FILES）"

if [ "$MISS" -ne 0 ]; then echo "[preasm] ⚠ 有 $MISS 项缺失/跳过（见上）"; exit 3; fi
echo "[preasm] ✅ 完成：staging 预装配就位，file_list 已登记（build_image 将自动打标签）"
