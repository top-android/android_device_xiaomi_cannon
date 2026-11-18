#pragma once

#include <hardware/gps.h>

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

// 通过 legacy gps.h 驱动 MTK 的 gps.mt6853.so。
// 关键点（probe 实测）：GpsCallbacks 必须是 112 字节 13 槽，
// 0x60 必须是 name 回调，否则模块内部会空指针崩溃或直接拒绝。
class GpsLegacyHal {
  public:
    using LocationFn = std::function<void(const GpsLocation&)>;
    using StatusFn = std::function<void(int32_t status)>;
    using SvStatusFn = std::function<void(const GpsSvStatus&)>;
    // cannon: MTK 真正使用的是新版 GnssSvStatus（槽 0x58），带每颗星的
    // constellation / flags。旧版 GpsSvInfo 只有 prn，会把北斗/GLONASS
    // 的 PRN 与 GPS 混淆，导致框架里全部被标成 GPS。
    using GnssSvStatusFn = std::function<void(const GnssSvStatus&)>;
    using NmeaFn = std::function<void(int64_t timestampMs, const std::string& nmea)>;
    using CapabilitiesFn = std::function<void(uint32_t capabilities)>;
    using SystemInfoFn = std::function<void(const GnssSystemInfo& info)>;
    using NameFn = std::function<void(const std::string& name)>;
    using AcquireWakelockFn = std::function<void()>;
    using ReleaseWakelockFn = std::function<void()>;
    using RequestTimeFn = std::function<void()>;

    static GpsLegacyHal& get();

    void setCallbacks(LocationFn location, StatusFn status, SvStatusFn svStatus, NmeaFn nmea,
                      CapabilitiesFn capabilities, SystemInfoFn systemInfo, NameFn name,
                      AcquireWakelockFn acquireWakelock, ReleaseWakelockFn releaseWakelock,
                      RequestTimeFn requestTime, GnssSvStatusFn gnssSvStatus = nullptr);

    bool init();
    bool start();
    void stop();
    void cleanup();

    bool setPositionMode(int mode, int recurrence, int minIntervalMs, int preferredAccuracyMs,
                         int preferredTimeMs);
    bool injectTime(int64_t timeMs, int64_t timeReferenceMs, int32_t uncertaintyMs);
    bool injectLocation(double latitudeDegrees, double longitudeDegrees, float accuracyMeters);
    bool deleteAidingData(int flags);

    // 模块回调入口（C 链接的静态函数转发到这里）
    void dispatchLocation(const GpsLocation& location);
    void dispatchStatus(int32_t status);
    void dispatchSvStatus(const GpsSvStatus& svStatus);
    void dispatchGnssSvStatus(const GnssSvStatus& svStatus);
    void dispatchNmea(int64_t timestampMs, const std::string& nmea);
    void dispatchCapabilities(uint32_t capabilities);
    void dispatchSystemInfo(const GnssSystemInfo& info);
    void dispatchName(const std::string& name);
    void dispatchAcquireWakelock();
    void dispatchReleaseWakelock();
    void dispatchRequestTime();

  private:
    GpsLegacyHal() = default;

    bool ensureInterface();

    std::mutex mMutex;
    const GpsInterface* mInterface = nullptr;
    bool mInitialized = false;
    bool mStarted = false;

    LocationFn mLocation;
    StatusFn mStatus;
    SvStatusFn mSvStatus;
    GnssSvStatusFn mGnssSvStatus;
    NmeaFn mNmea;
    CapabilitiesFn mCapabilities;
    SystemInfoFn mSystemInfo;
    NameFn mName;
    AcquireWakelockFn mAcquireWakelock;
    ReleaseWakelockFn mReleaseWakelock;
    RequestTimeFn mRequestTime;
};
