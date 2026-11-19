/*
 * [cannon][A17] A17 的 libcodec2_vndk.so 引用
 *   BufferAllocator::Alloc(const std::string&, size_t, unsigned int)
 * 这是 A17 新增的 3 参数重载（内部等价于 4 参数版本 + alignment=0）。
 * 厂商的 libdmabufheap.so 是 A12 的，只有 4 参数版本：
 *   BufferAllocator::Alloc(const std::string&, size_t, unsigned int, size_t)
 *
 * 直接替换 /vendor/lib64/libdmabufheap.so 会破坏 MTK gralloc / surfaceflinger
 * （实测 SkiaGLRenderEngine::create 空指针崩溃），所以这里只补这一个符号，
 * 通过 LD_PRELOAD 只进入 codec2 AIDL 服务进程，转发到厂商的 4 参数实现。
 */
#include <dlfcn.h>
#include <stddef.h>

#define SYM_ALLOC3 \
    "_ZN15BufferAllocator5AllocERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEmj"
#define SYM_ALLOC4 \
    "_ZN15BufferAllocator5AllocERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEmjm"

typedef int (*alloc4_fn)(void *, const void *, size_t, unsigned int, size_t);

extern int alloc3(void *, const void *, size_t, unsigned int) __asm__(SYM_ALLOC3);

int alloc3(void *self, const void *name, size_t len, unsigned int flags) {
    static alloc4_fn fn4;
    if (fn4 == NULL) {
        fn4 = (alloc4_fn)dlsym(RTLD_NEXT, SYM_ALLOC4);
    }
    if (fn4 == NULL) {
        return -1;
    }
    return fn4(self, name, len, flags, 0);
}
