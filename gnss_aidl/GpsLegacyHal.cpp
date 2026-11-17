#define LOG_TAG "GpsLegacyHal"

#include "GpsLegacyHal.h"

#include <hardware/hardware.h>
#include <log/log.h>
#include <pthread.h>

#include <cstring>

namespace {

// MTK 的 gps.mt6853.so 期望 13 个回调槽（112 字节），A17 的 GpsCallbacks 只有 11 个。
// 第 12 个（offset 0x60）是 name 回调：init 阶段会用 (name, strlen(name)) 调用它，
// 留空会直接 SIGSEGV（gpshal_gpscbs_save+0x10c）。第 13 个（0x68）init 阶段未使用，
// 但仍要给出合法地址，防止模块内部其它路径调用。
struct Callbacks112 {
    GpsCallbacks cb;
    void (*name_cb)(const char* name, size_t length);
    void (*reserved_cb)();
};

GpsLegacyHal* gHal = nullptr;

void locCb(GpsLocation* location) {
    if (gHal == nullptr || location == nullptr) return;
    GpsLegacyHal::get().dispatchLocation(*location);
}
void statusCb(GpsStatus* status) {
    if (status == nullptr) return;
    GpsLegacyHal::get().dispatchStatus(status->status);
}
void svStatusCb(GpsSvStatus* svStatus) {
    if (svStatus == nullptr) return;
    GpsLegacyHal::get().dispatchSvStatus(*svStatus);
}
void nmeaCb(GpsUtcTime timestamp, const char* nmea, int length) {
    if (nmea == nullptr || length <= 0) return;
    GpsLegacyHal::get().dispatchNmea(timestamp, std::string(nmea, length));
}
void capabilitiesCb(uint32_t capabilities) {
    GpsLegacyHal::get().dispatchCapabilities(capabilities);
}
void systemInfoCb(const GnssSystemInfo* info) {
    if (info == nullptr) return;
    GpsLegacyHal::get().dispatchSystemInfo(*info);
}
void nameCb(const char* name, size_t length) {
    if (name == nullptr) return;
    GpsLegacyHal::get().dispatchName(std::string(name, length));
}
void gnssSvStatusCb(GnssSvStatus*) {
    // 暂不上报 SV 状态，占位避免模块调用空指针
}
void reservedCb() {}
void acquireWakelockCb() { GpsLegacyHal::get().dispatchAcquireWakelock(); }
void releaseWakelockCb() { GpsLegacyHal::get().dispatchReleaseWakelock(); }
void requestTimeCb() { GpsLegacyHal::get().dispatchRequestTime(); }

struct ThreadStart {
    void (*start)(void*);
    void* arg;
};

void* threadTrampoline(void* data) {
    auto* t = static_cast<ThreadStart*>(data);
    t->start(t->arg);
    delete t;
    return nullptr;
}

pthread_t createThreadCb(const char* name, void (*start)(void*), void* arg) {
    pthread_t thread{};
    if (start == nullptr) return thread;
    auto* t = new ThreadStart{start, arg};
    if (pthread_create(&thread, nullptr, threadTrampoline, t) != 0) {
        delete t;
        return pthread_t{};
    }
    if (name != nullptr) pthread_setname_np(thread, name);
    return thread;
}

Callbacks112 makeCallbacks() {
    Callbacks112 callbacks{};
    callbacks.cb.size = sizeof(Callbacks112);
    callbacks.cb.location_cb = locCb;
    callbacks.cb.status_cb = statusCb;
    callbacks.cb.sv_status_cb = svStatusCb;
    callbacks.cb.nmea_cb = nmeaCb;
    callbacks.cb.set_capabilities_cb = capabilitiesCb;
    callbacks.cb.acquire_wakelock_cb = acquireWakelockCb;
    callbacks.cb.release_wakelock_cb = releaseWakelockCb;
    callbacks.cb.create_thread_cb = createThreadCb;
    callbacks.cb.request_utc_time_cb = requestTimeCb;
    callbacks.cb.set_system_info_cb = systemInfoCb;
    callbacks.cb.gnss_sv_status_cb = gnssSvStatusCb;
    callbacks.name_cb = nameCb;
    callbacks.reserved_cb = reservedCb;
    return callbacks;
}

}  // namespace

GpsLegacyHal& GpsLegacyHal::get() {
    static GpsLegacyHal instance;
    return instance;
}

void GpsLegacyHal::setCallbacks(LocationFn location, StatusFn status, SvStatusFn svStatus,
                                NmeaFn nmea, CapabilitiesFn capabilities,
                                SystemInfoFn systemInfo, NameFn name,
                                AcquireWakelockFn acquireWakelock,
                                ReleaseWakelockFn releaseWakelock, RequestTimeFn requestTime) {
    std::lock_guard<std::mutex> lock(mMutex);
    mLocation = std::move(location);
    mStatus = std::move(status);
    mSvStatus = std::move(svStatus);
    mNmea = std::move(nmea);
    mCapabilities = std::move(capabilities);
    mSystemInfo = std::move(systemInfo);
    mName = std::move(name);
    mAcquireWakelock = std::move(acquireWakelock);
    mReleaseWakelock = std::move(releaseWakelock);
    mRequestTime = std::move(requestTime);
    gHal = this;
}

