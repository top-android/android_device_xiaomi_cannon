#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
# Copyright (C) 2017-2020 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

set -e

DEVICE=cannon
VENDOR=xiaomi

# Load extract_utils and do some sanity checks
MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then MY_DIR="${PWD}"; fi

ANDROID_ROOT="${MY_DIR}/../../.."

HELPER="${ANDROID_ROOT}/tools/extract-utils/extract_utils.sh"
if [ ! -f "${HELPER}" ]; then
    echo "Unable to find helper script at ${HELPER}"
    exit 1
fi
source "${HELPER}"

# Default to sanitizing the vendor folder before extraction
CLEAN_VENDOR=true

KANG=
SECTION=

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n | --no-cleanup )
                CLEAN_VENDOR=false
                ;;
        -k | --kang )
                KANG="--kang"
                ;;
        -s | --section )
                SECTION="${2}"; shift
                CLEAN_VENDOR=false
                ;;
        * )
                SRC="${1}"
                ;;
    esac
    shift
done

if [ -z "${SRC}" ]; then
    SRC="adb"
fi

function blob_fixup() {
    case "${1}" in
    vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service)
        "${PATCHELF}" --replace-needed "android.hardware.power-V2-ndk_platform.so" "android.hardware.power-V2-ndk.so" "${2}"
        ;;
    vendor/bin/hw/android.hardware.thermal@2.0-service.mtk)
        "${PATCHELF}" --replace-needed "libutils.so" "libutils-v32.so" "${2}"
        "${PATCHELF}" --replace-needed "libhidlbase.so" "libhidlbase-v32.so" "${2}"
        "${PATCHELF}" --add-needed "libshim_cannon_vendor.so" "${2}"
        ;;
    vendor/bin/hw/camerahalserver)
        "${PATCHELF}" --replace-needed "libutils.so" "libutils-v32.so" "${2}"
        "${PATCHELF}" --replace-needed "libbinder.so" "libbinder-v32.so" "${2}"
        "${PATCHELF}" --replace-needed "libhidlbase.so" "libhidlbase-v32.so" "${2}"
        "${PATCHELF}" --add-needed "libshim_cannon_vendor.so" "${2}"
        ;;
    # A15 build/ 不再实现 TARGET_LD_SHIM_LIBS，旧垫片机制失效(见 docs/logs)。
    # 这些 HAL 经传递闭包核对确实缺 libshim_cannon_vendor 的
    # android::Thread::run / String16 移动构造等符号 → 直接烤进 NEEDED。
    vendor/bin/hw/android.hardware.gnss-service.mediatek|\
    vendor/bin/hw/android.hardware.bluetooth@1.1-service-mediatek|\
    vendor/bin/hw/mtkfusionrild|\
    vendor/bin/hw/vendor.mediatek.hardware.pq@2.2-service)
        "${PATCHELF}" --add-needed "libshim_cannon_vendor.so" "${2}"
        ;;
    system/lib64/libsource.so|\
    system/lib64/libsink.so)
        "${PATCHELF}" --add-needed "libshim_cannon_system.so" "${2}"
        ;;
    vendor/bin/mtk_agpsd)
       "$PATCHELF" --replace-needed "libcrypto.so" "libcrypto-v32.so" "$2"
        ;;
    vendor/lib/libnvram.so|\
    vendor/lib64/libnvram.so|\
    vendor/lib/libsysenv.so|\
    vendor/lib64/libsysenv.so|\
    vendor/lib/nfc_nci.nqx.default.hw.so|\
    vendor/lib64/nfc_nci.nqx.default.hw.so)
        # A15 的 libbase 把 android::base::Trim 改成了模板，不再导出旧的非模板符号
        # _ZN7android4base4TrimERK...；A12 的 libnvram/libsysenv/nfc_nci... 仍引用该符号。
        # 这三者是"未定义引用方"（libbase/libbinder/libdmabufheap/libreference-ril 自带定义，无关）。
        # 补 libbase_shim.so 依赖（其 strings.cpp 提供旧 Trim），否则加载它们的进程会
        # "cannot locate symbol ... Trim" 而 dlopen/exec 失败：
        #   libnvram → audio HAL / rild / 蓝牙 / nvram_daemon / fuelgauged / wlan_assistant
        #   libsysenv → ccci_mdinit / ccci_rpcd（基带）
        #   nfc_nci  → NFC HAL（本机无 NFC 硬件，顺手补齐）
        "${PATCHELF}" --add-needed "libbase_shim.so" "${2}"
        ;;
    vendor/lib*/hw/vendor.mediatek.hardware.pq@2.13-impl.so)
        "${PATCHELF}" --replace-needed "libutils.so" "libutils-v32.so" "${2}"
        "${PATCHELF}" --add-needed "libshim_sensors.so" "${2}"
        ;;
    vendor/lib64/libmtkcam_featurepolicy.so)
        sed -i "s|\xE8\x87\x40\xB9|\x28\x02\x80\x52|g" "${2}"
        ;;
    vendor/bin/mnld|\
    vendor/lib64/libaalservice.so|\
    vendor/lib64/libcam.utils.sensorprovider.so)
        "${PATCHELF}" --add-needed "libshim_sensors.so" "${2}"
        ;;
    vendor/bin/hw/android.hardware.media.c2@1.2-mediatek)
        "${PATCHELF}" --add-needed "libstagefright_foundation-v33.so" "${2}"
        ;;
    vendor/etc/init/vendor.mediatek.hardware.mtkpower@1.0-service.rc)
        echo "$(cat ${2}) input" > "${2}"
        ;;
    # 2026-10-30 第十八轮：gralloc impl 在 sphal 命名空间被 dlopen 时，其依赖
    # libutilscallstack.so -> libunwindstack.so 引用 A15 libc++ 新符号
    # std::__1::__libcpp_verbose_abort（_ZNSt3__122__libcpp_verbose_abortEPKcz），
    # 但 sphal 里 libc++.so 解析到 A12 /vendor/lib64/libc++.so，无此符号 →
    # dlopen 失败 → "gralloc-mapper is missing" → GraphicBufferMapper LOG_ALWAYS_FATAL
    # → media.swcodec 崩溃循环（没声）。补只导出该符号的垫片。
    vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-mediatek.so|\
    vendor/lib/hw/android.hardware.graphics.mapper@4.0-impl-mediatek.so)
        "${PATCHELF}" --add-needed "libshim_cpp_verbose_abort.so" "${2}"
        ;;
    # 2026-10-30 第十九轮：neuron NN HAL 自身 UND 引用旧 android::base::Trim
    # （_ZN7android4base4TrimERKNSt3__112basic_string...），其 NEEDED 的 A15 libbase.so
    # 已删除该非模板符号 → 每 5s "cannot locate symbol ...Trim" 崩溃重启（NPC 噪音，
    # 不杀 system_server）。补 libbase_shim.so（已导出旧 Trim）进 NEEDED。
    vendor/bin/hw/android.hardware.neuralnetworks@1.3-service-mtk-neuron)
        "${PATCHELF}" --add-needed "libbase_shim.so" "${2}"
        ;;
    esac
}

# Initialize the helper
setup_vendor "${DEVICE}" "${VENDOR}" "${ANDROID_ROOT}" false "${CLEAN_VENDOR}"

extract "${MY_DIR}/proprietary-files.txt" "${SRC}" "${KANG}" --section "${SECTION}"

"${MY_DIR}/setup-makefiles.sh"
