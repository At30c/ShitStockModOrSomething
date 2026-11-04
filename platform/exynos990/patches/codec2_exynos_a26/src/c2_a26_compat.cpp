// Compatibility shim that lets the A26 (Exynos 1380, VNDK 33) Exynos Codec2
// HAL run on the Exynos 990 vendor (VNDK 30).  It provides the ABI contracts
// the A26 chain needs and the y2s runtime does not have, and adapts the A26
// ExynosVideoApi to the Exynos 990 MFC driver (see each section below):
//
//  1. android::Fence with the Android 12+ layout.  The VNDK 30 libui Fence is
//     non-virtual ({mCount@0, fd@4}); the A26 libcodec2_vndk constructs Fence
//     inline with a vptr ({vptr@0, mCount@8, fd@12}).  The A26 imports
//     (Fence(int), wait(int), dup(), vtable) are renamed in place to
//     c2compa::Fence (same length as "android") so they never reach the VNDK 30
//     implementation.
//  2. ExynosGraphicBufferMeta::get_cstride(), missing from the Exynos 990
//     libexynosgraphicbuffer.  It is derived from the 990 accessors so the
//     990 private_handle layout stays owned by the 990 library.
//  3. AcrylicCanvas::setStride(), missing from the Exynos 990 libacryl.  The
//     990 AcrylicCanvas has no per-plane stride storage (canvas_type sits at
//     +0x84 where the A26 class keeps the strides), so writing would corrupt
//     the object; the call is accepted and ignored.

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <android/log.h>
#include <linux/sync_file.h>
#include <linux/videodev2.h>

#define C2A26_PIX_FMT_NV12N_10B v4l2_fourcc('B', 'N', '1', '2')
#define C2A26_PIX_FMT_NV12M_S10B v4l2_fourcc('B', 'M', '1', '2')
#include <dlfcn.h>
#include <sys/epoll.h>

#define EXPORT __attribute__((visibility("default")))
#define LOG_TAG "c2-a26-compat"
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

struct native_handle;

// The shim is linked without a C++ runtime (-nostdlib++): no function-local
// statics with dynamic initialisation, no containers, no exceptions.  The
// deleting Fence destructor uses a class-scope operator delete (free(), the
// platform operator new being malloc()), so no global allocation function is
// defined or exported.

// Resolves a symbol once; a benign race only repeats the lookup.
static void* resolve(std::atomic<void*>* cache, const char* lib, const char* sym) {
    void* fn = cache->load(std::memory_order_acquire);
    if (fn == nullptr) {
        void* handle = dlopen(lib, RTLD_NOW);
        fn = handle ? dlsym(handle, sym) : nullptr;
        cache->store(fn, std::memory_order_release);
    }
    return fn;
}

#define REAL(type, lib, sym)                                      \
    ([]() -> type {                                               \
        static std::atomic<void*> cache{nullptr};                 \
        return reinterpret_cast<type>(resolve(&cache, lib, sym)); \
    }())

static bool traceEnabled() {
    static std::atomic<int> state{-1};
    int v = state.load(std::memory_order_relaxed);
    if (v < 0) {
        v = getenv("C2A26_TRACE") != nullptr ? 1 : 0;
        state.store(v, std::memory_order_relaxed);
    }
    return v == 1;
}

namespace c2compa {

class EXPORT Fence {
public:
    explicit Fence(int fenceFd);

    int32_t wait(int timeout);
    int dup() const;

    // Declaration order defines the vtable order of the Android 12+ class:
    // getSignalTime, getStatus, ~Fence (complete), ~Fence (deleting).
    virtual int64_t getSignalTime() const;
    enum class Status { Invalid, Unsignaled, Signaled };
    virtual Status getStatus();

