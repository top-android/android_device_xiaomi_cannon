#
# Copyright (C) 2023 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit some common Lineage stuff.
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Inherit from cannon device
$(call inherit-product, device/xiaomi/cannon/device.mk)

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
