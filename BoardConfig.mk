#
# Copyright (C) 2023 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/xiaomi/cannon

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 := 
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a76

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a55

# Build system
BUILD_BROKEN_DUP_RULES := true
# BUILD_BROKEN_ENFORCE_SYSPROP_OWNER := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true

# APEX
DEXPREOPT_GENERATE_APEX_IMAGE := true

# Assert
TARGET_OTA_ASSERT_DEVICE := cannon,cannong

# Bootloader
TARGET_BOOTLOADER_BOARD_NAME := cannon
TARGET_NO_BOOTLOADER := true

# Display
TARGET_SCREEN_DENSITY := 440

# Kernel
BOARD_BOOTIMG_HEADER_VERSION := 2
BOARD_KERNEL_BASE := 0x40078000
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 androidboot.usbconfigfs=true androidboot.init_fatal_reboot_target=recovery
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/prebuilts/dtbo.img
BOARD_PREBUILT_DTBIMAGE := $(DEVICE_PATH)/prebuilts/dtb.img
BOARD_KERNEL_PAGESIZE := 2048
BOARD_RAMDISK_OFFSET := 0x07c08000
BOARD_KERNEL_TAGS_OFFSET := 0x0bc08000
BOARD_KERNEL_IMAGE_NAME := Image.gz
KERNEL_LD := LD=ld.lld
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOTIMG_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_KERNEL_TAGS_OFFSET)
BOARD_MKBOOTIMG_ARGS += --dtb $(BOARD_PREBUILT_DTBIMAGE)
TARGET_KERNEL_CONFIG := cannon_defconfig
TARGET_KERNEL_SOURCE := kernel/xiaomi/cannon

# Partitions
BOARD_FLASH_BLOCK_SIZE := 131072 # (BOARD_KERNEL_PAGESIZE * 64)
BOARD_HAS_LARGE_FILESYSTEM := true
BOARD_CACHEIMAGE_PARTITION_SIZE := 452984832
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_DTBOIMG_PARTITION_SIZE := 33554432
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 134217728
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEMIMAGE_PARTITION_TYPE := ext4
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SUPER_PARTITION_SIZE := 9126805504 # TODO: Fix hardcoded value
BOARD_SUPER_PARTITION_GROUPS := xiaomi_dynamic_partitions
BOARD_XIAOMI_DYNAMIC_PARTITIONS_PARTITION_LIST := system vendor product system_ext
BOARD_XIAOMI_DYNAMIC_PARTITIONS_SIZE := 9122611200 # TODO: Fix hardcoded value

BOARD_SYSTEMIMAGE_PARTITION_RESERVED_SIZE := 1258291200
BOARD_VENDORIMAGE_PARTITION_RESERVED_SIZE := 30720000
BOARD_PRODUCTIMAGE_PARTITION_RESERVED_SIZE := 1258291200
BOARD_SYSTEM_EXTIMAGE_PARTITION_RESERVED_SIZE := 1258291200

BOARD_SYSTEMIMAGE_EXTFS_INODE_COUNT := -1
BOARD_PRODUCTIMAGE_EXTFS_INODE_COUNT := -1
BOARD_SYSTEM_EXTIMAGE_EXTFS_INODE_COUNT := -1

BOARD_ROOT_EXTRA_FOLDERS += metadata
BOARD_USES_METADATA_PARTITION := true

TARGET_USES_MKE2FS := true
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_VENDOR := vendor

# Platform
TARGET_BOARD_PLATFORM := mt6853
BOARD_HAS_MTK_HARDWARE := true
BOARD_HAVE_MTK_FM := true

# Power
TARGET_TAP_TO_WAKE_NODE := "/sys/touchpanel/double_tap"

# Init
TARGET_INIT_VENDOR_LIB := //$(DEVICE_PATH):init_cannon
TARGET_RECOVERY_DEVICE_MODULES := init_cannon

# Properties
TARGET_SYSTEM_PROP += $(DEVICE_PATH)/system.prop
TARGET_VENDOR_PROP += $(DEVICE_PATH)/vendor.prop

# Recovery
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/rootdir/etc/fstab.mt6853
BOARD_INCLUDE_RECOVERY_DTBO := true
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_UI_BLANK_UNBLANK_ON_INIT := true
TARGET_RECOVERY_UI_MARGIN_HEIGHT := 60

# 2026-10-27  蓝牙 A2DP：让 audio HAL 进程看不到 /vendor/bin/vndservicemanager，
# 否则它会把整个进程绑到 /dev/vndbinder，蓝牙音频 provider 注册到错误的服务管理器。
# 详见 configs/fs_config_vendor.fs 与 docs/2026-10-27-bt-a2dp-vndbinder-domain.md
TARGET_FS_CONFIG_GEN += $(DEVICE_PATH)/configs/fs_config_vendor.fs

# Sepolicy
include device/mediatek/sepolicy_vndr/SEPolicy.mk
BOARD_VENDOR_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/vendor
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/private

# RIL
ENABLE_VENDOR_RIL_SERVICE := true

# Security patch level
VENDOR_SECURITY_PATCH := 2021-11-05