    static void operator delete(void* p) { free(p); }

protected:
    virtual ~Fence();

private:
    std::atomic<int32_t> mCount;  // LightRefBase<Fence>
    int mFenceFd;                 // base::unique_fd
};

static_assert(sizeof(void*) == 8, "arm64 only");

Fence::Fence(int fenceFd) : mCount(0), mFenceFd(fenceFd) {}

Fence::~Fence() {
    if (mFenceFd >= 0) {
        ::close(mFenceFd);
        mFenceFd = -1;
    }
}

int32_t Fence::wait(int timeout) {
    if (mFenceFd == -1) {
        return 0;
    }
    struct pollfd pfd = {mFenceFd, POLLIN, 0};
    for (;;) {
        int ret = ::poll(&pfd, 1, timeout);
        if (ret > 0) {
            if (pfd.revents & (POLLERR | POLLNVAL)) {
                return -EINVAL;
            }
            return 0;
        }
        if (ret == 0) {
            return -ETIME;
        }
        if (errno != EINTR && errno != EAGAIN) {
            return -errno;
        }
    }
}

int Fence::dup() const {
    return ::dup(mFenceFd);
}

int64_t Fence::getSignalTime() const {
    constexpr int64_t kPending = INT64_MAX;
    constexpr int64_t kInvalid = -1;
    if (mFenceFd == -1) {
        return kInvalid;
    }
    struct sync_file_info info = {};
    if (::ioctl(mFenceFd, SYNC_IOC_FILE_INFO, &info) < 0) {
        return kInvalid;
    }
    if (info.status != 1) {
        return kPending;
    }
    if (info.num_fences == 0) {
        return kInvalid;
    }
    auto* fences = static_cast<sync_fence_info*>(
            ::calloc(info.num_fences, sizeof(sync_fence_info)));
    if (fences == nullptr) {
        return kInvalid;
    }
    info.sync_fence_info = reinterpret_cast<uint64_t>(fences);
    int64_t signalTime = kInvalid;
    if (::ioctl(mFenceFd, SYNC_IOC_FILE_INFO, &info) == 0) {
        for (uint32_t i = 0; i < info.num_fences; ++i) {
            if (static_cast<int64_t>(fences[i].timestamp_ns) > signalTime) {
                signalTime = static_cast<int64_t>(fences[i].timestamp_ns);
            }
        }
    }
    ::free(fences);
    return signalTime;
}

Fence::Status Fence::getStatus() {
    int32_t status = wait(0);
    if (status < 0) {
        return status == -ETIME ? Status::Unsignaled : Status::Invalid;
    }
    return Status::Signaled;
}

}  // namespace c2compa

namespace vendor::graphics {

// Exynos 990 libexynosgraphicbuffer accessors (resolved at runtime).
class ExynosGraphicBufferMeta {
public:
    static int get_stride(const native_handle* hnd);
    static uint32_t get_internal_format(const native_handle* hnd);
    EXPORT static int get_cstride(const native_handle* hnd);
};

static bool isThreePlaneYuv(uint32_t format) {
    switch (format) {
        case 0x32315659:  // HAL_PIXEL_FORMAT_YV12
        case 0x101:       // EXYNOS_YCbCr_420_P_M
        case 0x11C:       // EXYNOS_YV12_M
        case 0x11F:       // EXYNOS_YCbCr_420_P
            return true;
        default:
            return false;
    }
}

int ExynosGraphicBufferMeta::get_cstride(const native_handle* hnd) {
    if (hnd == nullptr) {
        return 0;
    }
    int stride = get_stride(hnd);
    uint32_t format = get_internal_format(hnd);
    int cstride = isThreePlaneYuv(format) ? ((stride / 2 + 15) & ~15) : stride;
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true)) {
        ALOGI("get_cstride: format=0x%x stride=%d cstride=%d", format, stride, cstride);
    }
    return cstride;
}

// The A26 components mmap() the gralloc video-metadata fd with the A26
// ExynosVideoMeta size (0x2a60) and fill it with the A26 layout.  The Exynos
// 990 gralloc allocates a smaller buffer with a different ExynosVideoMeta, so
// the mmap fails (MAP_FAILED is only compared against NULL -> memset crash)
// and, even with a matching size, HWC would parse the wrong layout.  The
// component import is renamed in place to ExynosGraphicBufferMetc and reports
// "no metadata", which the component already handles; per-buffer HDR/ROI
// metadata is skipped until a layout translation exists.
class ExynosGraphicBufferMetc {
public:
    EXPORT static int get_video_metadata_fd(const native_handle* hnd);
};

