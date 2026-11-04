#include "exynos990/camera_aidl_mapper.h"

#include <cutils/native_handle.h>
#include <hardware/gralloc1.h>

#include <cstdint>
#include <dlfcn.h>
#include <pthread.h>

extern "C" int __android_log_print(int priority, const char* tag, const char* format, ...);

// These are the public HIDL 2.0 names embedded in the camera HAL ABI.  The
// camera client only passes Rect and receives YCbCrLayout; defining the small
// value types here keeps this compatibility shim independent of the HIDL C++
// runtime while preserving the exact mangled method names.
namespace android::hardware::graphics::mapper::V2_0 {
struct IMapper {
    struct Rect {
        int32_t left;
        int32_t top;
        int32_t width;
        int32_t height;
    };

    struct YCbCrLayout {
        void* y;
        void* cb;
        void* cr;
        uint32_t yStride;
        uint32_t cStride;
        uint32_t chromaStep;
    };
};
}  // namespace android::hardware::graphics::mapper::V2_0

namespace android::GrallocMapperCamera {

namespace {

using HidlRect = android::hardware::graphics::mapper::V2_0::IMapper::Rect;
using HidlYcbcr = android::hardware::graphics::mapper::V2_0::IMapper::YCbCrLayout;

int mapperError(int32_t error) {
    switch (error) {
        case GRALLOC1_ERROR_NONE: return 0;            // IMapper::Error::NONE
        case GRALLOC1_ERROR_BAD_DESCRIPTOR: return 1; // BAD_DESCRIPTOR
        case GRALLOC1_ERROR_BAD_HANDLE: return 2;     // BAD_BUFFER
        case GRALLOC1_ERROR_BAD_VALUE: return 3;      // BAD_VALUE
        case GRALLOC1_ERROR_NO_RESOURCES: return 4;   // NO_RESOURCES
        default: return 5;                             // UNSUPPORTED
    }
}

// mapper.exynos990_compat.so lives in /vendor/lib64/hw, which is an Android
// HAL discovery directory rather than the generic vendor linker search path.
// Load its absolute path once instead of relying on a DT_NEEDED lookup that
// may vary with the process linker namespace.  This still keeps the only
// implementation in the Stable-C mapper; this library exports solely the
// historical Camera3 C++ symbols.
struct AidlCameraCore {
    void* handle = nullptr;
    decltype(&exynos990_aidl_camera_lock) lock = nullptr;
    decltype(&exynos990_aidl_camera_lock_ycbcr) lockYcbcr = nullptr;
    decltype(&exynos990_aidl_camera_unlock) unlock = nullptr;
};

AidlCameraCore& aidlCameraCore() {
    static AidlCameraCore core;
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, [] {
        core.handle = dlopen("/vendor/lib64/hw/mapper.exynos990_compat.so", RTLD_NOW | RTLD_LOCAL);
        if (core.handle) {
            core.lock = reinterpret_cast<decltype(core.lock)>(
                    dlsym(core.handle, "exynos990_aidl_camera_lock"));
            core.lockYcbcr = reinterpret_cast<decltype(core.lockYcbcr)>(
                    dlsym(core.handle, "exynos990_aidl_camera_lock_ycbcr"));
            core.unlock = reinterpret_cast<decltype(core.unlock)>(
                    dlsym(core.handle, "exynos990_aidl_camera_unlock"));
        }
        if (!core.lock || !core.lockYcbcr || !core.unlock) {
            __android_log_print(6, "Exynos990CameraMapper",
                                "Stable-C camera core is unavailable: %s",
                                dlerror() ?: "required symbol missing");
            if (core.handle) dlclose(core.handle);
            core = {};
        }
    });
    return core;
}

}  // namespace

class __attribute__((visibility("default"))) Mapper {
  public:
    int lock(const native_handle_t* buffer, uint64_t usage, const HidlRect& rect,
             int fence, void** output) const;
    int lock(const native_handle_t* buffer, uint64_t usage, const HidlRect& rect,
             int fence, HidlYcbcr* output) const;
    int unlock(const native_handle_t* buffer) const;
};

int Mapper::lock(const native_handle_t* buffer, uint64_t usage, const HidlRect& rect,
                 int fence, void** output) const {
    const exynos990_camera_rect_t aidlRect{rect.left, rect.top, rect.width, rect.height};
    AidlCameraCore& core = aidlCameraCore();
    if (!core.lock) return 2;
    return mapperError(core.lock(buffer, usage, &aidlRect, fence, output));
}

int Mapper::lock(const native_handle_t* buffer, uint64_t usage, const HidlRect& rect,
                 int fence, HidlYcbcr* output) const {
    const exynos990_camera_rect_t aidlRect{rect.left, rect.top, rect.width, rect.height};
    exynos990_camera_ycbcr_t aidlLayout{};
    AidlCameraCore& core = aidlCameraCore();
    if (!core.lockYcbcr) return 2;
    const int result = core.lockYcbcr(buffer, usage, &aidlRect, fence, &aidlLayout);
    if (result != GRALLOC1_ERROR_NONE) return mapperError(result);
    output->y = aidlLayout.y;
    output->cb = aidlLayout.cb;
    output->cr = aidlLayout.cr;
    output->yStride = aidlLayout.yStride;
    output->cStride = aidlLayout.cStride;
    output->chromaStep = aidlLayout.chromaStep;
    return 0;
}

int Mapper::unlock(const native_handle_t* buffer) const {
    AidlCameraCore& core = aidlCameraCore();
    if (!core.unlock) return 2;
    return mapperError(core.unlock(buffer));
}

// The vendor camera HAL was linked by an older Clang revision whose C++ ABI
// substitution table encoded this nested type as NS8_.  The method demangles
// identically, but the dynamic linker compares the mangled bytes.  Export an
// ABI alias with the exact name used by libexynoscamera3.so.
extern "C" __attribute__((visibility("default"))) int camera_mapper_lock_ycbcr_abi(
        const native_handle_t* buffer, uint64_t usage, const HidlRect& rect,
        int fence, HidlYcbcr* output)
        __asm__("_ZNK7android19GrallocMapperCamera6Mapper4lockEPK13native_handlemRKNS_8hardware8graphics6mapper4V2_07IMapper4RectEiPNS8_11YCbCrLayoutE");

int camera_mapper_lock_ycbcr_abi(const native_handle_t* buffer, uint64_t usage,
                                 const HidlRect& rect, int fence, HidlYcbcr* output) {
    Mapper mapper;
    return mapper.lock(buffer, usage, rect, fence, output);
}

}  // namespace android::GrallocMapperCamera