bool GpsLegacyHal::ensureInterface() {
    if (mInterface != nullptr) return true;

    const hw_module_t* module = nullptr;
    int rc = hw_get_module(GPS_HARDWARE_MODULE_ID, &module);
    if (rc != 0 || module == nullptr) {
        ALOGE("hw_get_module(gps) failed: %d", rc);
        return false;
    }

    gps_device_t* device = nullptr;
    rc = module->methods->open(module, GPS_HARDWARE_MODULE_ID, (hw_device_t**)&device);
    if (rc != 0 || device == nullptr) {
        ALOGE("open(gps) failed: %d", rc);
        return false;
    }

    mInterface = device->get_gps_interface(device);
    if (mInterface == nullptr) {
        ALOGE("get_gps_interface returned null");
        return false;
    }
    ALOGI("gps interface ready, size=%zu", mInterface->size);
    return true;
}

bool GpsLegacyHal::init() {
    std::lock_guard<std::mutex> lock(mMutex);
    if (!ensureInterface()) return false;
    if (mInitialized) return true;

    // 必须活到 cleanup，模块会长期持有这个指针
    static Callbacks112 callbacks = makeCallbacks();
    int rc = mInterface->init(&callbacks.cb);
    if (rc != 0) {
        ALOGE("GpsInterface::init failed: %d", rc);
        return false;
    }
    mInitialized = true;
    ALOGI("GpsInterface::init ok");
    return true;
}

bool GpsLegacyHal::start() {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || mInterface->start == nullptr) return false;
    if (mStarted) return true;
    int rc = mInterface->start();
    if (rc != 0) {
        ALOGE("GpsInterface::start failed: %d", rc);
        return false;
    }
    mStarted = true;
    ALOGI("GpsInterface::start ok");
    return true;
}

void GpsLegacyHal::stop() {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || !mStarted || mInterface->stop == nullptr) return;
    mInterface->stop();
    mStarted = false;
    ALOGI("GpsInterface::stop");
}

void GpsLegacyHal::cleanup() {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || mInterface->cleanup == nullptr) return;
    mInterface->cleanup();
    mInitialized = false;
    mStarted = false;
    ALOGI("GpsInterface::cleanup");
}

bool GpsLegacyHal::setPositionMode(int mode, int recurrence, int minIntervalMs,
                                   int preferredAccuracyMs, int preferredTimeMs) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || mInterface->set_position_mode == nullptr) {
        return false;
    }
    int rc = mInterface->set_position_mode((GpsPositionMode)mode, (GpsPositionRecurrence)recurrence,
                                           minIntervalMs, preferredAccuracyMs, preferredTimeMs);
    if (rc != 0) {
        ALOGE("set_position_mode failed: %d", rc);
        return false;
    }
    return true;
}

bool GpsLegacyHal::injectTime(int64_t timeMs, int64_t timeReferenceMs, int32_t uncertaintyMs) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || mInterface->inject_time == nullptr) return false;
    mInterface->inject_time(timeMs, timeReferenceMs, uncertaintyMs);
    return true;
}

bool GpsLegacyHal::injectLocation(double latitudeDegrees, double longitudeDegrees,
                                  float accuracyMeters) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || mInterface->inject_location == nullptr) {
        return false;
    }
    mInterface->inject_location(latitudeDegrees, longitudeDegrees, accuracyMeters);
    return true;
}

bool GpsLegacyHal::deleteAidingData(int flags) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mInterface == nullptr || !mInitialized || mInterface->delete_aiding_data == nullptr) {
        return false;
    }
    mInterface->delete_aiding_data((GpsAidingData)flags);
    return true;
}
void GpsLegacyHal::dispatchLocation(const GpsLocation& location) {
    if (mLocation) mLocation(location);
}
void GpsLegacyHal::dispatchStatus(int32_t status) {
    if (mStatus) mStatus(status);
}
void GpsLegacyHal::dispatchSvStatus(const GpsSvStatus& svStatus) {
    if (mSvStatus) mSvStatus(svStatus);
}
void GpsLegacyHal::dispatchNmea(int64_t timestampMs, const std::string& nmea) {
    if (mNmea) mNmea(timestampMs, nmea);
}
void GpsLegacyHal::dispatchCapabilities(uint32_t capabilities) {
    if (mCapabilities) mCapabilities(capabilities);
}
void GpsLegacyHal::dispatchSystemInfo(const GnssSystemInfo& info) {
    if (mSystemInfo) mSystemInfo(info);
}
void GpsLegacyHal::dispatchName(const std::string& name) {
    if (mName) mName(name);
}
void GpsLegacyHal::dispatchAcquireWakelock() {
    if (mAcquireWakelock) mAcquireWakelock();
}
void GpsLegacyHal::dispatchReleaseWakelock() {
    if (mReleaseWakelock) mReleaseWakelock();
}
void GpsLegacyHal::dispatchRequestTime() {
    if (mRequestTime) mRequestTime();
}