int ExynosGraphicBufferMetc::get_video_metadata_fd(const native_handle*) {
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true)) {
        ALOGI("video metadata disabled: A26 ExynosVideoMeta layout differs from the 990 gralloc");
    }
    return -1;
}

}  // namespace vendor::graphics

// libdmabufheap (VNDK 31+) is absent from VNDK 30.  The Exynos 990 kernel has
// no /dev/dma_heap, so the A13 libcodec2_vndk selects C2AllocatorIon whenever
// /dev/ion exists and never constructs BufferAllocator.  These definitions
// only satisfy the load-time imports; the platform libc++ mangles std::string
// as std::__1, so the symbols are bound by name.  Constructing one would leave
// the inline-destroyed members uninitialized, so fail loudly instead.
extern "C" EXPORT void c2compat_BufferAllocator_ctor(void*) __asm__("_ZN15BufferAllocatorC1Ev");
extern "C" EXPORT int c2compat_BufferAllocator_Alloc(void*, const void*, unsigned long, unsigned int,
                                                    unsigned long)
        __asm__("_ZN15BufferAllocator5AllocERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEEmjm");

void c2compat_BufferAllocator_ctor(void*) {
    __android_log_print(ANDROID_LOG_FATAL, LOG_TAG,
                        "BufferAllocator constructed: DMA-BUF heaps are not supported on this kernel");
    abort();
}

int c2compat_BufferAllocator_Alloc(void*, const void*, unsigned long, unsigned int, unsigned long) {
    return -ENODEV;
}

// The A26 ExynosVideoApi sets the compressed (OUTPUT_MPLANE) sizeimage to 1,
// leaving the CPB size to the newer MFC driver.  The Exynos 990 driver takes
// sizeimage literally: cpb = ALIGN(1, 512), max stream = cpb - 512 = 0, and
// every header/frame is truncated to zero bytes ("header parsing failed").
// The component imports are renamed in place (same length) to
// exynos_c2a6_s_fmt, which only the shim defines, and the shim forwards to the
// real 990 exynos_v4l2_s_fmt().
static constexpr uint32_t kCompressedCpbSize = 4 * 1024 * 1024;

extern "C" EXPORT int exynos_c2a6_s_fmt(int fd, struct v4l2_format* fmt) {
    using SFmt = int (*)(int, struct v4l2_format*);
    SFmt real = REAL(SFmt, "libexynosv4l2.so", "exynos_v4l2_s_fmt");
    if (real == nullptr) {
        ALOGW("exynos_v4l2_s_fmt: real implementation not found");
        errno = ENOSYS;
        return -1;
    }
    if (traceEnabled() && fmt != nullptr && fmt->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
        uint32_t pf = fmt->fmt.pix_mp.pixelformat;
        ALOGI("s_fmt(CAPTURE_MPLANE): %ux%u fourcc %c%c%c%c (0x%08x) planes=%u", fmt->fmt.pix_mp.width,
              fmt->fmt.pix_mp.height, pf & 0xff, (pf >> 8) & 0xff, (pf >> 16) & 0xff, pf >> 24, pf,
              fmt->fmt.pix_mp.num_planes);
    }
    if (fmt != nullptr && fmt->type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE &&
        fmt->fmt.pix_mp.plane_fmt[0].sizeimage <= 1) {
        ALOGI("s_fmt(OUTPUT_MPLANE): sizeimage %u -> %u for the Exynos 990 MFC",
              fmt->fmt.pix_mp.plane_fmt[0].sizeimage, kCompressedCpbSize);
        fmt->fmt.pix_mp.plane_fmt[0].sizeimage = kCompressedCpbSize;
    }
    return real(fd, fmt);
}

