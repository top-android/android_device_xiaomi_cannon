#!/system/bin/sh
# cannon debug watchdog: 开机 120s 还没 boot_completed，就 dump 现场并重启到 bootloader。
# 结果文件：/metadata/bootlog_stuck.txt（重启后仍可读，进 recovery 后 cat 即可）
#
# 注意：init 卡住时它自己处理不了 sys.powerctl（单线程，正阻塞在动作里），
#       所以这里直接调 reboot 系统调用，不经过 init。

sleep 120

[ "$(getprop sys.boot_completed)" = "1" ] && exit 0

D=/metadata

{
    echo "=== boot stuck at $(date) ==="
    echo
    echo "--- /proc/cmdline"
    cat /proc/cmdline
    echo
    echo "--- init (pid 1) state"
    cat /proc/1/stat 2>/dev/null
    echo "wchan: $(cat /proc/1/wchan 2>/dev/null)"
    cat /proc/1/stack 2>/dev/null
    echo
    echo "--- init task stacks"
    for t in /proc/1/task/*; do
        echo "  tid $(basename $t) wchan=$(cat $t/wchan 2>/dev/null)"
        cat $t/stack 2>/dev/null
    done
    echo
    echo "--- dmesg"
    dmesg
    echo
    echo "--- ps -A -T"
    ps -A -T
    echo
    echo "--- per-process wchan / stack"
    for p in /proc/[0-9]*; do
        echo "### $p $(cat $p/comm 2>/dev/null) wchan=$(cat $p/wchan 2>/dev/null)"
        cat "$p/stack" 2>/dev/null
    done
    echo
    echo "--- logcat (last dump)"
    logcat -b all -d 2>/dev/null
} > "$D/bootlog_stuck.txt" 2>&1

# 单独再存一份内核日志，方便只看内核侧
dmesg > "$D/bootlog_kmsg.txt" 2>/dev/null

sync

# 回 bootloader（不走 init，直接系统调用）
/system/bin/reboot bootloader 2>/dev/null
# 兜底：上面失败就直接 sysrq 重启
echo b > /proc/sysrq-trigger 2>/dev/null
