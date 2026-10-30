// cannon: A15(Android 15) 的 /system/lib64/libunwindstack.so 引用了一个新的 libc++
// 符号 std::__1::__libcpp_verbose_abort(char const*, ...)（mangled
// _ZNSt3__122__libcpp_verbose_abortEPKcz）。该符号在 A15 的 /system/lib64/libc++.so 里
// 被导出（WEAK），但 A12 vendor 的 /vendor/lib64/libc++.so 没有。
//
// 现象：vendor 的 gralloc HAL android.hardware.graphics.mapper@4.0-impl-mediatek.so 在
// "sphal" 命名空间被 dlopen 时，其依赖 libutilscallstack.so -> libunwindstack.so 的该
// UND 符号解析到 /vendor/lib64/libc++.so（A12，无此符号）→ dlopen 失败 →
// "gralloc-mapper is missing" -> GraphicBufferMapper LOG_ALWAYS_FATAL -> media.swcodec
// 崩溃循环（没声）。
//
// 修法：提供一个只导出该符号的垫片，用 patchelf --add-needed 烤进 gralloc impl，
// 使 libunwindstack 的 UND 在 sphal 命名空间内能被本垫片补齐（与 libbase_shim 同一套路）。

#include <stdarg.h>
#include <stdlib.h>
#include <android/log.h>

namespace std {
inline namespace __1 {

__attribute__((noreturn))
void __libcpp_verbose_abort(const char* format, ...) {
    va_list ap;
    va_start(ap, format);
    __android_log_vprint(ANDROID_LOG_FATAL, "libc++", format, ap);
    va_end(ap);
    abort();
}

}  // namespace __1
}  // namespace std