// 10-bit 4:2:0: the A26 components set the CAPTURE queue to single-fd NV12N at
// init and pick their output colour format from G_FMT after the header.  The
// 990 driver reports NV12N_10B (one fd) for 10-bit content, which the
// components map to the two-fd SP_M_S10B (HAL 0x125, two planes), so every DPB
// QBUF fails ("geometry vs nPlaneCnt") or the buffer only holds luma.  When
// G_FMT reports NV12N_10B the shim switches the queue to NV12M_S10B (two
// planes, 8+2 bit each) before the components allocate, and returns that
// format; 8-bit streams are untouched.  Renamed in place from
// exynos_v4l2_g_fmt (same length).
extern "C" EXPORT int exynos_c2a6_g_fmt(int fd, struct v4l2_format* fmt) {
    using Fmt = int (*)(int, struct v4l2_format*);
    Fmt realG = REAL(Fmt, "libexynosv4l2.so", "exynos_v4l2_g_fmt");
    Fmt realS = REAL(Fmt, "libexynosv4l2.so", "exynos_v4l2_s_fmt");
    if (realG == nullptr || realS == nullptr) {
        errno = ENOSYS;
        return -1;
    }
    int ret = realG(fd, fmt);
    if (ret != 0 || fmt == nullptr || fmt->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ||
        fmt->fmt.pix_mp.pixelformat != C2A26_PIX_FMT_NV12N_10B) {
        return ret;
    }
    struct v4l2_format want = {};
    want.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    want.fmt.pix_mp.width = fmt->fmt.pix_mp.width;
    want.fmt.pix_mp.height = fmt->fmt.pix_mp.height;
    want.fmt.pix_mp.pixelformat = C2A26_PIX_FMT_NV12M_S10B;
    want.fmt.pix_mp.num_planes = 2;
    int sret = realS(fd, &want);
    struct v4l2_format now = {};
    now.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    int gret = sret == 0 ? realG(fd, &now) : -1;
    ALOGI("g_fmt(CAPTURE): 10-bit NV12N_10B -> NV12M_S10B (s_fmt %d, g_fmt %d, planes %u)", sret,
          gret, gret == 0 ? now.fmt.pix_mp.num_planes : 0);
    if (gret == 0) {
        *fmt = now;
    }
    return ret;
}

// Real-time playback (e.g. the Samsung Gallery/APlayer, priority 0) makes the
// A26 components query V4L2_CID_MPEG_MFC_BASE + 0x24 (real-time priority)
// before start.  The 990 MFC driver has no such control and returns EINVAL,
// which the components turn into "Failed to get real time resource" and a
// NO_MEMORY start failure.  The 990 MFC schedules all instances itself, so the
// query is answered as the highest priority (0).  Renamed in place from
// exynos_v4l2_g_ctrl (same length).
static constexpr unsigned int kCidMfcRealTimePriority = 0x00992024;

extern "C" EXPORT int exynos_c2a6_g_ctrl(int fd, unsigned int id, int* value) {
    using GCtrl = int (*)(int, unsigned int, int*);
    GCtrl real = REAL(GCtrl, "libexynosv4l2.so", "exynos_v4l2_g_ctrl");
    if (real == nullptr) {
        errno = ENOSYS;
        return -1;
    }
    int ret = real(fd, id, value);
    if (ret != 0 && id == kCidMfcRealTimePriority && value != nullptr) {
        static std::atomic<bool> logged{false};
        if (!logged.exchange(true)) {
            ALOGI("g_ctrl(real-time priority) unsupported by the 990 MFC; reporting priority 0");
        }
        *value = 0;
        return 0;
    }
    return ret;
}

static void captureQueued(int fd);

// The EOS bitstream buffer is a tiny dmabuf flagged LAST_FRAME|EMPTY_DATA
// (reserved2 bits 31/30, the same protocol as the 990 driver).  On the 990
// the OUTPUT min_length is the CPB size, so the EOS QBUF is rejected ("invalid
// dmabuf length 1280 ... minimum 4194304"), the DPB is never flushed and the
// last frames are lost.  The MFC does not read EMPTY_DATA buffers, so the
// shim queues a CPB-sized placeholder dmabuf in its place.
static constexpr uint32_t kMfcFlagLastFrame = 1U << 31;

static int gEosFd = -1;
static pthread_once_t gEosOnce = PTHREAD_ONCE_INIT;

