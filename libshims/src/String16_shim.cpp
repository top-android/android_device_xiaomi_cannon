/*
 * Copyright (C) 2026 The LineageOS Project
 *
 * SPDX-License-Identifier: Apache-2.0
 */

// A12 厂商 blob / A14 框架库之间的 String16「移动语义」ABI 缺口。
//
// 症状（logcat 实测）：
//   CANNOT LINK EXECUTABLE "/vendor/bin/hw/android.hardware.thermal@2.0-service.mtk":
//     cannot locate symbol "_ZN7android8String16C1EOS0_" referenced by "/system/lib64/libbinder.so"
//   ⇒ thermal/GNSS/相机等 HAL 起不来 ⇒ 框架 getService 死等 ⇒ Watchdog ⇒ 卡开机动画
//
// A14 的实现（system/core/libutils/binder/String16.cpp）：
//   String16::String16(String16&& o) noexcept : mString(o.mString) { o.mString = getEmptyString(); }
//   String16& String16::operator=(String16&& other) noexcept {
//       release(); mString = other.mString; other.mString = getEmptyString(); return *this;
//   }
// 但 getEmptyString()/release() 是 libutils 内的文件级私有实现，外部无法调用。
//
// 这里改用「拷贝语义」等价实现：移动构造/移动赋值对使用者而言，结果都是
// “目标获得源的内容、源变为空”，因此用公开的拷贝构造/拷贝赋值 + 置空即可，
// 语义等价、且不需要访问 libutils 内部实现。
//
// 注意：必须避免自我递归 —— 置空时用左值（const String16 对象）走拷贝赋值，
// 否则 *other = String16() 会再次落到本文件定义的移动赋值上。

#include <new>

#include <utils/String16.h>

namespace {

// 用「拷贝赋值」把 p 置为空（左值 ⇒ 走 operator=(const String16&)，不会递归）
inline void clearByCopy(android::String16* p) {
    const android::String16 empty;
    *p = empty;
}

}  // namespace

// android::String16::String16(android::String16&&)
extern "C" void _ZN7android8String16C1EOS0_(android::String16* self, android::String16* other) {
    new (self) android::String16(*other);  // 拷贝构造（左值 ⇒ 走拷贝构造）
    clearByCopy(other);
}

// android::String16& android::String16::operator=(android::String16&&)
extern "C" android::String16* _ZN7android8String16aSEOS0_(android::String16* self,
                                                          android::String16* other) {
    *self = *other;  // 拷贝赋值（左值 ⇒ 走拷贝赋值）
    clearByCopy(other);
    return self;
}
