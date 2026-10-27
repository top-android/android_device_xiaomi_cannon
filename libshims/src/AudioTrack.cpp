/*
 * 2026-10-27  AudioTrack 旧构造函数的垫片（vtservice / libsink.so 用）
 *
 * A12 的 AudioTrack 构造函数把回调拆成两个参数：
 *     callback_t cbf, void* user            // typedef void (*callback_t)(int, void*, void*)
 * A14 换成了接口对象：
 *     const wp<IAudioTrackCallback>& callback
 * 于是 libsink.so（A12 blob）要的符号
 *     _ZN7android10AudioTrackC1E...PFviPvS5_ES5_i...
 * 在 A14 的 libaudioclient.so 里根本不存在，vtservice 直接 CANNOT LINK。
 *
 * 做法：包一层 IAudioTrackCallback，把 A14 的各个虚函数翻译回 A12 的
 * “一个 event 常量 + user 指针 + info 指针” 语义，再用 placement new 调真正的
 * A14 构造函数（mangled name 不同，不会递归）。
 *
 * 注意 info 指针的类型：A12 和 A14 的 AudioTrack::Buffer 字段布局一致
 * （frameCount / size / 数据指针 / sequence），所以把 Buffer* 直接当 void* 传下去
 * 给老代码是安全的。
 */

#include <media/AudioTrack.h>

#include <new>

#include <utils/RefBase.h>

namespace android {

// A12 的 callback_t
typedef void (*legacy_callback_t)(int event, void* user, void* info);

class LegacyAudioTrackCallback : public AudioTrack::IAudioTrackCallback {
  public:
    LegacyAudioTrackCallback(legacy_callback_t cb, void* user) : mCb(cb), mUser(user) {}

    size_t onMoreData(const AudioTrack::Buffer& buffer) override {
        if (mCb != nullptr) {
            mCb(AudioTrack::EVENT_MORE_DATA, mUser,
                const_cast<AudioTrack::Buffer*>(&buffer));
        }
        return buffer.size();
    }

    void onUnderrun() override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_UNDERRUN, mUser, nullptr);
    }

    void onLoopEnd(int32_t loopsRemaining) override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_LOOP_END, mUser, &loopsRemaining);
    }

    void onMarker(uint32_t markerPosition) override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_MARKER, mUser, &markerPosition);
    }

    void onNewPos(uint32_t newPos) override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_NEW_POS, mUser, &newPos);
    }

    void onBufferEnd() override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_BUFFER_END, mUser, nullptr);
    }

    void onNewIAudioTrack() override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_NEW_IAUDIOTRACK, mUser, nullptr);
    }

    void onStreamEnd() override {
        if (mCb != nullptr) mCb(AudioTrack::EVENT_STREAM_END, mUser, nullptr);
    }

    size_t onCanWriteMoreData(const AudioTrack::Buffer& buffer) override {
        if (mCb != nullptr) {
            mCb(AudioTrack::EVENT_CAN_WRITE_MORE_DATA, mUser,
                const_cast<AudioTrack::Buffer*>(&buffer));
        }
        return buffer.size();
    }

  private:
    legacy_callback_t mCb;
    void* mUser;
};

}  // namespace android

// A12 版 AudioTrack 构造函数
// android::AudioTrack::AudioTrack(audio_stream_type_t, unsigned int, audio_format_t,
//     audio_channel_mask_t, unsigned long, audio_output_flags_t,
//     void (*)(int, void*, void*), void*, int, audio_session_t,
//     android::AudioTrack::transfer_type, audio_offload_info_t const*,
//     android::content::AttributionSourceState const&, audio_attributes_t const*,
//     bool, float, int)
extern "C" void
_ZN7android10AudioTrackC1E19audio_stream_type_tj14audio_format_t20audio_channel_mask_tm20audio_output_flags_tPFviPvS5_ES5_i15audio_session_tNS0_13transfer_typeEPK20audio_offload_info_tRKNS_7content22AttributionSourceStateEPK18audio_attributes_tbfi(
        void* thiz, audio_stream_type_t streamType, uint32_t sampleRate, audio_format_t format,
        audio_channel_mask_t channelMask, size_t frameCount, audio_output_flags_t flags,
        void (*cbf)(int, void*, void*), void* user, int32_t notificationFrames,
        audio_session_t sessionId, android::AudioTrack::transfer_type transferType,
        const audio_offload_info_t* offloadInfo,
        const android::content::AttributionSourceState& attributionSource,
        const audio_attributes_t* pAttributes, bool doNotReconnect, float maxRequiredSpeed,
        int32_t selectedDeviceId) {
    android::sp<android::LegacyAudioTrackCallback> callback;
    if (cbf != nullptr) {
        callback = new android::LegacyAudioTrackCallback(cbf, user);
    }
    android::wp<android::AudioTrack::IAudioTrackCallback> wpCallback = callback;
    new (thiz) android::AudioTrack(
            streamType, sampleRate, format, channelMask, frameCount, flags, wpCallback,
            notificationFrames, sessionId, transferType, offloadInfo, attributionSource,
            pAttributes, doNotReconnect, maxRequiredSpeed,
            static_cast<audio_port_handle_t>(selectedDeviceId));
}