static void allocEosDmabuf() {
    using Open = int (*)();
    using Alloc = int (*)(int, size_t, unsigned int, unsigned int);
    void* lib = dlopen("libion_exynos.so", RTLD_NOW);
    auto ionOpen = lib ? reinterpret_cast<Open>(dlsym(lib, "exynos_ion_open")) : nullptr;
    auto ionAlloc = lib ? reinterpret_cast<Alloc>(dlsym(lib, "exynos_ion_alloc")) : nullptr;
    if (ionOpen == nullptr || ionAlloc == nullptr) {
        ALOGW("EOS placeholder: libion_exynos unavailable");
        return;
    }
    int ion = ionOpen();
    gEosFd = ion >= 0 ? ionAlloc(ion, kCompressedCpbSize, 1 /* system heap */, 0) : -1;
    if (gEosFd < 0) {
        ALOGW("EOS placeholder: exynos_ion_alloc failed (%d)", gEosFd);
    }
}

static int eosDmabuf() {
    pthread_once(&gEosOnce, allocEosDmabuf);
    return gEosFd;
}

// The A26 components report each CAPTURE dmabuf plane length as the bare
// width*height*1.5 they computed, while the 990 MFC requires the per-plane
// 256-byte extension as min_length.  vb2 validates the userspace length, not
// the dmabuf, so the DPB is rejected even when the buffer is large enough.
// Length 0 makes vb2 use the real dmabuf size.  Renamed in place from
// exynos_v4l2_qbuf (same length).
extern "C" EXPORT int exynos_c2a6_qbuf(int fd, struct v4l2_buffer* buf) {
    using QBuf = int (*)(int, struct v4l2_buffer*);
    QBuf real = REAL(QBuf, "libexynosv4l2.so", "exynos_v4l2_qbuf");
    if (real == nullptr) {
        errno = ENOSYS;
        return -1;
    }
    if (buf != nullptr && buf->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE &&
        buf->memory == V4L2_MEMORY_DMABUF && buf->m.planes != nullptr) {
        for (uint32_t i = 0; i < buf->length && i < VIDEO_MAX_PLANES; ++i) {
            buf->m.planes[i].length = 0;
        }
    }
    int savedFd = -1;
    if (buf != nullptr && buf->type == V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE &&
        buf->memory == V4L2_MEMORY_DMABUF && buf->m.planes != nullptr && buf->length > 0 &&
        (buf->reserved2 & kMfcFlagLastFrame)) {
        off_t size = ::lseek(buf->m.planes[0].m.fd, 0, SEEK_END);
        int eosFd = eosDmabuf();
        if (size >= 0 && size < static_cast<off_t>(kCompressedCpbSize) && eosFd >= 0) {
            savedFd = buf->m.planes[0].m.fd;
            buf->m.planes[0].m.fd = eosFd;
            buf->m.planes[0].length = 0;
        }
    }
    int ret = real(fd, buf);
    if (savedFd >= 0) {
        buf->m.planes[0].m.fd = savedFd;
        ALOGI("EOS: queued LAST_FRAME on a %u-byte placeholder dmabuf -> %d",
              kCompressedCpbSize, ret);
    }
    if (ret == 0 && buf != nullptr && buf->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
        captureQueued(fd);
    }
    if (traceEnabled() && buf != nullptr) {
        ALOGI("QBUF type=%u idx=%u flags=0x%x ts=%ld.%06ld res=%u res2=%u bytes0=%u -> %d",
              buf->type, buf->index, buf->flags, static_cast<long>(buf->timestamp.tv_sec),
              static_cast<long>(buf->timestamp.tv_usec), buf->reserved, buf->reserved2,
              buf->m.planes ? buf->m.planes[0].bytesused : 0, ret);
    }
    return ret;
}

extern "C" EXPORT int exynos_c2a6_dqbuf(int fd, struct v4l2_buffer* buf) {
    using DqBuf = int (*)(int, struct v4l2_buffer*);
    DqBuf real = REAL(DqBuf, "libexynosv4l2.so", "exynos_v4l2_dqbuf");
    if (real == nullptr) {
        errno = ENOSYS;
        return -1;
    }
    int ret = real(fd, buf);
    if (traceEnabled() && buf != nullptr && ret == 0) {
        ALOGI("DQBUF type=%u idx=%u flags=0x%x ts=%ld.%06ld res=%u res2=%u bytes0=%u field=%u seq=%u",
              buf->type, buf->index, buf->flags, static_cast<long>(buf->timestamp.tv_sec),
              static_cast<long>(buf->timestamp.tv_usec), buf->reserved, buf->reserved2,
              buf->m.planes ? buf->m.planes[0].bytesused : 0, buf->field, buf->sequence);
    }
    return ret;
}

