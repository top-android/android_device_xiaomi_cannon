/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * A12 vendor blobs (MTK camera HAL: libmtkcam_device3_app.so) call
 * android::Thread::run() before the Thread object is adopted by an sp<>.
 * Android 14's libutils then does, inside Thread::run():
 *
 *     mHoldSelf = sp<Thread>::fromExisting(this);
 *
 * which calls RefBase::incStrongRequireStrong() and aborts with
 *   "incStrongRequireStrong() called on ... which isn't already owned".
 *
 * Thread::run() is referenced by the blobs through the PLT (unlike the
 * libutils-internal incStrongRequireStrong call, which is a local branch and
 * cannot be interposed), so overriding it here takes effect. We pre-own the
 * object so fromExisting() succeeds, then drop that extra reference; the one
 * taken by fromExisting() is stored in mHoldSelf and released when the thread
 * exits, keeping the strong refcount balanced. For Threads that are already
 * owned (the normal case) this is a no-op (inc/dec cancel out).
 */
#include <utils/Thread.h>
#include <dlfcn.h>
#include <stdint.h>

namespace android {

status_t Thread::run(const char* name, int32_t priority, size_t stack) {
    using RunFn = status_t (*)(Thread*, const char*, int32_t, size_t);
    static RunFn real_run = reinterpret_cast<RunFn>(
            dlsym(RTLD_NEXT, "_ZN7android6Thread3runEPKcim"));
    if (real_run == nullptr) {
        return INVALID_OPERATION;
    }

    this->incStrong(this);                       // ensure owned (0 -> 1, onFirstRef)
    status_t res = real_run(this, name, priority, stack);  // fromExisting: 1 -> 2
    this->decStrong(this);                       // 2 -> 1 (mHoldSelf owns 1)
    return res;
}

}  // namespace android
