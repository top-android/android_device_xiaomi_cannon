/*
 * cannon: 开机时通过 MTK 私有 HIDL 设置 NR 选项（AT+E5GOPT=<n>）
 *
 * 背景：AOSP/LineageOS 的 telephony 从不调用 IMtkRadioEx::setNROption，
 *       modem 停在出厂默认 5（0b101，仅 NSA）。纯 SA 组网下 modem 不注册 NR，
 *       框架只看到 LTE 且 dcnr-Restricted=true，5G 永远显示不出来。
 *       原厂 MIUI 是开机时通过 OEM hook 下发 AT+E5GOPT=7（0b111，NSA+SA）。
 *
 * 本程序由 init 在 on boot 阶段拉起，此时 framework 还没打开射频，
 * 设置完成后 modem 首次注册就带 SA 能力，不需要再触发重注册。
 *
 * 用法：cannon_nropt [option]   // 默认 7；5=仅 NSA，1=关 NR
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <android/log.h>
#include <hidl/HidlTransportSupport.h>
#include <vendor/mediatek/hardware/mtkradioex/3.0/IMtkRadioEx.h>

#define LOG_TAG "cannon_nropt"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

using vendor::mediatek::hardware::mtkradioex::V3_0::IMtkRadioEx;

int main(int argc, char** argv) {
    const int option = (argc > 1) ? atoi(argv[1]) : 7;
    android::hardware::configureRpcThreadpool(1, false);

    const char* slots[] = {"mtkSlot1", "mtkSlot2"};
    for (const char* slot : slots) {
        android::sp<IMtkRadioEx> svc;
        // 开机早期 HAL 可能还没注册到 hwservicemanager，最多等 30s
        for (int i = 0; i < 60 && svc == nullptr; i++) {
            svc = IMtkRadioEx::getService(slot);
            if (svc == nullptr) usleep(500 * 1000);
        }
        if (svc == nullptr) {
            LOGI("%s: service not found, skip", slot);
            continue;
        }
        // setNROption 是 oneway，拿不到 AT 回执；modem 早期可能还没起 AT 通道，
        // 隔 2s 重发一次兜底。
        for (int i = 0; i < 2; i++) {
            auto ret = svc->setNROption(0, option);
            LOGI("%s: setNROption(%d) attempt %d -> %s", slot, option, i + 1,
                 ret.isOk() ? "ok" : "transport error");
            if (!ret.isOk()) break;
            sleep(2);
        }
    }
    return 0;
}