// The 4.19 vb2_core_poll() returns EPOLLERR for a queue that is not streaming
// *before* it calls poll_wait(), so an epoll item added before STREAMON is
// never hooked to the queue's done_wq and no vb2_buffer_done() ever wakes it.
// Newer kernels call poll_wait() first, and the A26 components register the
// MFC fd at init, before STREAMON.  The components import epoll_ctl,
// exynos_v4l2_streamon and exynos_v4l2_qbuf renamed in place; the shim records
// every epoll item on a video node and re-arms it (DEL + ADD) once the queue is
// streaming: after STREAMON, and after the first CAPTURE QBUF that follows it
// (vb2 also returns EPOLLERR without poll_wait() while a capture queue still
// waits for its first buffer).  The kernel-side fix is to move poll_wait() to
// the top of vb2_core_poll(), as upstream did.
namespace {
struct EpollItem {
    int epfd;
    int fd;
    struct epoll_event ev;
};
constexpr int kMaxEpollItems = 64;
constexpr int kMaxPendingRearm = 16;
pthread_mutex_t gEpollLock = PTHREAD_MUTEX_INITIALIZER;
EpollItem gEpollItems[kMaxEpollItems];
int gEpollCount = 0;
int gCaptureRearmPending[kMaxPendingRearm];
int gPendingCount = 0;

struct Locked {
    Locked() { pthread_mutex_lock(&gEpollLock); }
    ~Locked() { pthread_mutex_unlock(&gEpollLock); }
};

bool isVideoNode(int fd) {
    char link[64];
    char target[128];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, target, sizeof(target) - 1);
    if (n <= 0) {
        return false;
    }
    target[n] = 0;
    return strncmp(target, "/dev/video", 10) == 0;
}

void rearmEpoll(int fd, const char* why) {
    Locked lock;
    for (int i = 0; i < gEpollCount; ++i) {
        EpollItem& item = gEpollItems[i];
        if (item.fd != fd) {
            continue;
        }
        epoll_ctl(item.epfd, EPOLL_CTL_DEL, fd, nullptr);
        struct epoll_event ev = item.ev;
        int ret = epoll_ctl(item.epfd, EPOLL_CTL_ADD, fd, &ev);
        if (traceEnabled() || ret != 0) {
            ALOGI("epoll: re-armed MFC fd %d on ep %d (events 0x%x) after %s -> %d", fd, item.epfd,
                  item.ev.events, why, ret);
        }
    }
}
}  // namespace

extern "C" EXPORT int c2a6epctl(int epfd, int op, int fd, struct epoll_event* ev) {
    int ret = epoll_ctl(epfd, op, fd, ev);
    if (ret != 0 || !isVideoNode(fd)) {
        return ret;
    }
    Locked lock;
    for (int i = 0; i < gEpollCount;) {
        if (gEpollItems[i].epfd == epfd && gEpollItems[i].fd == fd) {
            gEpollItems[i] = gEpollItems[--gEpollCount];
        } else {
            ++i;
        }
    }
    if ((op == EPOLL_CTL_ADD || op == EPOLL_CTL_MOD) && ev != nullptr) {
        if (gEpollCount < kMaxEpollItems) {
            gEpollItems[gEpollCount++] = {epfd, fd, *ev};
        } else {
            ALOGW("epoll: tracking table full, fd %d will not be re-armed", fd);
        }
    }
    return ret;
}

extern "C" EXPORT int exynos_c2a6_streamon(int fd, enum v4l2_buf_type type) {
    using StreamOn = int (*)(int, enum v4l2_buf_type);
    StreamOn real = REAL(StreamOn, "libexynosv4l2.so", "exynos_v4l2_streamon");
    if (real == nullptr) {
        errno = ENOSYS;
        return -1;
    }
    int ret = real(fd, type);
    if (ret == 0) {
        rearmEpoll(fd, type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE ? "capture STREAMON"
                                                                  : "output STREAMON");
        if (type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
            Locked lock;
            if (gPendingCount < kMaxPendingRearm) {
                gCaptureRearmPending[gPendingCount++] = fd;
            }
        }
    }
    return ret;
}

