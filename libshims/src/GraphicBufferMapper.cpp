/*
 * Copyright (C) 2024 The LineageOS Project
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdint.h>

#include <vector>

#include <android-base/unique_fd.h>
#include <sync/sync.h>
#include <ui/GraphicBufferMapper.h>
#include <ui/Rect.h>
#include <utils/Errors.h>

using android::Rect;
using android::status_t;

extern "C" {
// A12 的 32 位 codec2 HAL（libcodec2_vndk.so）调用 gralloc1 时代的 6 参数 lock：
//   lock(handle, usage, bounds, &vaddr, &bytesPerPixel, &bytesPerStride)
// A17 的 libui 已删除该符号。最初实现只回填了 vaddr，bytesPerPixel/bytesPerStride
// 保持未初始化 —— MTK 的 vdec 用它计算 buffer 布局，拿不到就一直卡到框架 3 秒超时
// （实测 start 卡 3.27s → UNKNOWN_ERROR，硬解永远失败，只能回退软解）。
// 这里用 gralloc4 的 getPlaneLayouts 回填 stride。
status_t _ZN7android19GraphicBufferMapper4lockEPK13native_handlejRKNS_4RectEPPvPiS9_(
        void* thisptr, buffer_handle_t handle, uint32_t usage, const Rect& bounds, void** vaddr,
        int32_t* outBytesPerPixel, int32_t* outBytesPerStride) {
    auto* gpm = static_cast<android::GraphicBufferMapper*>(thisptr);

    status_t status = gpm->lock(handle, usage, bounds, vaddr);
    if (status != android::OK) {
        return status;
    }

    int32_t bytesPerPixel = 1;
    int32_t bytesPerStride = 0;
    auto layouts = gpm->getPlaneLayouts(handle);
    if (layouts.ok() && !layouts.value().empty()) {
        // gralloc4: strideInBytes 已经是字节数，Y plane 按 1 byte/pixel 计
        bytesPerStride = static_cast<int32_t>(layouts.value()[0].strideInBytes);
        if (bytesPerStride <= 0) {
            bytesPerStride = 0;
        }
    }

    if (outBytesPerPixel != nullptr) {
        *outBytesPerPixel = bytesPerPixel;
    }
    if (outBytesPerStride != nullptr) {
        *outBytesPerStride = bytesPerStride;
    }
    return android::OK;
}

status_t _ZN7android19GraphicBufferMapper6unlockEPK13native_handle(void* thisptr,
                                                                   buffer_handle_t handle) {
    android::base::unique_fd outFence;
    auto* gpm = static_cast<android::GraphicBufferMapper*>(thisptr);
    status_t status = gpm->unlock(handle, &outFence);
    if (status == android::OK && outFence.get() >= 0) {
        sync_wait(outFence.get(), -1);
        outFence.reset();
    }
    return status;
}
// A17 的 libcodec2_vndk.so 引用 GraphicBufferMapper::setSmpte2094_50（HDR10+ 动态元数据），
// 但进程里实际解析到的是 vendor 侧 A10 的 libui，没有这个符号 -> CANNOT LINK。
// 解码路径不会用到 HDR10+ 元数据，返回 OK 即可。
status_t _ZN7android19GraphicBufferMapper15setSmpte2094_50EPK13native_handleNSt3__18optionalINS4_6vectorIhNS4_9allocatorIhEEEEEE(
        void* thisptr, buffer_handle_t handle, void* smpte2094_50) {
    (void)thisptr;
    (void)handle;
    (void)smpte2094_50;
    return android::OK;
}
}
