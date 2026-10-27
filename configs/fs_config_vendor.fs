#
# 2026-10-27  蓝牙 A2DP 无声 —— 让 audio HAL 进程看不到 vndservicemanager
#
# 背景：
#   hardware/interfaces/audio/common/all-versions/default/service/service.cpp:78
#     if (ProcessState::isVndservicemanagerEnabled()) {
#         ProcessState::initWithDriver("/dev/vndbinder");   // 整个进程改绑 vndbinder
#     }
#   isVndservicemanagerEnabled() = access("/vendor/bin/vndservicemanager", R_OK) == 0
#   （frameworks/native/libs/binder/ProcessState.cpp:106，DAC 检查，不走 SELinux）
#
#   本机 /vendor/bin/vndservicemanager 是 A12 原厂 blob（cannon-vendor.mk 整包拷入），
#   于是 audio HAL 进程被绑到 vndbinder，audio.bluetooth.default.so 在里面注册的
#   IBluetoothAudioProviderFactory 落到 vndservicemanager；而系统蓝牙栈查的是
#   servicemanager（/dev/binder），两边不是同一个 binder 域，永远互相看不见。
#
#   这里把该文件改成 0700 + owner=AID_SYSTEM：
#     - vndservicemanager 自己以 user system(1000) 运行（vndservicemanager.rc），
#       是 owner，照常可执行；
#     - audio HAL 以 uid 1041 运行（user audioserver），既不是 owner 也没有 other 位，
#       即使它的 group 列表里含 system 也读不到 -> 探测返回 false -> 留在 /dev/binder。
#   codec2 / omx 等仍以 vndbinder 注册的 vendor 服务不受影响。
#
[vendor/bin/vndservicemanager]
mode: 0700
user: AID_SYSTEM
group: AID_SYSTEM
# fs_config 要求四项齐全；0 = 不授予任何 capability
caps: 0
