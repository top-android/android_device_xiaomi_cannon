#
# Copyright (C) 2023 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# [cannon][A17] 恢复标准 userdebug 的 ro.debuggable=1。
# Lineage 在 vendor/lineage/config/common.mk:43 设 PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG := true，
# 于是 gen_build_prop.py:376 把 ro.debuggable 写成 0 —— adb root 直接不可用
# （should_drop_privileges() 里 ro_debuggable 为假，service.adb.root=1 也不生效）。
#
# 它在 build/make/core/product.mk:496 的 _product_single_value_vars 里，
# inherit-product 对单值变量是「先到先得」：必须写在**任何 inherit-product 之前**。
# 写在 inherit 之后（哪怕在本文件里）都压不住 common.mk —— 2026-11-10 实测
# out/soong/soong.lineage_cannon.extra.variables 仍是 "ProductNotDebuggableInUserdebug": true。
# 发布正式版时删掉本行。
PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG := false

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit some common Lineage stuff.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Inherit from cannon device
$(call inherit-product, device/xiaomi/cannon/device.mk)

# [cannon][A17] 内核 4.14 非 GKI：没有 CONFIG_USERFAULTFD，也没有 MREMAP_DONTUNMAP。
# A17 默认 PRODUCT_ENABLE_UFFD_GC=true（build/make/target/product/default_art_config.mk:288），
# dexpreopt 会用 -Xgc:CMC 生成 boot.art（read barrier=false）；而运行时因内核不支持 uffd
# 只能退回 read barrier=true，zygote 加载时报：
#   ValidateOatFile found read barrier state mismatch (oat file: false, runtime: true)
# 导致 zygote 秒退、system_server 起不来、永远卡开机动画。
# 注意：必须写在顶层产品 makefile 里。PRODUCT_ENABLE_UFFD_GC 是单值产品变量，
# inherit-product 是「先到先得」，写在 device.mk 里会被 core 继承链里的 true 吃掉。
PRODUCT_ENABLE_UFFD_GC := false

PRODUCT_DEVICE := cannon
PRODUCT_NAME := lineage_cannon
PRODUCT_BRAND := Redmi
PRODUCT_MODEL := M2007J22C
PRODUCT_MANUFACTURER := Xiaomi

PRODUCT_GMS_CLIENTID_BASE := android-xiaomi

PRODUCT_BUILD_PROP_OVERRIDES += \
    BuildDesc="cannong-user 12 SP1A.210812.016 V13.0.3.0.SJEMIXM release-keys"
# A15: build.prop 改由 build/soong/scripts/gen_build_prop.py 生成，override key 必须是
# product_config.json 里的 CamelCase 变量名；旧的 PRIVATE_BUILD_DESC 已不被识别（会报
# Key "PRIVATE_BUILD_DESC" isn't a valid prop override）。ro.build.description 取自
# config['BuildDesc']（gen_build_prop.py:274），故此处改用 BuildDesc=（cannon A15 适配）。

BUILD_FINGERPRINT := Redmi/cannong_global/cannong:12/SP1A.210812.016/V13.0.3.0.SJEMIXM:user/release-keys
