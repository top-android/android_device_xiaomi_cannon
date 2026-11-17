// cannon GNSS 探针 v2：定位 gpshal_gpscbs_save 需要的回调槽并验证 112 字节布局
#include <fcntl.h>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstddef>
#include <cstdio>
#include <cstring>

#include <hardware/gps.h>
#include <hardware/hardware.h>

static void logSlot(const char* who, int slot) {
    printf("[cb] %s slot=0x%02x\n", who, slot);
    fflush(stdout);
}

static void cbLoc(GpsLocation*) { logSlot("location", 0x08); }
static void cbStatus(GpsStatus*) { logSlot("status", 0x10); }
static void cbSv(GpsSvStatus*) { logSlot("sv_status", 0x18); }
static void cbNmea(GpsUtcTime, const char*, int) { logSlot("nmea", 0x20); }
static void cbCap(uint32_t caps) { printf("[cb] set_capabilities 0x%x\n", caps); fflush(stdout); }
static void cbAcq() { logSlot("acquire_wakelock", 0x30); }
static void cbRel() { logSlot("release_wakelock", 0x38); }
static void cbUtc() { logSlot("request_utc", 0x48); }
static void cbSysInfo(const GnssSystemInfo* info) {
    printf("[cb] set_system_info year=%d\n", info ? info->year_of_hw : -1);
    fflush(stdout);
}
static void cbGnssSv(GnssSvStatus*) { logSlot("gnss_sv_status", 0x58); }
static void cbName(const char* name, size_t len) {
    printf("[cb] NAME(0x60) len=%zu str=%.*s\n", len, (int)(len > 64 ? 64 : len), name ? name : "(null)");
    fflush(stdout);
}
static void cbSlot68(void) { logSlot("slot_0x68", 0x68); }

struct ThreadArg {
    void (*start)(void*);
    void* arg;
};
static void* trampoline(void* p) {
    auto* a = static_cast<ThreadArg*>(p);
    a->start(a->arg);
    return nullptr;
}
static pthread_t cbThread(const char* name, void (*start)(void*), void* arg) {
    printf("[cb] create_thread(%s)\n", name ? name : "?");
    fflush(stdout);
    pthread_t t{};
    if (start == nullptr) return t;
    auto* a = new ThreadArg{start, arg};
    if (pthread_create(&t, nullptr, trampoline, a) != 0) return pthread_t{};
    return t;
}

static bool socketExists() {
    int fd = ::open("/proc/net/unix", O_RDONLY);
    if (fd < 0) return false;
    char buf[262144];
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0) return false;
    buf[n] = 0;
    return std::strstr(buf, "mtk_mnl2hal") != nullptr;
}

// MTK 期望的 13 指针布局：0x60 = name_cb，0x68 = 未知（init 阶段未调用）
struct Callbacks112 {
    GpsCallbacks cb;
    void (*name_cb)(const char*, size_t);
    void (*slot68)(void);
};

static void fill(Callbacks112* c) {
    std::memset(c, 0, sizeof(*c));
    c->cb.size = sizeof(Callbacks112);
    c->cb.location_cb = cbLoc;
    c->cb.status_cb = cbStatus;
    c->cb.sv_status_cb = cbSv;
    c->cb.nmea_cb = cbNmea;
    c->cb.set_capabilities_cb = cbCap;
    c->cb.acquire_wakelock_cb = cbAcq;
    c->cb.release_wakelock_cb = cbRel;
    c->cb.create_thread_cb = cbThread;
    c->cb.request_utc_time_cb = cbUtc;
    c->cb.set_system_info_cb = cbSysInfo;
    c->cb.gnss_sv_status_cb = cbGnssSv;
    c->name_cb = cbName;
    c->slot68 = cbSlot68;
}

static void runStage(const char* tag, bool padded) {
    pid_t pid = fork();
    if (pid != 0) {
        int st = 0;
        waitpid(pid, &st, 0);
        if (WIFSIGNALED(st)) {
            printf("== %s: killed by signal %d\n", tag, WTERMSIG(st));
        } else {
            printf("== %s: exit %d\n", tag, WEXITSTATUS(st));
        }
        fflush(stdout);
        return;
    }

    const hw_module_t* module = nullptr;
    int rc = hw_get_module(GPS_HARDWARE_MODULE_ID, &module);
    if (rc != 0 || module == nullptr) {
        printf("%s: hw_get_module rc=%d\n", tag, rc);
        _exit(10);
    }
    gps_device_t* dev = nullptr;
    rc = module->methods->open(module, GPS_HARDWARE_MODULE_ID, (hw_device_t**)&dev);
    if (rc != 0 || dev == nullptr) {
        printf("%s: open rc=%d\n", tag, rc);
        _exit(11);
    }
    const GpsInterface* itf = dev->get_gps_interface(dev);
    printf("%s: interface=%p size=%zu\n", tag, (const void*)itf, itf ? itf->size : 0);
    fflush(stdout);
    if (itf == nullptr) _exit(12);

    static Callbacks112 cbs;
    fill(&cbs);
    if (!padded) {
        cbs.cb.size = sizeof(GpsCallbacks);
        cbs.name_cb = nullptr;
        cbs.slot68 = nullptr;
    }
    printf("%s: calling init(size=%zu)\n", tag, cbs.cb.size);
    fflush(stdout);

    int r = itf->init(&cbs.cb);
    printf("%s: init rc=%d socket=%d\n", tag, r, socketExists());
    fflush(stdout);

    if (r == 0) {
        int rs = itf->start ? itf->start() : -1;
        printf("%s: start rc=%d socket=%d\n", tag, rs, socketExists());
        fflush(stdout);
        for (int i = 1; i <= 8; i++) {
            sleep(1);
            printf("%s: t+%ds socket=%d\n", tag, i, socketExists());
            fflush(stdout);
        }
        if (itf->stop) itf->stop();
    }
    _exit(0);
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("sizeof(GpsCallbacks)=%zu (0x%zx)\n", sizeof(GpsCallbacks), sizeof(GpsCallbacks));
    printf("sizeof(Callbacks112)=%zu (0x%zx), name_cb off=0x%zx\n",
           sizeof(Callbacks112), sizeof(Callbacks112), offsetof(Callbacks112, name_cb));
    printf("socket before=%d\n", socketExists());
    fflush(stdout);

    runStage("stage1-96", false);
    runStage("stage2-112", true);

    printf("socket after=%d\n", socketExists());
    return 0;
}
