/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * MTK Q 的 libcodec2_hidl@1.0.so（以及 A17 的 libsfplugin_ccodec /
 * libstagefright_graphicbuffersource_aidl）都引用 android::GraphicBufferSource。
 * A17 的实现（libstagefright_bufferqueue_helper）依赖 libgui/libEGL 等只在
 * /system 的库，装不进 /vendor，所以这里用同名 SONAME 提供空实现，
 * 由 c2 服务的 rc 通过 LD_PRELOAD 预加载。
 *
 * 只有「c2 硬件编码 + 输入 surface」才会真正调用这些方法，解码路径不碰。
 * 三个 getXGraphicBufferProducer 返回空 sp，其余返回 -1（UNKNOWN_ERROR）。
 */

#include <stdint.h>
#include <string.h>

extern "C" {
int32_t _ZN7android19GraphicBufferSource10setSuspendEbl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource13setStopTimeUsEl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource14setStartTimeUsEl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource14submitBuffer_lERKNS0_11VideoBufferE(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource15acquireBuffer_lEPNS0_11VideoBufferE(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource15setColorAspectsEi(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource15setTimeOffsetUsEl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource16onFrameAvailableERKNS_10BufferItemE(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource17fillCodecBuffer_lEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource17onBuffersReleasedEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource17onMessageReceivedERKNS_2spINS_8AMessageEEE(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource17setLatestBuffer_lERKNS0_11VideoBufferE(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource18onBufferAcquired_lERKNS0_11VideoBufferE(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource18onInputBufferAddedEi(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource18queueFrameRepeat_lEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource18setTimeLapseConfigEdd(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource19getStopTimeOffsetUsEPl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource20onDataspaceChanged_lE19android_dataspace_t22android_pixel_format_t(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource20onInputBufferEmptiedEii(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource20repeatLatestBuffer_lEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource21discardBufferInSlot_lEi(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource22signalEndOfInputStreamEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource23onSidebandStreamChangedEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource24submitEndOfInputStream_lEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource25calculateCodecTimestamp_lElPl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource26discardBufferAtSlotIndex_lEl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource28releaseAllAvailableBuffers_lEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource29setRepeatPreviousFrameDelayUsEl(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource33areWeDiscardingAvailableBuffers_lEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource4stopEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource5startEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource7releaseEv(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource9configureERKNS_2spINS_16ComponentWrapperEEEiijjj(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource9configureERKNS_2spINS_16ComponentWrapperEEEiijjm(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSource9setMaxFpsEf(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSourceC1Ev(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSourceC2Ev(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSourceD0Ev(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSourceD1Ev(void*, void*, void*, void*, void*) { return -1; }
int32_t _ZN7android19GraphicBufferSourceD2Ev(void*, void*, void*, void*, void*) { return -1; }
void _ZNK7android19GraphicBufferSource25getHGraphicBufferProducerEv(void*, void* out) {
    if (out != nullptr) {
        memset(out, 0, sizeof(void*));
    }
}
void _ZNK7android19GraphicBufferSource25getIGraphicBufferProducerEv(void*, void* out) {
    if (out != nullptr) {
        memset(out, 0, sizeof(void*));
    }
}
void _ZNK7android19GraphicBufferSource30getHGraphicBufferProducer_V1_0Ev(void*, void* out) {
    if (out != nullptr) {
        memset(out, 0, sizeof(void*));
    }
}

// A17 的 libcodec2_vndk.so 还要 GraphicBufferMapper::setSmpte2094_50（HDR10+ 元数据），
// 进程里解析到的是 vendor 侧 A10 的 libui，没有这个符号。解码不用 HDR10+，返回 OK。
int32_t _ZN7android19GraphicBufferMapper15setSmpte2094_50EPK13native_handleNSt3__18optionalINS4_6vectorIhNS4_9allocatorIhEEEEEE(
        void*, void*, void*) {
    return 0;
}

// 回退到 A10 的 libcodec2_vndk 后，A17 的 libcodec2_aidl 仍引用这个 A17 才有的重载
// （AHardwareBuffer 版本的 GraphicBlock 分配）。AIDL HAL 只在客户端传 AHardwareBuffer
// 时用；这里回空 shared_ptr（sret），调用方会拿到空块并走错误分支，不会崩。
void _ZN15_C2BlockFactory18CreateGraphicBlockEP15AHardwareBuffer(void* out, void*) {
    if (out != nullptr) {
        memset(out, 0, 16);
    }
}
}
