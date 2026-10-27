#define LOG_TAG "BtAudioAIDLServiceCannon"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <log/log.h>

// Implemented in android.hardware.bluetooth.audio-impl (AOSP default A2DP/HFP
// software providers). Registers the AIDL IBluetoothAudioProviderFactory so the
// A14 audio policy can route A2DP/HFP audio to Bluetooth. Normally the AOSP
// audio HAL calls this; MTK's A12 audio HAL does not, hence this tiny service.
extern "C" __attribute__((visibility("default"))) binder_status_t
createIBluetoothAudioProviderFactory();

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(0);
    binder_status_t st = createIBluetoothAudioProviderFactory();
    if (st != STATUS_OK) {
        ALOGE("register BluetoothAudioProviderFactory failed: %d", st);
        return 1;
    }
    ALOGI("BluetoothAudioProviderFactory registered");
    ABinderProcess_joinThreadPool();
    return 0;
}
