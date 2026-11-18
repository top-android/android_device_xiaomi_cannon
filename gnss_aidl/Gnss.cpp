/*
 * Copyright (C) 2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define LOG_TAG "GnssAidl"

#include "Gnss.h"
#include <inttypes.h>
#include <log/log.h>
#include <utils/Timers.h>
#include "AGnss.h"
#include "AGnssRil.h"
#include "DeviceFileReader.h"
#include "FixLocationParser.h"
#include "GnssAntennaInfo.h"
#include "GnssAssistanceInterface.h"
#include "GnssBatching.h"
#include "GnssConfiguration.h"
#include "GnssDebug.h"
#include "GnssGeofence.h"
#include "GnssNavigationMessageInterface.h"
#include "GnssPsds.h"
#include "GnssVisibilityControl.h"
#include "MeasurementCorrectionsInterface.h"
#include "Utils.h"

namespace aidl::android::hardware::gnss {
using ::android::hardware::gnss::common::Utils;

using ndk::ScopedAStatus;
using GnssSvInfo = IGnssCallback::GnssSvInfo;

constexpr int TTFF_MILLIS = 2200;

std::shared_ptr<IGnssCallback> Gnss::sGnssCallback = nullptr;

Gnss::Gnss() : mMinIntervalMs(1000), mFirstFixReceived(false) {}

ScopedAStatus Gnss::setCallback(const std::shared_ptr<IGnssCallback>& callback) {
    ALOGD("setCallback");
    if (callback == nullptr) {
        ALOGE("%s: Null callback ignored", __func__);
        return ScopedAStatus::fromExceptionCode(STATUS_INVALID_OPERATION);
    }
    {
        std::unique_lock<std::mutex> lock(mMutex);
        sGnssCallback = callback;
    }

    int capabilities =
            (int)(IGnssCallback::CAPABILITY_MEASUREMENTS | IGnssCallback::CAPABILITY_SCHEDULING |
                  IGnssCallback::CAPABILITY_SATELLITE_BLOCKLIST |
                  IGnssCallback::CAPABILITY_SATELLITE_PVT |
                  IGnssCallback::CAPABILITY_CORRELATION_VECTOR |
                  IGnssCallback::CAPABILITY_ANTENNA_INFO |
                  IGnssCallback::CAPABILITY_ACCUMULATED_DELTA_RANGE);
    auto status = callback->gnssSetCapabilitiesCb(capabilities);
    if (!status.isOk()) {
        ALOGE("%s: Unable to invoke callback.gnssSetCapabilitiesCb", __func__);
    }

    IGnssCallback::GnssSystemInfo systemInfo = {
            .yearOfHw = 2022,
            .name = "Google, Cuttlefish, AIDL v3",
    };
    status = callback->gnssSetSystemInfoCb(systemInfo);
    if (!status.isOk()) {
        ALOGE("%s: Unable to invoke callback.gnssSetSystemInfoCb", __func__);
    }
    GnssSignalType signalType1 = {
            .constellation = GnssConstellationType::GPS,
            .carrierFrequencyHz = 1.57542e+09,
            .codeType = GnssSignalType::CODE_TYPE_C,
    };
    GnssSignalType signalType2 = {
            .constellation = GnssConstellationType::GLONASS,
            .carrierFrequencyHz = 1.5980625e+09,
            .codeType = GnssSignalType::CODE_TYPE_C,
    };
    status = callback->gnssSetSignalTypeCapabilitiesCb(
            std::vector<GnssSignalType>({signalType1, signalType2}));
    if (!status.isOk()) {
        ALOGE("%s: Unable to invoke callback.gnssSetSignalTypeCapabilitiesCb", __func__);
    }

    // cannon: 注册 MTK legacy gps.h 回调
    registerLegacyCallbacks();

    // In case when the setCallback() and close() calls are not balanced
    mIsInitialized = false;
    mIsActive = false;
    mThreadBlocker.notify();
    if (mThread.joinable()) {
        mThread.join();
    }

    mIsInitialized = true;
    mThreadBlocker.reset();
    mThread = std::thread([this]() {
        while (mIsInitialized) {
            if (mIsActive) {
                if (mUseLegacyHal) {
                    // 数据由 GpsLegacyHal 回调直接投递，这里只维持线程存活
                    mThreadBlocker.wait_for(std::chrono::milliseconds(500));
                    continue;
                }
                if (mReportedLocationCount == 0) {
                    if (!mGnssMeasurementEnabled || mMinIntervalMs <= mGnssMeasurementIntervalMs) {
                        this->reportSvStatus();
                    }
                    if (!mFirstFixReceived) {
                        // Simulate the code start TTFF
                        std::this_thread::sleep_for(std::chrono::milliseconds(TTFF_MILLIS));
                        mFirstFixReceived = true;
                    }
                }
                if (!mGnssMeasurementEnabled || mMinIntervalMs <= mGnssMeasurementIntervalMs) {
                    this->reportSvStatus();
                }
                this->reportNmea();

                auto currentLocation = getLocationFromHW();
                mGnssPowerIndication->notePowerConsumption();
                if (currentLocation != nullptr) {
                    this->reportLocation(*currentLocation);
                } else {
                    const auto location = Utils::getMockLocation();
                    this->reportLocation(location);
                }
                mReportedLocationCount += 1;
                mThreadBlocker.wait_for(std::chrono::milliseconds(mMinIntervalMs));
            } else {
                // Wait indefinitely until start() or close() is called
                mThreadBlocker.wait();
            }
        }
    });

    return ScopedAStatus::ok();
}

std::unique_ptr<GnssLocation> Gnss::getLocationFromHW() {
    if (!::android::hardware::gnss::common::ReplayUtils::hasFixedLocationDeviceFile()) {
        return nullptr;
    }
    std::string inputStr =
            ::android::hardware::gnss::common::DeviceFileReader::Instance().getLocationData();
    return ::android::hardware::gnss::common::FixLocationParser::getLocationFromInputStr(inputStr);
}

ScopedAStatus Gnss::start() {
    ALOGD("start");
    if (mIsActive) {
        ALOGW("Gnss has started. Restarting...");
        stop();
    }
    mIsActive = true;
    if (mUseLegacyHal) {
        if (!GpsLegacyHal::get().init() || !GpsLegacyHal::get().start()) {
            ALOGE("cannon: legacy gps init/start failed");
            mIsActive = false;
            return ScopedAStatus::fromExceptionCode(STATUS_INVALID_OPERATION);
        }
    }
    // notify measurement engine to update measurement interval
    mGnssMeasurementInterface->setLocationEnabled(true);
    this->reportGnssStatusValue(IGnssCallback::GnssStatusValue::SESSION_BEGIN);
    mThreadBlocker.notify();
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::stop() {
    ALOGD("stop");
    mIsActive = false;
    if (mUseLegacyHal) {
        GpsLegacyHal::get().stop();
    }
    mGnssMeasurementInterface->setLocationEnabled(false);
    this->reportGnssStatusValue(IGnssCallback::GnssStatusValue::SESSION_END);

    int reportedLocationCount = mReportedLocationCount;
    ALOGD("reportedLocationCount: %d", reportedLocationCount);
    mReportedLocationCount = 0;
    mThreadBlocker.notify();
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::close() {
    ALOGD("close");
    {
        std::unique_lock<std::mutex> lock(mMutex);
        sGnssCallback = nullptr;
    }
    mIsInitialized = false;
    mThreadBlocker.notify();
    if (mThread.joinable()) {
        mThread.join();
    }
    return ScopedAStatus::ok();
}

void Gnss::reportLocation(const GnssLocation& location) {
    std::shared_ptr<IGnssCallback> callback;
    {
        std::unique_lock<std::mutex> lock(mMutex);
        if (sGnssCallback == nullptr) {
            ALOGE("%s: GnssCallback is null.", __func__);
            return;
        }
        callback = sGnssCallback;
    }
    mLastLocation = std::make_shared<GnssLocation>(location);
    auto status = callback->gnssLocationCb(location);
    if (!status.isOk()) {
        ALOGE("%s: Unable to invoke gnssLocationCb", __func__);
    }
    return;
}

// （已移除按 prn 推断星座的函数：北斗/GLONASS 的 prn 与 GPS 重叠，
//   推断必然出错，改为直接使用模块上报的 constellation。）

// cannon: 解析 NMEA GSV 构建卫星列表。MTK 的 GnssSvStatus 二进制布局与
// AOSP gps.h 不一致（多出字段），直接用会错位；GSV 是文本协议，talker 标明
// 星座，不会错位，而且芯片已经把全部 in-view 卫星都输出成 GSV 了。
void Gnss::handleNmeaForSv(const std::string& nmea) {
    size_t gsv = nmea.find("GSV,");
    if (gsv == std::string::npos || gsv < 2) {
        return;
    }
    {
        static int sEnter = 0;
        if (sEnter < 6) {
            ALOGD("SVDBG enter talker=%.2s len=%zu", nmea.c_str() + (gsv - 2), nmea.size());
            sEnter++;
        }
    }
    const std::string talker = nmea.substr(gsv - 2, 2);

    GnssConstellationType fixedConst{};
    bool known = true;
    if (talker == "GP") {
        fixedConst = GnssConstellationType::GPS;
    } else if (talker == "GL") {
        fixedConst = GnssConstellationType::GLONASS;
    } else if (talker == "GA") {
        fixedConst = GnssConstellationType::GALILEO;
    } else if (talker == "GB") {
        fixedConst = GnssConstellationType::BEIDOU;
    } else if (talker == "GQ") {
        fixedConst = GnssConstellationType::QZSS;
    } else {
        known = false;  // GN 混合句
    }

    std::string body = nmea;
    size_t star = body.rfind('*');
    if (star != std::string::npos) {
        body.resize(star);
    }

    std::vector<std::string> f;
    size_t start = 0;
    while (true) {
        size_t comma = body.find(',', start);
        if (comma == std::string::npos) {
            f.push_back(body.substr(start));
            break;
        }
        f.push_back(body.substr(start, comma - start));
        start = comma + 1;
    }
    if (f.size() < 4) {
        return;
    }

    std::lock_guard<std::mutex> lock(mGsvMutex);
    for (size_t i = 4; i + 3 < f.size(); i += 4) {
        int prn = std::atoi(f[i].c_str());
        if (prn <= 0) {
            continue;
        }
        float elev = std::atof(f[i + 1].c_str());
        float azim = std::atof(f[i + 2].c_str());
        float snr = f[i + 3].empty() ? 0.0f : std::atof(f[i + 3].c_str());

        GnssConstellationType c = fixedConst;
        if (!known) {
            if (prn >= 65 && prn <= 96) {
                c = GnssConstellationType::GLONASS;
            } else if (prn >= 193 && prn <= 200) {
                c = GnssConstellationType::QZSS;
            } else if (prn >= 201 && prn <= 237) {
                c = GnssConstellationType::BEIDOU;
            } else if (prn >= 301 && prn <= 336) {
                c = GnssConstellationType::GALILEO;
            } else {
                c = GnssConstellationType::GPS;
            }
        }

        uint64_t key = (static_cast<uint64_t>(c) << 32) | static_cast<uint32_t>(prn);
        IGnssCallback::GnssSvInfo info{};
        info.svid = prn;
        info.constellation = c;
        info.cN0Dbhz = snr;
        info.elevationDegrees = elev;
        info.azimuthDegrees = azim;
        info.svFlag = static_cast<int32_t>(IGnssCallback::GnssSvFlags::HAS_ALMANAC_DATA);
        if (snr > 0.0f) {
            info.svFlag |= static_cast<int32_t>(IGnssCallback::GnssSvFlags::HAS_EPHEMERIS_DATA);
        }
        mGsvMap[key] = info;
    }

    // 1 秒节流上报，避免每条 GSV 都触发一次 binder 回调
    auto now = std::chrono::steady_clock::now();
    if (mLastGsvReport.time_since_epoch().count() != 0 &&
        now - mLastGsvReport < std::chrono::milliseconds(1000)) {
        return;
    }
    mLastGsvReport = now;

    std::vector<IGnssCallback::GnssSvInfo> list;
    list.reserve(mGsvMap.size());
    for (const auto& kv : mGsvMap) {
        list.push_back(kv.second);
    }
    {
        static int sRep = 0;
        if (sRep < 6) {
            ALOGD("SVDBG report cnt=%zu", list.size());
            sRep++;
        }
    }
    reportSvStatus(list);
}

void Gnss::reportSvStatus() const {
    if (mIsSvStatusActive) {
        auto svStatus = filterBlocklistedSatellites(Utils::getMockSvInfoList());
        reportSvStatus(svStatus);
    }
}

void Gnss::reportSvStatus(const std::vector<GnssSvInfo>& svInfoList) const {
    std::shared_ptr<IGnssCallback> callback;
    {
        std::unique_lock<std::mutex> lock(mMutex);
        if (sGnssCallback == nullptr) {
            ALOGE("%s: GnssCallback is null.", __func__);
            return;
        }
        callback = sGnssCallback;
    }
    auto status = callback->gnssSvStatusCb(svInfoList);
    if (!status.isOk()) {
        ALOGE("%s: Unable to invoke callback", __func__);
    }
}

std::vector<GnssSvInfo> Gnss::filterBlocklistedSatellites(
        std::vector<GnssSvInfo> gnssSvInfoList) const {
    for (uint32_t i = 0; i < gnssSvInfoList.size(); i++) {
        if (mGnssConfiguration->isBlocklisted(gnssSvInfoList[i])) {
            gnssSvInfoList[i].svFlag &= ~(uint32_t)IGnssCallback::GnssSvFlags::USED_IN_FIX;
        }
    }
    return gnssSvInfoList;
}

void Gnss::reportGnssStatusValue(const IGnssCallback::GnssStatusValue gnssStatusValue) const {
    std::shared_ptr<IGnssCallback> callback;
    {
        std::unique_lock<std::mutex> lock(mMutex);
        if (sGnssCallback == nullptr) {
            ALOGE("%s: GnssCallback is null.", __func__);
            return;
        }
        callback = sGnssCallback;
    }
    auto status = callback->gnssStatusCb(gnssStatusValue);
    if (!status.isOk()) {
        ALOGE("%s: Unable to invoke gnssStatusCb", __func__);
    }
}

void Gnss::reportNmea() const {
    if (mIsNmeaActive) {
        std::shared_ptr<IGnssCallback> callback;
        {
            std::unique_lock<std::mutex> lock(mMutex);
            if (sGnssCallback == nullptr) {
                ALOGE("%s: GnssCallback is null.", __func__);
                return;
            }
            callback = sGnssCallback;
        }
        nsecs_t now = systemTime(SYSTEM_TIME_MONOTONIC);
        auto status = callback->gnssNmeaCb(now, "$TEST,0,1,2,3,4,5");
        if (!status.isOk()) {
            ALOGE("%s: Unable to invoke callback", __func__);
        }
    }
}

ScopedAStatus Gnss::startSvStatus() {
    ALOGD("startSvStatus");
    mIsSvStatusActive = true;
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::stopSvStatus() {
    ALOGD("stopSvStatus");
    mIsSvStatusActive = false;
    return ScopedAStatus::ok();
}
ScopedAStatus Gnss::startNmea() {
    ALOGD("startNmea");
    mIsNmeaActive = true;
    return ScopedAStatus::ok();
}
ScopedAStatus Gnss::stopNmea() {
    ALOGD("stopNmea");
    mIsNmeaActive = false;
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionAGnss(std::shared_ptr<IAGnss>* iAGnss) {
    ALOGD("Gnss::getExtensionAGnss");
    *iAGnss = SharedRefBase::make<AGnss>();
    return ndk::ScopedAStatus::ok();
}

ScopedAStatus Gnss::injectTime(int64_t timeMs, int64_t timeReferenceMs, int uncertaintyMs) {
    ALOGD("injectTime. timeMs:%" PRId64 ", timeReferenceMs:%" PRId64 ", uncertaintyMs:%d", timeMs,
          timeReferenceMs, uncertaintyMs);
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionAGnssRil(std::shared_ptr<IAGnssRil>* iAGnssRil) {
    ALOGD("Gnss::getExtensionAGnssRil");
    *iAGnssRil = SharedRefBase::make<AGnssRil>();
    return ndk::ScopedAStatus::ok();
}

ScopedAStatus Gnss::injectLocation(const GnssLocation& location) {
    ALOGD("injectLocation. lat:%lf, lng:%lf, acc:%f", location.latitudeDegrees,
          location.longitudeDegrees, location.horizontalAccuracyMeters);
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::injectBestLocation(const GnssLocation& location) {
    ALOGD("injectBestLocation. lat:%lf, lng:%lf, acc:%f", location.latitudeDegrees,
          location.longitudeDegrees, location.horizontalAccuracyMeters);
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::deleteAidingData(GnssAidingData aidingDataFlags) {
    ALOGD("deleteAidingData. flags:%d", (int)aidingDataFlags);
    mFirstFixReceived = false;
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::setPositionMode(const PositionModeOptions& options) {
    ALOGD("setPositionMode. minIntervalMs:%d, lowPowerMode:%d", options.minIntervalMs,
          (int)options.lowPowerMode);
    if (std::max(1000, options.minIntervalMs) != mMinIntervalMs) {
        mMinIntervalMs = std::max(1000, options.minIntervalMs);
        mGnssMeasurementInterface->setLocationInterval(mMinIntervalMs);
        if (mIsActive) {
            stop();
            start();
        }
    }
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionPsds(std::shared_ptr<IGnssPsds>* iGnssPsds) {
    ALOGD("getExtensionPsds");
    *iGnssPsds = SharedRefBase::make<GnssPsds>();
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionGnssConfiguration(
        std::shared_ptr<IGnssConfiguration>* iGnssConfiguration) {
    ALOGD("getExtensionGnssConfiguration");
    if (mGnssConfiguration == nullptr) {
        mGnssConfiguration = SharedRefBase::make<GnssConfiguration>();
    }
    *iGnssConfiguration = mGnssConfiguration;
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionGnssPowerIndication(
        std::shared_ptr<IGnssPowerIndication>* iGnssPowerIndication) {
    ALOGD("getExtensionGnssPowerIndication");
    if (mGnssPowerIndication == nullptr) {
        mGnssPowerIndication = SharedRefBase::make<GnssPowerIndication>();
    }

    *iGnssPowerIndication = mGnssPowerIndication;
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionGnssMeasurement(
        std::shared_ptr<IGnssMeasurementInterface>* iGnssMeasurement) {
    ALOGD("getExtensionGnssMeasurement");
    if (mGnssMeasurementInterface == nullptr) {
        mGnssMeasurementInterface = SharedRefBase::make<GnssMeasurementInterface>();
        mGnssMeasurementInterface->setGnssInterface(static_cast<std::shared_ptr<Gnss>>(this));
    }
    *iGnssMeasurement = mGnssMeasurementInterface;
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionGnssBatching(std::shared_ptr<IGnssBatching>* iGnssBatching) {
    ALOGD("getExtensionGnssBatching");

    *iGnssBatching = SharedRefBase::make<GnssBatching>();
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionGnssGeofence(std::shared_ptr<IGnssGeofence>* iGnssGeofence) {
    ALOGD("getExtensionGnssGeofence");

    *iGnssGeofence = SharedRefBase::make<GnssGeofence>();
    return ScopedAStatus::ok();
}

ScopedAStatus Gnss::getExtensionGnssNavigationMessage(
        std::shared_ptr<IGnssNavigationMessageInterface>* iGnssNavigationMessage) {
    ALOGD("getExtensionGnssNavigationMessage");

    *iGnssNavigationMessage = SharedRefBase::make<GnssNavigationMessageInterface>();
    return ScopedAStatus::ok();
}

ndk::ScopedAStatus Gnss::getExtensionGnssDebug(std::shared_ptr<IGnssDebug>* iGnssDebug) {
    ALOGD("Gnss::getExtensionGnssDebug");
    *iGnssDebug = SharedRefBase::make<GnssDebug>();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Gnss::getExtensionGnssVisibilityControl(
        std::shared_ptr<visibility_control::IGnssVisibilityControl>* iGnssVisibilityControl) {
    ALOGD("Gnss::getExtensionGnssVisibilityControl");

    *iGnssVisibilityControl = SharedRefBase::make<visibility_control::GnssVisibilityControl>();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Gnss::getExtensionGnssAntennaInfo(
        std::shared_ptr<IGnssAntennaInfo>* iGnssAntennaInfo) {
    ALOGD("Gnss::getExtensionGnssAntennaInfo");

    *iGnssAntennaInfo = SharedRefBase::make<GnssAntennaInfo>();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Gnss::getExtensionMeasurementCorrections(
        std::shared_ptr<measurement_corrections::IMeasurementCorrectionsInterface>*
                iMeasurementCorrections) {
    ALOGD("Gnss::getExtensionMeasurementCorrections");

    *iMeasurementCorrections =
            SharedRefBase::make<measurement_corrections::MeasurementCorrectionsInterface>();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus Gnss::getExtensionGnssAssistanceInterface(
        std::shared_ptr<gnss_assistance::IGnssAssistanceInterface>* iGnssAssistanceInterface) {
    ALOGD("Gnss::getExtensionGnssAssistanceInterface");

    *iGnssAssistanceInterface = SharedRefBase::make<gnss_assistance::GnssAssistanceInterface>();
    return ndk::ScopedAStatus::ok();
}

void Gnss::setGnssMeasurementEnabled(const bool enabled) {
    mGnssMeasurementEnabled = enabled;
}

void Gnss::setGnssMeasurementInterval(const long intervalMs) {
    mGnssMeasurementIntervalMs = intervalMs;
}

std::shared_ptr<GnssLocation> Gnss::getLastLocation() const {
    return mLastLocation;
}

// cannon: 把 MTK legacy gps.h 的回调转成 AIDL IGnssCallback
void Gnss::registerLegacyCallbacks() {
    mUseLegacyHal = true;

    GpsLegacyHal::get().setCallbacks(
            [this](const GpsLocation& in) {
                GnssLocation out{};
                out.gnssLocationFlags = in.flags;
                out.latitudeDegrees = in.latitude;
                out.longitudeDegrees = in.longitude;
                out.altitudeMeters = in.altitude;
                out.speedMetersPerSec = in.speed;
                out.bearingDegrees = in.bearing;
                out.horizontalAccuracyMeters = in.accuracy;
                out.timestampMillis = static_cast<long>(in.timestamp);
                reportLocation(out);
            },
            [this](int32_t status) {
                IGnssCallback::GnssStatusValue value = IGnssCallback::GnssStatusValue::NONE;
                switch (status) {
                    case GPS_STATUS_SESSION_BEGIN:
                        value = IGnssCallback::GnssStatusValue::SESSION_BEGIN;
                        break;
                    case GPS_STATUS_SESSION_END:
                        value = IGnssCallback::GnssStatusValue::SESSION_END;
                        break;
                    case GPS_STATUS_ENGINE_ON:
                        value = IGnssCallback::GnssStatusValue::ENGINE_ON;
                        break;
                    case GPS_STATUS_ENGINE_OFF:
                        value = IGnssCallback::GnssStatusValue::ENGINE_OFF;
                        break;
                    default:
                        break;
                }
                reportGnssStatusValue(value);
            },
            // cannon: 旧版 GpsSvStatus 没有 constellation 字段，北斗(prn 1~37)
            // 会和 GPS(1~32) 撞号，导致框架里全部显示成 GPS。这里不再使用，
            // 改用最后注册的新版 GnssSvStatus 回调。
            nullptr,
            [this](int64_t timestampMs, const std::string& nmea) {
                // cannon: 从 GSV 构建卫星列表（绕开 MTK 私有 SV 结构）
                handleNmeaForSv(nmea);
                std::shared_ptr<IGnssCallback> callback;
                {
                    std::unique_lock<std::mutex> lock(mMutex);
                    callback = sGnssCallback;
                }
                if (callback != nullptr && mIsNmeaActive) {
                    callback->gnssNmeaCb(timestampMs, nmea);
                }
            },
            nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
            // cannon: MTK 的 GnssSvStatus 二进制布局与 AOSP gps.h 不一致（带额外字段），
            // 按 gps.h 解析会错位：角度字段读到载波频率(1575.42MHz/1602MHz)、
            // num_svs 虚高(33 实际 11 颗)、每 3 个槽位才 1 颗真卫星。
            // 因此改为解析芯片输出的 NMEA GSV（见 handleNmeaForSv）。
            nullptr);
}


}  // namespace aidl::android::hardware::gnss