static void captureQueued(int fd) {
    bool pending = false;
    {
        Locked lock;
        for (int i = 0; i < gPendingCount; ++i) {
            if (gCaptureRearmPending[i] == fd) {
                gCaptureRearmPending[i] = gCaptureRearmPending[--gPendingCount];
                pending = true;
                break;
            }
        }
    }
    if (pending) {
        rearmEpoll(fd, "first capture QBUF");
    }
}

// BufferUsage::VIDEO_DECODER.  The Exynos 990 gralloc only adds the MFC
// per-plane extension (256 bytes) when the producer is the video decoder,
// which is what the OMX path declares; the A26 pool omits it, so the 990 MFC
// rejects the DPB ("invalid dmabuf length 1382400 ... minimum 1382912").
static constexpr uint64_t kUsageVideoDecoder = 1ULL << 22;

static bool isExynosMfcYuv(uint32_t format) {
    return format >= 0x100 && format <= 0x1ff;  // HAL_PIXEL_FORMAT_EXYNOS_* YUV range
}

// Compat hook for the A26 C2 graphic block pool.  The import in
// libcodec2_vndk is renamed in place (android -> c2compa); the std::string
// argument is passed indirectly per AAPCS64 and forwarded untouched.
using AllocateRawHandleFn = int32_t (*)(void* self, uint32_t width, uint32_t height, int32_t format,
                                        uint32_t layerCount, uint64_t usage,
                                        const native_handle** handle, uint32_t* stride,
                                        void* requestorName);

extern "C" EXPORT int32_t c2compat_allocateRawHandle(void* self, uint32_t width, uint32_t height,
                                                     int32_t format, uint32_t layerCount,
                                                     uint64_t usage, const native_handle** handle,
                                                     uint32_t* stride, void* requestorName)
        __asm__("_ZN7c2compa22GraphicBufferAllocator17allocateRawHandleEjjijmPPK13native_handlePjNSt3__112basic_stringIcNS6_11char_traitsIcEENS6_9allocatorIcEEEE");

int32_t c2compat_allocateRawHandle(void* self, uint32_t width, uint32_t height, int32_t format,
                                   uint32_t layerCount, uint64_t usage,
                                   const native_handle** handle, uint32_t* stride,
                                   void* requestorName) {
    AllocateRawHandleFn real = REAL(
            AllocateRawHandleFn, "libui.so",
            "_ZN7android22GraphicBufferAllocator17allocateRawHandleEjjijmPPK13native_handlePjNSt3__112basic_stringIcNS6_11char_traitsIcEENS6_9allocatorIcEEEE");
    if (real == nullptr) {
        ALOGW("allocateRawHandle: libui implementation not found");
        return -ENOSYS;
    }
    uint64_t requested = usage;
    if (isExynosMfcYuv(static_cast<uint32_t>(format))) {
        usage |= kUsageVideoDecoder;
    }
    int32_t ret = real(self, width, height, format, layerCount, usage, handle, stride, requestorName);
    if (!traceEnabled()) {
        return ret;
    }
    off_t size = -1;
    if (ret == 0 && handle != nullptr && *handle != nullptr) {
        const int* ints = reinterpret_cast<const int*>(*handle);  // version, numFds, numInts, data[]
        if (ints[1] > 0) {
            size = ::lseek(ints[3], 0, SEEK_END);
        }
    }
    ALOGI("allocateRawHandle(%ux%u fmt=0x%x usage=0x%llx->0x%llx) -> %d stride=%u fd0=%lld bytes",
          width, height, format, static_cast<unsigned long long>(requested),
          static_cast<unsigned long long>(usage), ret, stride ? *stride : 0,
          static_cast<long long>(size));
    return ret;
}

class AcrylicCanvas {
public:
    EXPORT bool setStride(unsigned int* stride);
};

bool AcrylicCanvas::setStride(unsigned int* stride) {
    static std::atomic<bool> logged{false};
    if (stride != nullptr && !logged.exchange(true)) {
        ALOGW("AcrylicCanvas::setStride(%u,%u,%u,%u) ignored on the 990 libacryl",
              stride[0], stride[1], stride[2], stride[3]);
    }
    return true;
}