# AVB
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_VBMETA_SYSTEM := system
BOARD_AVB_VBMETA_SYSTEM_KEY_PATH := external/avb/test/data/testkey_rsa2048.pem
BOARD_AVB_VBMETA_SYSTEM_ALGORITHM := SHA256_RSA2048
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX := $(PLATFORM_SECURITY_PATCH_TIMESTAMP)
BOARD_AVB_VBMETA_SYSTEM_ROLLBACK_INDEX_LOCATION := 1
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa2048.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA2048
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1
BOARD_AVB_VBMETA_VENDOR := vendor
BOARD_AVB_VBMETA_VENDOR_KEY_PATH := external/avb/test/data/testkey_rsa2048.pem
BOARD_AVB_VBMETA_VENDOR_ALGORITHM := SHA256_RSA2048
BOARD_AVB_VBMETA_VENDOR_ROLLBACK_INDEX := $(PLATFORM_SECURITY_PATCH_TIMESTAMP)
BOARD_AVB_VBMETA_VENDOR_ROLLBACK_INDEX_LOCATION := 2

# VINTF
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE := $(DEVICE_PATH)/configs/vintf/framework_compatibility_matrix.xml
DEVICE_MATRIX_FILE += $(DEVICE_PATH)/configs/vintf/compatibility_matrix.xml
DEVICE_MANIFEST_FILE += $(DEVICE_PATH)/configs/vintf/manifest.xml
ODM_MANIFEST_SKUS += nfc
ODM_MANIFEST_NFC_FILES := $(DEVICE_PATH)/configs/vintf/manifest_nfc.xml

# Releasetools
TARGET_RELEASETOOLS_EXTENSIONS := $(DEVICE_PATH)

# WiFi
BOARD_WLAN_DEVICE := MediaTek
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
BOARD_WPA_SUPPLICANT_PRIVATE_LIB := lib_driver_cmd_mt66xx
WIFI_HIDL_FEATURE_DUAL_INTERFACE := true
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_HOSTAPD_DRIVER := NL80211
BOARD_HOSTAPD_PRIVATE_LIB := lib_driver_cmd_mt66xx
WIFI_DRIVER_FW_PATH_PARAM := "/dev/wmtWifi"
WIFI_DRIVER_FW_PATH_STA := "STA"
WIFI_DRIVER_FW_PATH_AP := "AP"
WIFI_DRIVER_FW_PATH_P2P := "P2P"
WIFI_DRIVER_STATE_CTRL_PARAM := "/dev/wmtWifi"
WIFI_DRIVER_STATE_ON := "1"
WIFI_DRIVER_STATE_OFF := "0"
WIFI_HIDL_UNIFIED_SUPPLICANT_SERVICE_RC_ENTRY := true

# A12 厂商 blob ↔ A14 框架库 的符号缺失兼容（LineageOS 官方 LD_SHIM_LIBS 机制）
# 原理：bionic/linker 在加载左侧目标时，把右侧垫片预加载进同一进程/命名空间，
#       由垫片补齐 A14 删掉的符号（gBnsConstructorMap / GraphicBufferMapper::lock /
#       String16 移动语义 / strncpy16 / convertToSensorEvent）。
# 注意：只映射具体 HAL 进程，不映射 libhidlbase.so 等全局平台库 —— 否则
#       surfaceflinger/zygote 等也会被垫片波及，有卡第一屏风险（fix18 的教训）。
TARGET_LD_SHIM_LIBS := \
    /vendor/bin/hw/android.hardware.thermal@2.0-service.mtk|libshim_cannon_vendor.so \
    /vendor/bin/hw/android.hardware.gnss-service.mediatek|libshim_cannon_vendor.so \
    /vendor/bin/hw/camerahalserver|libshim_cannon_vendor.so \
    /vendor/bin/hw/android.hardware.bluetooth@1.1-service-mediatek|libshim_cannon_vendor.so \
    /vendor/bin/hw/android.hardware.wifi@1.0-service-lazy|libshim_cannon_vendor.so \
    /vendor/bin/hw/wpa_supplicant|libshim_cannon_vendor.so \
    /vendor/bin/hw/hostapd|libshim_cannon_vendor.so \
    /vendor/bin/hw/rild|libshim_cannon_vendor.so \
    /vendor/bin/hw/mtkfusionrild|libshim_cannon_vendor.so \
    /vendor/bin/mnld|libshim_sensors.so \
    /vendor/bin/hw/android.hardware.sensors@2.0-service.multihal-mediatek|libshim_sensors.so \
    /vendor/lib64/libaalservice.so|libshim_sensors.so \
    /vendor/lib64/libcam.utils.sensorprovider.so|libshim_sensors.so \
    /vendor/bin/hw/vendor.mediatek.hardware.pq@2.2-service|libshim_cannon_vendor.so \
    /system/lib64/libsource.so|libshim_cannon_system.so \
    /system/lib64/libsink.so|libshim_cannon_system.so

# Inherit the proprietary files
include vendor/xiaomi/cannon/BoardConfigVendor.mk

# Disable VINTF manifest compatibility enforcement for this legacy device:
# the Android 14 framework compatibility matrix does not declare cannon's old
# HIDL HALs, and a plain 'PRODUCT_ENFORCE_VINTF_MANIFEST := false' is force
# overwritten by build/make/core/config.mk (it becomes PRODUCT_FULL_TREBLE=$
# (PRODUCT_SHIPPING_API_LEVEL>=26)), so the _OVERRIDE variable is required.
PRODUCT_ENFORCE_VINTF_MANIFEST_OVERRIDE := false
