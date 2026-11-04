#include <aidl/android/hardware/graphics/composer3/IComposer.h>
#include <aidl/android/hardware/graphics/composer3/IComposerClient.h>
#include <aidl/android/hardware/graphics/composer3/IComposerCallback.h>
#include <aidl/android/hardware/graphics/composer3/BnComposer.h>
#include <aidl/android/hardware/graphics/composer3/BnComposerClient.h>
#include <aidl/android/hardware/graphics/composer3/Buffer.h>
#include <aidl/android/hardware/graphics/composer3/ChangedCompositionTypes.h>
#include <aidl/android/hardware/graphics/composer3/CommandError.h>
#include <aidl/android/hardware/graphics/composer3/ColorMode.h>
#include <aidl/android/hardware/graphics/composer3/CommandResultPayload.h>
#include <aidl/android/hardware/graphics/composer3/DisplayCommand.h>
#include <aidl/android/hardware/graphics/composer3/DisplayAttribute.h>
#include <aidl/android/hardware/graphics/composer3/DisplayConfiguration.h>
#include <aidl/android/hardware/graphics/composer3/DisplayConnectionType.h>
#include <aidl/android/hardware/graphics/composer3/DisplayRequest.h>
#include <aidl/android/hardware/graphics/composer3/HdrCapabilities.h>
#include <aidl/android/hardware/graphics/composer3/LayerCommand.h>
#include <aidl/android/hardware/graphics/composer3/PerFrameMetadata.h>
#include <aidl/android/hardware/graphics/composer3/PerFrameMetadataBlob.h>
#include <aidl/android/hardware/graphics/composer3/PerFrameMetadataKey.h>
#include <aidl/android/hardware/graphics/composer3/Composition.h>
#include <aidl/android/hardware/graphics/composer3/LayerLifecycleBatchCommandType.h>
#include <aidl/android/hardware/graphics/composer3/ParcelableBlendMode.h>
#include <aidl/android/hardware/graphics/composer3/ParcelableComposition.h>
#include <aidl/android/hardware/graphics/composer3/ParcelableTransform.h>
#include <aidl/android/hardware/graphics/composer3/PlaneAlpha.h>
#include <aidl/android/hardware/graphics/composer3/PresentFence.h>
#include <aidl/android/hardware/graphics/composer3/PowerMode.h>
#include <aidl/android/hardware/graphics/composer3/ReleaseFences.h>
#include <aidl/android/hardware/graphics/composer3/VsyncPeriodChangeTimeline.h>
#include <aidl/android/hardware/graphics/common/BlendMode.h>
#include <aidl/android/hardware/graphics/common/DisplayHotplugEvent.h>
#include <aidl/android/hardware/graphics/common/FRect.h>
#include <aidl/android/hardware/graphics/common/Hdr.h>
#include <aidl/android/hardware/graphics/common/Rect.h>
#include <aidl/android/hardware/graphics/common/Transform.h>
#include <aidl/android/hardware/common/NativeHandle.h>
#include <android/binder_ibinder.h>
#include <android/binder_status.h>
#include <android/hardware/graphics/mapper/IMapper.h>
#include <hardware/hwcomposer2.h>
#include <cutils/native_handle.h>
#include <android/log.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#include <algorithm>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <dlfcn.h>
#include <deque>
#include <errno.h>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>
#include <utility>
#include <vector>

#include "hwc2_backend.h"
#include "hwc2_backend_state.h"
#include "metadata.h"
#include "exynos990/graphics_backend.h"
#include "exynos990/graphics_contract.h"

namespace composer3 = aidl::android::hardware::graphics::composer3;
namespace graphics_common = aidl::android::hardware::graphics::common;
namespace hardware_common = aidl::android::hardware::common;

namespace {

native_handle_t* cloneNativeHandle(const aidl::android::hardware::common::NativeHandle& source) {
    native_handle_t* result = native_handle_create(static_cast<int>(source.fds.size()),
                                                   static_cast<int>(source.ints.size()));
    if (!result) return nullptr;
    for (size_t i = 0; i < source.fds.size(); ++i) {
        const int fd = source.fds[i].get();
        result->data[i] = fd >= 0 ? ::dup(fd) : -1;
        if (fd >= 0 && result->data[i] < 0) {
            native_handle_close(result);
            native_handle_delete(result);
            return nullptr;
        }
    }
    std::copy(source.ints.begin(), source.ints.end(), result->data + source.fds.size());
    return result;
}

void freeNativeHandle(native_handle_t* handle) {
    if (!handle) return;
    native_handle_close(handle);
    native_handle_delete(handle);
}

int duplicateFence(const ndk::ScopedFileDescriptor& fence) {
    return fence.get() >= 0 ? ::dup(fence.get()) : -1;
}

int waitFence(int fd, int timeout_ms) {
    if (fd < 0) return 0;
    pollfd descriptor{fd, POLLIN, 0};
    int status = 0;
    do {
        status = ::poll(&descriptor, 1, timeout_ms);
    } while (status < 0 && errno == EINTR);
    if (status == 1 && (descriptor.revents & (POLLIN | POLLERR | POLLHUP))) return 0;
    if (status == 0) return ETIMEDOUT;
    return status < 0 ? errno : EIO;
}

int32_t toComposerError(int error) {
    switch (error) {
        case HWC2_ERROR_BAD_DISPLAY: return composer3::IComposerClient::EX_BAD_DISPLAY;
        case HWC2_ERROR_BAD_LAYER: return composer3::IComposerClient::EX_BAD_LAYER;
        case HWC2_ERROR_BAD_CONFIG: return composer3::IComposerClient::EX_BAD_CONFIG;
        case HWC2_ERROR_NOT_VALIDATED: return composer3::IComposerClient::EX_NOT_VALIDATED;
        case HWC2_ERROR_NO_RESOURCES: return composer3::IComposerClient::EX_NO_RESOURCES;
        case HWC2_ERROR_BAD_PARAMETER: return composer3::IComposerClient::EX_BAD_PARAMETER;
        case HWC2_ERROR_UNSUPPORTED: return composer3::IComposerClient::EX_UNSUPPORTED;
        case HWC2_ERROR_SEAMLESS_NOT_ALLOWED:
            return composer3::IComposerClient::EX_SEAMLESS_NOT_ALLOWED;
        case HWC2_ERROR_SEAMLESS_NOT_POSSIBLE:
            return composer3::IComposerClient::EX_SEAMLESS_NOT_POSSIBLE;
        default: return composer3::IComposerClient::EX_UNSUPPORTED;
    }
}

int64_t monotonicTimeNanos() {
    timespec now{};
    if (::clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return static_cast<int64_t>(now.tv_sec) * 1000000000LL + now.tv_nsec;
}

bool cameraMppPathEnabled() {
    static const bool enabled = [] {
        char value[PROP_VALUE_MAX] = {};
        return __system_property_get("persist.vendor.exynos990.camera_mpp", value) > 0 &&
                (strcmp(value, "1") == 0 || strcmp(value, "true") == 0);
    }();
    return enabled;
}

int64_t cameraConvertIntervalNanos() {
    static const int64_t interval = [] {
        char value[PROP_VALUE_MAX] = {};
        int fps = 30;
        if (__system_property_get("persist.vendor.exynos990.camera_convert_fps", value) > 0) {
            char* end = nullptr;
            const long parsed = std::strtol(value, &end, 10);
            if (end != value && *end == '\0') fps = static_cast<int>(parsed);
        }
        fps = std::clamp(fps, 5, 60);
        return 1000000000LL / static_cast<int64_t>(fps);
    }();
    return interval;
}

using HwcBufferKey = std::pair<uint64_t, int32_t>;
constexpr uint64_t kClientTargetKey = ~uint64_t{0};
constexpr size_t kRetiredHandleLimit = 64;
constexpr size_t kCameraOutputHardLimit = 16;

// Keep one authoritative view of the modes exposed by the proprietary HWC2.
// Android 17 asks Composer3 for this information through several independent
// entry points.  Returning a fresh, slightly different answer from each one
// lets SurfaceFlinger create a logical mode which the DDI scaler never sees.
struct DisplayConfigState {
    int32_t id = -1;
    int32_t width = 0;
    int32_t height = 0;
    int32_t vsync_period_ns = 0;
    int32_t dpi_x = 0;
    int32_t dpi_y = 0;
    int32_t group = -1;
};

class StableMapperImporter {
  public:
    StableMapperImporter() {
        library_ = ::dlopen("/vendor/lib64/hw/mapper.exynos990_compat.so",
                            RTLD_NOW | RTLD_LOCAL);
        if (!library_) {
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Unable to load Exynos990 Stable-C mapper: %s", ::dlerror());
            return;
        }
        using LoadMapper = AIMapper_Error (*)(AIMapper**);
        auto load = reinterpret_cast<LoadMapper>(::dlsym(library_, "AIMapper_loadIMapper"));
        if (!load || load(&mapper_) != AIMAPPER_ERROR_NONE || !mapper_ ||
            mapper_->version < AIMAPPER_VERSION_5) {
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Exynos990 Stable-C mapper V5 is unavailable");
            mapper_ = nullptr;
            return;
        }
        __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                            "Exynos990 Stable-C mapper V5 ready for HWC2 buffer imports");
    }

    native_handle_t* import(const hardware_common::NativeHandle& source) const {
        if (!mapper_) return nullptr;
        native_handle_t* raw = cloneNativeHandle(source);
        if (!raw) return nullptr;
        buffer_handle_t imported = nullptr;
        const AIMapper_Error error = mapper_->v5.importBuffer(raw, &imported);
        freeNativeHandle(raw);
        if (error != AIMAPPER_ERROR_NONE || !imported) {
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Stable-C mapper importBuffer failed: %d", error);
            return nullptr;
        }
        return const_cast<native_handle_t*>(imported);
    }

    // Keep a plain native-handle clone available for Exynos private camera
    // buffers.  Stable-C import is intentionally used for metadata discovery,
    // but the legacy HWC2 path expects the original private-handle layout and
    // its original fd/int contract.  Passing the mapper's imported handle to
    // HWC2 can turn a valid 0x11d NV21 buffer into a uniform green frame.
    native_handle_t* cloneRaw(const hardware_common::NativeHandle& source) const {
        native_handle_t* raw = cloneNativeHandle(source);
        if (!raw) return nullptr;
        const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
        if (!backend || !backend->ready || !backend->retain ||
            backend->retain(backend->device, raw) != GRALLOC1_ERROR_NONE) {
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Unable to retain raw private camera handle for HWC2");
            freeNativeHandle(raw);
            return nullptr;
        }
        return raw;
    }

    void releaseRaw(native_handle_t* handle) const {
        if (!handle) return;
        const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
        if (!backend || !backend->ready || !backend->release ||
            backend->release(backend->device, handle) != GRALLOC1_ERROR_NONE) {
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Unable to release raw private camera handle through Gralloc1");
            freeNativeHandle(handle);
            return;
        }
        if (!backend->releaseImpliesDelete) freeNativeHandle(handle);
    }

    // The Exynos camera producer uses the private 0x11d YUV format.  The
    // Stable-C mapper exposes the requested format as standard metadata, so
    // identify it after import instead of guessing from the layer name.
    bool isPrivateCameraYuv(buffer_handle_t buffer) const {
        if (!mapper_ || !buffer) return false;
        // The original y2s camera mapper does not attach a Stable-C standard
        // metadata envelope to every imported 0x11d buffer.  Gralloc1 still
        // exposes the authoritative HAL format through get_format(); use it
        // before parsing optional metadata so the global Composer3 bridge
        // cannot mistake the camera allocation for a normal YUV layer.
        const exynos990_gralloc_backend_t* format_backend = exynos990_gralloc_backend();
        int32_t direct_format = -1;
        if (format_backend && format_backend->ready && format_backend->getFormat &&
            format_backend->getFormat(format_backend->device, buffer, &direct_format) ==
                    GRALLOC1_ERROR_NONE &&
            direct_format == exynos990::graphics::kExynosCameraYuv) {
            return true;
        }
        static std::atomic_bool camera_format_probe_logged{false};
        const size_t handleBytes = buffer->numFds >= 0 && buffer->numInts >= 0
                ? offsetof(native_handle_t, data) +
                        static_cast<size_t>(buffer->numFds + buffer->numInts) * sizeof(int)
                : 0;
        if (!camera_format_probe_logged.exchange(true)) {
            int32_t grallocFormat = -1;
            const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
            if (backend && backend->ready && backend->getFormat)
                backend->getFormat(backend->device, buffer, &grallocFormat);
            int32_t framework = -1;
            int32_t internalLow = -1;
            int32_t allocation = -1;
            const uint8_t* raw = reinterpret_cast<const uint8_t*>(buffer);
            if (handleBytes >= exynos990::graphics::PrivateHandleLayout::kFrameworkFormat +
                                    sizeof(framework)) {
                std::memcpy(&framework, raw +
                                    exynos990::graphics::PrivateHandleLayout::kFrameworkFormat,
                            sizeof(framework));
            }
            if (handleBytes >= exynos990::graphics::PrivateHandleLayout::kInternalFormat +
                                    sizeof(internalLow)) {
                std::memcpy(&internalLow, raw +
                                    exynos990::graphics::PrivateHandleLayout::kInternalFormat,
                            sizeof(internalLow));
            }
            if (handleBytes >= exynos990::graphics::PrivateHandleLayout::kAllocationFormat +
                                    sizeof(allocation)) {
                std::memcpy(&allocation, raw +
                                    exynos990::graphics::PrivateHandleLayout::kAllocationFormat,
                            sizeof(allocation));
            }
            __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                "Camera format probe: fds=%d ints=%d gralloc=0x%x framework=0x%x internal=0x%x alloc=0x%x bytes=%zu",
                                buffer->numFds, buffer->numInts, grallocFormat, framework,
                                internalLow, allocation, handleBytes);
        }
        constexpr int64_t kPixelFormatRequested = 6;
        const int32_t required = mapper_->v5.getStandardMetadata(
                buffer, kPixelFormatRequested, nullptr, 0);
        if (required > 0) {
            std::vector<uint8_t> encoded(static_cast<size_t>(required));
            if (mapper_->v5.getStandardMetadata(buffer, kPixelFormatRequested,
                                                 encoded.data(), encoded.size()) == required) {
                size_t offset = 0;
                const auto read = [&](void* output, size_t size) {
                    if (offset > encoded.size() || size > encoded.size() - offset) return false;
                    std::memcpy(output, encoded.data() + offset, size);
                    offset += size;
                    return true;
                };
                int64_t nameLength = 0;
                int64_t encodedType = 0;
                int32_t format = 0;
                if (read(&nameLength, sizeof(nameLength)) && nameLength >= 0 &&
                    static_cast<uint64_t>(nameLength) <= encoded.size() - offset &&
                    static_cast<size_t>(nameLength) == exynos990::metadata::kStandardName.size() &&
                    std::memcmp(encoded.data() + offset,
                                exynos990::metadata::kStandardName.data(),
                                exynos990::metadata::kStandardName.size()) == 0) {
                    offset += static_cast<size_t>(nameLength);
                    if (read(&encodedType, sizeof(encodedType)) &&
                        encodedType == kPixelFormatRequested && read(&format, sizeof(format)) &&
                        offset == encoded.size() &&
                        format == exynos990::graphics::kExynosCameraYuv) {
                        return true;
                    }
                }
            }
        }

        // Some camera buffers arrive with the legacy private handle metadata
        // but without the Stable-C standard metadata envelope.  The Exynos
        // 990 gralloc contract keeps the allocation format at this fixed
        // field; use it
        // only as a fallback after validating the native-handle bounds.
        if (buffer->numFds < 0 || buffer->numInts < 0) return false;
        if (exynos990::graphics::PrivateHandleLayout::kAllocationFormat +
            sizeof(int32_t) > handleBytes) {
            return false;
        }
        int32_t format = 0;
        std::memcpy(&format, reinterpret_cast<const uint8_t*>(buffer) +
                            exynos990::graphics::PrivateHandleLayout::kAllocationFormat,
                    sizeof(format));
        return format == exynos990::graphics::kExynosCameraYuv;
    }

    void release(native_handle_t* handle) const {
        if (!handle) return;
        if (!mapper_) {
            freeNativeHandle(handle);
            return;
        }
        const AIMapper_Error error = mapper_->v5.freeBuffer(handle);
        if (error != AIMAPPER_ERROR_NONE) {
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Stable-C mapper freeBuffer failed: %d", error);
        }
    }

  private:
    void* library_ = nullptr;
    AIMapper* mapper_ = nullptr;
};

// The Exynos 990 HWC2 does not understand the vendor camera format 0x11d
// when it is handed through the new Composer3 transport.  Passing the raw
// handle preserves the lifetime but still leaves HWC2 trying to scan out a
// private YUV layout as if it were RGB, which is the uniform-green preview
// seen on y2s.  Keep the stock camera lock callback as the source of truth,
// convert only this one preview stream to an ordinary RGBA allocation, and
// let the same stock Gralloc1 backend own the destination handle.  This is a
// compatibility bridge, not a donor blob or a replacement for the camera
// mapper.
class CameraRgbConverter {
  public:
    native_handle_t* convert(const native_handle_t* source,
                             int acquire_fence,
                             native_handle_t* existing_output = nullptr) const {
        const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
        if (!backend || !backend->ready || !backend->cameraReady || !backend->retain ||
            !backend->release || !backend->createDescriptor || !backend->destroyDescriptor ||
            !backend->setDimensions || !backend->setFormat || !backend->setLayerCount ||
            !backend->setProducerUsage || !backend->setConsumerUsage || !backend->allocate ||
            !backend->getDimensions || !backend->getNumFlexPlanes ||
            !backend->cameraLockFlexAsync || !backend->cameraUnlock || !backend->lock ||
            !backend->unlock || !backend->getStride || !backend->getProducerUsage ||
            !backend->getConsumerUsage) {
            if (acquire_fence >= 0) ::close(acquire_fence);
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Camera RGB bridge is unavailable");
            return nullptr;
        }

        native_handle_t* input = source ? native_handle_clone(source) : nullptr;
        if (!input) {
            if (acquire_fence >= 0) ::close(acquire_fence);
            return nullptr;
        }
        // Do not inspect or log every DMA fd here.  This function runs on the
        // Composer thread for every camera buffer; repeatedly fstat/mmap'ing
        // the producer handles makes the camera queue miss its dequeue window.
        // Keep a single bounded probe for post-mortem diagnostics.
        static std::atomic_bool handle_probe_logged{false};
        if (!handle_probe_logged.exchange(true)) {
            __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                "Camera private handle accepted: fds=%d ints=%d",
                                input->numFds, input->numInts);
        }
        if (backend->retain(backend->device, input) != GRALLOC1_ERROR_NONE) {
            freeNativeHandle(input);
            if (acquire_fence >= 0) ::close(acquire_fence);
            return nullptr;
        }

        uint32_t width = 0;
        uint32_t height = 0;
        if (backend->getDimensions(backend->device, input, &width, &height) !=
                    GRALLOC1_ERROR_NONE ||
            width == 0 || height == 0 || width > static_cast<uint32_t>(INT32_MAX) ||
            height > static_cast<uint32_t>(INT32_MAX)) {
            releaseRaw(backend, input);
            if (acquire_fence >= 0) ::close(acquire_fence);
            return nullptr;
        }

        // The original y2s camera mapper was disassembled and verified to
        // pass a null private_module_t to all three legacy camera helpers:
        // get_num_flex_planes(), lock_flex_async(), and lock_async().  Keep
        // that exact ABI until a device trace proves otherwise; supplying the
        // hw_module_t here would be an unverified contract change.
        constexpr const void* kStockCameraModule = nullptr;
        uint32_t plane_count = 0;
        if (backend->cameraGetNumFlexPlanes(kStockCameraModule, input, &plane_count) != 0 ||
            plane_count == 0 || plane_count > 8) {
            releaseRaw(backend, input);
            if (acquire_fence >= 0) ::close(acquire_fence);
            return nullptr;
        }
        std::vector<android_flex_plane_t> planes(plane_count);
        android_flex_layout_t layout{
                .format = FLEX_FORMAT_INVALID,
                .num_planes = plane_count,
                .planes = planes.data(),
        };
        const gralloc1_rect_t region{
                .left = 0,
                .top = 0,
                .width = static_cast<int32_t>(width),
                .height = static_cast<int32_t>(height),
        };
        // Unlike the old camera-side mapper, Composer3 reaches this adapter
        // before HWC has consumed the acquire fence.  The y2s
        // mali_gralloc_lock_flex_async() implementation explicitly waits on
        // and closes a non-negative fence before it exposes the planes.  The
        // previous bridge discarded the duplicate and passed -1, so the
        // preview converter could read the producer's not-yet-written cache
        // and obtain Y/Cb/Cr == 0 (the uniform green frame).  Transfer the
        // duplicate to the stock helper and let it own the wait/close.
        // This exported Mali helper is the legacy camera ABI, not the
        // Gralloc1 callback ABI.  Reconstruct its old combined usage mask
        // from the allocation's producer/consumer domains and add the
        // software-read request.  Passing only a Gralloc1 CPU bit returns a
        // successful lock with an uncached zeroed view on this vendor.
        constexpr uint64_t kLegacyCameraReadOften = 0x3;
        uint64_t producer_usage = 0;
        uint64_t consumer_usage = 0;
        if (backend->getProducerUsage(backend->device, input, &producer_usage) !=
                    GRALLOC1_ERROR_NONE ||
            backend->getConsumerUsage(backend->device, input, &consumer_usage) !=
                    GRALLOC1_ERROR_NONE) {
            producer_usage = 0;
            consumer_usage = 0;
        }
        uint64_t legacy_usage = 0;
        // Gralloc1 splits CPU access into producer/consumer domains and uses
        // bits 0x60 for CPU_WRITE_OFTEN.  The exported Mali camera helper
        // receives the old Android combined mask, where the same request is
        // 0x30.  Hardware bits are intentionally copied only from their
        // domain with the same numeric ABI; CPU bits are translated below.
        switch (producer_usage & 0x0f) {
            case 0x06: legacy_usage |= 0x03; break;  // SW_READ_OFTEN
            case 0x02: legacy_usage |= 0x02; break;  // SW_READ_RARELY
        }
        switch (producer_usage & 0xf0) {
            case 0x60: legacy_usage |= 0x30; break;  // SW_WRITE_OFTEN
            case 0x20: legacy_usage |= 0x20; break;  // SW_WRITE_RARELY
        }
        legacy_usage |= producer_usage & (GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET |
                                          GRALLOC1_PRODUCER_USAGE_PROTECTED |
                                          GRALLOC1_PRODUCER_USAGE_CAMERA |
                                          GRALLOC1_PRODUCER_USAGE_VIDEO_DECODER |
                                          GRALLOC1_PRODUCER_USAGE_SENSOR_DIRECT_DATA);
        legacy_usage |= consumer_usage & (GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE |
                                          GRALLOC1_CONSUMER_USAGE_HWCOMPOSER |
                                          GRALLOC1_CONSUMER_USAGE_CLIENT_TARGET |
                                          GRALLOC1_CONSUMER_USAGE_CURSOR |
                                          GRALLOC1_CONSUMER_USAGE_VIDEO_ENCODER |
                                          GRALLOC1_CONSUMER_USAGE_CAMERA |
                                          GRALLOC1_CONSUMER_USAGE_RENDERSCRIPT |
                                          GRALLOC1_CONSUMER_USAGE_GPU_DATA_BUFFER);
        // A preview surface is allocated with CPU_WRITE_OFTEN for the camera
        // producer, but the converter is a reader.  Passing that producer
        // write bit into the legacy lock path makes this private 0x11d
        // allocation return an all-zero view.  The stock mapper's YCbCr lock
        // uses the read-only mask while it inspects camera buffers.
        legacy_usage &= kLegacyCameraReadOften;
        legacy_usage = kLegacyCameraReadOften;
        static std::atomic_bool usage_probe_logged{false};
        if (!usage_probe_logged.exchange(true)) {
            __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                "Camera usage probe: producer=0x%llx consumer=0x%llx legacy=0x%llx",
                                static_cast<unsigned long long>(producer_usage),
                                static_cast<unsigned long long>(consumer_usage),
                                static_cast<unsigned long long>(legacy_usage));
        }
        // The camera producer owns the original fence carried by Composer3.
        // The converter cannot hand that fence to the legacy lock callback
        // and also keep it available to HWC2, so wait on the duplicate here.
        // Reading before this fence signals produces the exact symptom seen
        // on y2s: a stale preview frame is presented repeatedly until the
        // SurfaceView is detached by returning to Home. Keep the wait short
        // enough that a broken fence falls back to the raw-handle path rather
        // than stalling Camera3 indefinitely.
        if (acquire_fence >= 0) {
            const int wait_status = waitFence(acquire_fence, 250);
            if (wait_status != 0) {
                __android_log_print(ANDROID_LOG_WARN, "Composer3Bridge",
                                    "Camera acquire fence did not signal: %d", wait_status);
            }
            ::close(acquire_fence);
            acquire_fence = -1;
        }
        const int lock_error = backend->cameraLockFlexAsync(
                kStockCameraModule, input, legacy_usage,
                region.left, region.top, region.width, region.height, &layout,
                -1);
        if (lock_error != GRALLOC1_ERROR_NONE) {
            releaseRaw(backend, input);
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Camera private YUV lock failed: %d", lock_error);
            return nullptr;
        }

        const android_flex_plane_t* y_plane = nullptr;
        const android_flex_plane_t* cb_plane = nullptr;
        const android_flex_plane_t* cr_plane = nullptr;
        for (uint32_t index = 0; index < layout.num_planes && index < plane_count; ++index) {
            const android_flex_plane_t& plane = layout.planes[index];
            if (!plane.top_left || plane.h_increment <= 0 || plane.v_increment <= 0) continue;
            if (plane.component == FLEX_COMPONENT_Y) y_plane = &plane;
            if (plane.component == FLEX_COMPONENT_Cb) cb_plane = &plane;
            if (plane.component == FLEX_COMPONENT_Cr) cr_plane = &plane;
        }
        if (!y_plane || !cb_plane || !cr_plane || y_plane->bits_used < 8 ||
            cb_plane->bits_used < 8 || cr_plane->bits_used < 8 ||
            cb_plane->h_increment <= 0 || cr_plane->h_increment <= 0 ||
            cb_plane->v_increment <= 0 || cr_plane->v_increment <= 0) {
            int ignored_fence = -1;
            backend->cameraUnlock(backend->cameraModule, input);
            (void)ignored_fence;
            releaseRaw(backend, input);
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Camera private YUV layout is not convertible");
            return nullptr;
        }

        // A valid private handle can still expose an unusable CPU view on
        // this vendor.  In that case the planes have plausible geometry but
        // every sample is zero; converting that view to RGBA creates the
        // characteristic uniform green preview.  Do not manufacture an
        // image from an unverified mapping.  Returning nullptr deliberately
        // selects handleForBuffer()'s raw-handle fallback, leaving the
        // original 0x11d allocation opaque to the stock HWC2/Mali path.
        const auto samplePlane = [](const android_flex_plane_t* plane,
                                    uint32_t x, uint32_t y) -> uint8_t {
            const auto* row = static_cast<const uint8_t*>(plane->top_left) +
                    static_cast<size_t>(y) * static_cast<size_t>(plane->v_increment);
            return row[static_cast<size_t>(x) * static_cast<size_t>(plane->h_increment)];
        };
        const uint32_t mid_x = width / 2;
        const uint32_t mid_y = height / 2;
        const bool zero_view = samplePlane(y_plane, 0, 0) == 0 &&
                samplePlane(cb_plane, 0, 0) == 0 && samplePlane(cr_plane, 0, 0) == 0 &&
                samplePlane(y_plane, mid_x, mid_y) == 0 &&
                samplePlane(cb_plane, mid_x / 2, mid_y / 2) == 0 &&
                samplePlane(cr_plane, mid_x / 2, mid_y / 2) == 0;
        if (zero_view) {
            backend->cameraUnlock(backend->cameraModule, input);
            // LOCK_FLEX can expose the private 0x11d geometry while its
            // flex-plane mapping remains empty on some camera/HWC hand-offs.
            // Probe the legacy packed lock on the same retained handle after
            // balancing LOCK_FLEX.  This callback is part of the original
            // Mali camera ABI and may reveal a valid linear view without
            // changing the handle or guessing its private plane offsets.
            void* packed = nullptr;
            const int packed_error = backend->cameraLockAsync(
                    kStockCameraModule, input, legacy_usage, region.left, region.top,
                    region.width, region.height, &packed, -1);
            int packed_first = -1;
            int packed_second = -1;
            if (packed_error == GRALLOC1_ERROR_NONE && packed) {
                const auto* bytes = static_cast<const uint8_t*>(packed);
                packed_first = bytes[0];
                packed_second = bytes[1];
                backend->cameraUnlock(backend->cameraModule, input);
            }
            __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                "Camera LOCK_ASYNC probe: error=%d ptr=%p bytes=%d/%d",
                                packed_error, packed, packed_first, packed_second);
            releaseRaw(backend, input);
            __android_log_print(ANDROID_LOG_WARN, "Composer3Bridge",
                                "Camera private YUV CPU view is zero; preserving raw 0x11d handle");
            return nullptr;
        }

        const auto firstSample = [](const android_flex_plane_t* plane) -> int {
            return static_cast<int>(*static_cast<const uint8_t*>(plane->top_left));
        };
        static std::atomic_bool plane_probe_logged{false};
        if (!plane_probe_logged.exchange(true)) {
            __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                "Camera LOCK_FLEX planes: Y=%p h=%d v=%d c=%u; "
                                "Cb=%p h=%d v=%d c=%u; Cr=%p h=%d v=%d c=%u; "
                                "samples=%d/%d/%d",
                                y_plane->top_left, y_plane->h_increment, y_plane->v_increment,
                                y_plane->component, cb_plane->top_left, cb_plane->h_increment,
                                cb_plane->v_increment, cb_plane->component, cr_plane->top_left,
                                cr_plane->h_increment, cr_plane->v_increment, cr_plane->component,
                                firstSample(y_plane), firstSample(cb_plane), firstSample(cr_plane));
        }

        native_handle_t* output = existing_output;
        const bool output_owned = output == nullptr;
        buffer_handle_t allocated = nullptr;
        gralloc1_buffer_descriptor_t descriptor = 0;
        int32_t error = GRALLOC1_ERROR_NONE;
        if (!output) {
            error = backend->createDescriptor(backend->device, &descriptor);
            if (!error) error = backend->setDimensions(backend->device, descriptor, width, height);
            if (!error) error = backend->setFormat(backend->device, descriptor,
                                                    HAL_PIXEL_FORMAT_RGBA_8888);
            if (!error) error = backend->setLayerCount(backend->device, descriptor, 1);
            if (!error) error = backend->setProducerUsage(
                    backend->device, descriptor, GRALLOC1_PRODUCER_USAGE_CPU_WRITE_OFTEN);
            if (!error) error = backend->setConsumerUsage(
                    backend->device, descriptor,
                    GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE | GRALLOC1_CONSUMER_USAGE_HWCOMPOSER);
            if (!error) error = backend->allocate(backend->device, 1, &descriptor, &allocated);
            output = const_cast<native_handle_t*>(allocated);
            if (descriptor) backend->destroyDescriptor(backend->device, descriptor);
            if (error != GRALLOC1_ERROR_NONE || !output) {
                int ignored_fence = -1;
                backend->cameraUnlock(backend->cameraModule, input);
                (void)ignored_fence;
                releaseRaw(backend, input);
                __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                    "Camera RGB allocation failed: %d", error);
                return nullptr;
            }
        }

        uint32_t output_stride = 0;
        void* output_pixels = nullptr;
        const gralloc1_rect_t output_region = region;
        error = backend->getStride(backend->device, output, &output_stride);
        if (!error) {
            error = backend->lock(backend->device, output,
                                  GRALLOC1_PRODUCER_USAGE_CPU_WRITE_OFTEN, 0,
                                  &output_region, &output_pixels, -1);
        }
        if (error != GRALLOC1_ERROR_NONE || !output_pixels || output_stride < width) {
            int ignored_fence = -1;
            if (!error && output_pixels) backend->unlock(backend->device, output, &ignored_fence);
            if (ignored_fence >= 0) ::close(ignored_fence);
            if (output_owned) {
                backend->release(backend->device, output);
                if (!backend->releaseImpliesDelete) freeNativeHandle(output);
            }
            backend->cameraUnlock(backend->cameraModule, input);
            releaseRaw(backend, input);
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Camera RGB destination lock failed: %d stride=%u", error,
                                output_stride);
            return nullptr;
        }

        // Keep the conversion scalar but cache the row/chroma pointers.  The
        // previous implementation called a lambda and recomputed three
        // pointer products for every component of every pixel; at 1440x1080
        // that was enough to stall Camera3 on the Exynos 990.  The increments
        // come from LOCK_FLEX and are retained so this remains valid for a
        // padded or interleaved camera allocation.
        const auto* y_base = static_cast<const uint8_t*>(y_plane->top_left);
        const auto* cb_base = static_cast<const uint8_t*>(cb_plane->top_left);
        const auto* cr_base = static_cast<const uint8_t*>(cr_plane->top_left);
        const size_t y_h_increment = static_cast<size_t>(y_plane->h_increment);
        const size_t y_v_increment = static_cast<size_t>(y_plane->v_increment);
        const size_t cb_h_increment = static_cast<size_t>(cb_plane->h_increment);
        const size_t cb_v_increment = static_cast<size_t>(cb_plane->v_increment);
        const size_t cr_h_increment = static_cast<size_t>(cr_plane->h_increment);
        const size_t cr_v_increment = static_cast<size_t>(cr_plane->v_increment);
        uint8_t* destination = static_cast<uint8_t*>(output_pixels);
        // The S20 camera's LOCK_FLEX view is NV21: Y is linear and its
        // interleaved chroma plane exposes Cr at byte zero, Cb at byte one.
        // Converting it pixel-by-pixel on a Composer worker consumed hundreds
        // of milliseconds per 1440p frame.  Use the Cortex-A77/A55 NEON path
        // only when that exact contract is present; retain the scalar path for
        // all other producer layouts.
        const bool is_nv21 = y_h_increment == 1 && cb_h_increment == 2 &&
                cr_h_increment == 2 && cr_base + 1 == cb_base;
        const bool is_nv12 = y_h_increment == 1 && cb_h_increment == 2 &&
                cr_h_increment == 2 && cb_base + 1 == cr_base;
        for (uint32_t y = 0; y < height; ++y) {
            const uint8_t* y_row = y_base + static_cast<size_t>(y) * y_v_increment;
            const uint8_t* cb_row = cb_base + static_cast<size_t>(y / 2) * cb_v_increment;
            const uint8_t* cr_row = cr_base + static_cast<size_t>(y / 2) * cr_v_increment;
            uint8_t* row = destination + static_cast<size_t>(y) * output_stride * 4;
            uint32_t x = 0;
#if defined(__aarch64__)
            if (is_nv21 || is_nv12) {
                const uint8_t* chroma_row = is_nv21 ? cr_row : cb_row;
                for (; x + 8 <= width; x += 8) {
                    const uint8x8_t luma = vld1_u8(y_row + x);
                    const uint8x8x2_t chroma = vld2_u8(chroma_row + x);
                    const uint8x8_t cb4 = is_nv21 ? chroma.val[1] : chroma.val[0];
                    const uint8x8_t cr4 = is_nv21 ? chroma.val[0] : chroma.val[1];
                    const uint8x8_t cb = vzip_u8(cb4, cb4).val[0];
                    const uint8x8_t cr = vzip_u8(cr4, cr4).val[0];
                    const int16x8_t y16 = vreinterpretq_s16_u16(vmovl_u8(luma));
                    const int16x8_t cb16 = vsubq_s16(
                            vreinterpretq_s16_u16(vmovl_u8(cb)), vdupq_n_s16(128));
                    const int16x8_t cr16 = vsubq_s16(
                            vreinterpretq_s16_u16(vmovl_u8(cr)), vdupq_n_s16(128));
                    const int16x8_t red = vaddq_s16(y16,
                            vshrq_n_s16(vmulq_n_s16(cr16, 179), 7));
                    const int16x8_t green = vsubq_s16(y16, vshrq_n_s16(vaddq_s16(
                            vmulq_n_s16(cb16, 44), vmulq_n_s16(cr16, 91)), 7));
                    const int16x8_t blue = vaddq_s16(y16,
                            vshrq_n_s16(vmulq_n_s16(cb16, 227), 7));
                    uint8x8x4_t rgba{{vqmovun_s16(red), vqmovun_s16(green),
                                      vqmovun_s16(blue), vdup_n_u8(255)}};
                    vst4_u8(row + static_cast<size_t>(x) * 4, rgba);
                }
            }
#endif
            for (; x < width; ++x) {
                const int luma = y_row[static_cast<size_t>(x) * y_h_increment];
                const size_t chroma_x = static_cast<size_t>(x / 2);
                const int cb = cb_row[chroma_x * cb_h_increment] - 128;
                const int cr = cr_row[chroma_x * cr_h_increment] - 128;
                const int red = luma + (179 * cr) / 128;
                const int green = luma - (44 * cb + 91 * cr) / 128;
                const int blue = luma + (227 * cb) / 128;
                uint8_t* pixel = row + static_cast<size_t>(x) * 4;
                pixel[0] = static_cast<uint8_t>(red < 0 ? 0 : red > 255 ? 255 : red);
                pixel[1] = static_cast<uint8_t>(green < 0 ? 0 : green > 255 ? 255 : green);
                pixel[2] = static_cast<uint8_t>(blue < 0 ? 0 : blue > 255 ? 255 : blue);
                pixel[3] = 255;
            }
        }
        static std::atomic_bool pixel_probe_logged{false};
        if (!pixel_probe_logged.exchange(true)) {
            const uint32_t mid_x = width / 2;
            const uint32_t mid_y = height / 2;
            const int mid_y_sample = y_base[static_cast<size_t>(mid_y) * y_v_increment +
                                            static_cast<size_t>(mid_x) * y_h_increment];
            const int mid_cb_sample = cb_base[static_cast<size_t>(mid_y / 2) * cb_v_increment +
                                              static_cast<size_t>(mid_x / 2) * cb_h_increment];
            const int mid_cr_sample = cr_base[static_cast<size_t>(mid_y / 2) * cr_v_increment +
                                              static_cast<size_t>(mid_x / 2) * cr_h_increment];
            const uint8_t* first = destination;
            const uint8_t* middle = destination +
                    (static_cast<size_t>(mid_y) * output_stride + mid_x) * 4;
            __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                "Camera YUV probe: first=%d/%d/%d mid=%d/%d/%d; "
                                "RGBA first=%u/%u/%u mid=%u/%u/%u",
                                static_cast<int>(y_base[0]), static_cast<int>(cb_base[0]),
                                static_cast<int>(cr_base[0]),
                                mid_y_sample, mid_cb_sample, mid_cr_sample,
                                first[0], first[1], first[2], middle[0], middle[1], middle[2]);
        }
        int output_fence = -1;
        const int unlock_error = backend->unlock(backend->device, output, &output_fence);
        // Gralloc may return a cache-maintenance fence for the CPU-written
        // RGBA destination. HWC2 receives the handle immediately after this
        // function returns, so closing that fence without waiting can make it
        // scan out the previous conversion. Consume it before publishing the
        // handle; the CPU write itself is already complete at this point.
        if (output_fence >= 0) {
            const int wait_status = waitFence(output_fence, 250);
            if (wait_status != 0) {
                __android_log_print(ANDROID_LOG_WARN, "Composer3Bridge",
                                    "Camera output fence did not signal: %d", wait_status);
            }
            ::close(output_fence);
        }
        const int source_unlock_error = backend->cameraUnlock(backend->cameraModule, input);
        releaseRaw(backend, input);
        if (unlock_error != GRALLOC1_ERROR_NONE || source_unlock_error != GRALLOC1_ERROR_NONE) {
            if (output_owned) {
                backend->release(backend->device, output);
                if (!backend->releaseImpliesDelete) freeNativeHandle(output);
            }
            __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                "Camera RGB unlock failed: dst=%d src=%d", unlock_error,
                                source_unlock_error);
            return nullptr;
        }
        // Keep the hot path silent.  A log record per converted frame was
        // enough to add visible back-pressure to Camera3 on this device.
        return output;
    }

    void release(native_handle_t* handle) const {
        if (!handle) return;
        const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
        if (!backend || !backend->ready || !backend->release ||
            backend->release(backend->device, handle) != GRALLOC1_ERROR_NONE) {
            freeNativeHandle(handle);
            return;
        }
        if (!backend->releaseImpliesDelete) freeNativeHandle(handle);
    }

  private:
    static void releaseRaw(const exynos990_gralloc_backend_t* backend,
                           native_handle_t* handle) {
        if (!backend || !handle) return;
        if (!backend->release ||
            backend->release(backend->device, handle) != GRALLOC1_ERROR_NONE) {
            freeNativeHandle(handle);
            return;
        }
        if (!backend->releaseImpliesDelete) freeNativeHandle(handle);
    }
};


bool isPrimaryDisplay(int64_t display) {
    return display == 0;
}

void synchronizePanelMode(exynos990_hwc2_session* session, uint32_t config) {
    if (!session) return;
    const int error = exynos990_hwc2_session_set_scaled_resolution(session, config);
    if (error != HWC2_ERROR_NONE) {
        __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                            "Unable to synchronize physical panel for config %u: %d",
                            config, error);
        return;
    }
    __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                        "Physical panel scaler synchronized for HWC2 config %u", config);
}

class Hwc2ComposerClient final : public composer3::BnComposerClient {
  public:
    Hwc2ComposerClient() {
        // Do not probe the proprietary HWC2 module through a temporary
        // open/query/close cycle.  Its ExynosDevice destructor waits for
        // hardware threads that are shared with the persistent HWC2 service,
        // so closing the probe can block SurfaceFlinger's createClient call.
        // The panel's native mode is 60 Hz, which is also the safe fallback
        // used by the callback adapter below.
        vsync_period_ns_ = 16666666;
        (void)exynos990_hwc2_session_open(0, &session_);
    }

    ~Hwc2ComposerClient() override {
        exynos990_hwc2_session_close(session_);
        for (auto& entry : buffer_handles_) releaseHandle(entry.second);
        for (auto& entry : retired_handles_) {
            for (native_handle_t* handle : entry.second) releaseHandle(handle);
        }
        for (auto& entry : camera_source_handles_) importer_.releaseRaw(entry.second);
        for (auto& entry : camera_output_pool_) {
            for (native_handle_t* handle : entry.second) releaseOwnedCameraHandle(handle);
        }
    }

    ndk::ScopedAStatus createLayer(int64_t display, int32_t buffer_slot_count,
                                   int64_t* out_layer) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_layer) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0 || buffer_slot_count <= 0) {
            return serviceError(composer3::IComposerClient::EX_BAD_PARAMETER,
                                "invalid display or buffer slot count");
        }
        uint64_t layer = 0;
        const int error = exynos990_hwc2_session_create_layer(session_, &layer);
        if (error != HWC2_ERROR_NONE) return displayError(error, "createLayer");
        *out_layer = static_cast<int64_t>(layer);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus destroyLayer(int64_t display, int64_t layer) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (display != 0 || layer < 0) {
            return serviceError(composer3::IComposerClient::EX_BAD_PARAMETER,
                                "invalid display or layer");
        }
        const int error = exynos990_hwc2_session_destroy_layer(
                session_, static_cast<uint64_t>(layer));
        if (error == HWC2_ERROR_NONE) {
            for (auto it = buffer_handles_.begin(); it != buffer_handles_.end();) {
                if (it->first.first == static_cast<uint64_t>(layer)) {
                    releaseHandle(it->second);
                    it = buffer_handles_.erase(it);
                } else {
                    ++it;
                }
            }
            for (auto it = retired_handles_.begin(); it != retired_handles_.end();) {
                if (it->first.first == static_cast<uint64_t>(layer)) {
                    for (native_handle_t* handle : it->second) releaseHandle(handle);
                    it = retired_handles_.erase(it);
                } else {
                    ++it;
                }
            }
            releaseCameraSources(static_cast<uint64_t>(layer));
            releaseOwnedCameraHandles(static_cast<uint64_t>(layer));
            private_camera_yuv_layers_.erase(static_cast<uint64_t>(layer));
            converted_camera_layers_.erase(static_cast<uint64_t>(layer));
        }
        return error == HWC2_ERROR_NONE ? ndk::ScopedAStatus::ok()
                                        : displayError(error, "destroyLayer");
    }

    ndk::ScopedAStatus registerCallback(
            const std::shared_ptr<composer3::IComposerCallback>& callback) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!callback) return serviceError(composer3::IComposerClient::EX_BAD_PARAMETER,
                                           "null Composer3 callback");
        if (!session_) return displayError(HWC2_ERROR_NO_RESOURCES, "registerCallback");
        callback_ = callback;
        const exynos990_hwc2_callbacks callbacks{
                this, &Hwc2ComposerClient::onHotplug, &Hwc2ComposerClient::onRefresh,
                &Hwc2ComposerClient::onVsync, &Hwc2ComposerClient::onVsyncPeriodTimingChanged,
                &Hwc2ComposerClient::onSeamlessPossible};
        const int error = exynos990_hwc2_session_register_callbacks(session_, &callbacks);
        if (error != HWC2_ERROR_NONE) {
            callback_.reset();
            return displayError(error, "registerCallback");
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus executeCommands(
            const std::vector<composer3::DisplayCommand>& commands,
            std::vector<composer3::CommandResultPayload>* out_results) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_results) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!session_) return displayError(HWC2_ERROR_NO_RESOURCES, "executeCommands");
        out_results->clear();
        for (size_t command_index = 0; command_index < commands.size(); ++command_index) {
            const auto& command = commands[command_index];
            if (command.display != 0) {
                out_results->push_back(commandError(command_index,
                                                     composer3::IComposerClient::EX_BAD_DISPLAY));
                continue;
            }
            int command_status = applyDisplayCommand(command);
            if (command_status != HWC2_ERROR_NONE) {
                __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                                    "executeCommands: apply display failed status=%d layers=%zu clientTarget=%d colorTransform=%d",
                                    command_status, command.layers.size(),
                                    command.clientTarget.has_value(),
                                    command.colorTransformMatrix.has_value());
                out_results->push_back(commandError(command_index, toComposerError(command_status)));
                continue;
            }

            // AIDL batches the new client target/layer state and the accept
            // flag in one DisplayCommand.  Samsung's HWC2 consumes the
            // client target before acceptDisplayChanges; accepting first
            // leaves the DDI scaler transaction attached to the old target
            // and the logical mode changes without updating physical scanout.
            if (command.acceptDisplayChanges) {
                const int accept_status = exynos990_hwc2_session_accept_changes(session_);
                if (accept_status != HWC2_ERROR_NONE) {
                    out_results->push_back(commandError(
                            command_index, toComposerError(accept_status)));
                    continue;
                }
                validate_pending_accept_ = false;
            }

            if (command.validateDisplay) {
                uint32_t num_types = 0;
                uint32_t num_requests = 0;
                command_status = exynos990_hwc2_session_validate(session_, &num_types,
                                                                  &num_requests);
                if (command_status != HWC2_ERROR_NONE) {
                    out_results->push_back(commandError(command_index,
                                                         toComposerError(command_status)));
                    continue;
                }
                if (num_requests != 0) {
                    command_status = appendDisplayRequests(command.display, out_results);
                    if (command_status != HWC2_ERROR_NONE) {
                        out_results->push_back(commandError(
                                command_index, toComposerError(command_status)));
                        continue;
                    }
                }
                validate_pending_accept_ = true;
                if (num_types != 0) {
                    std::vector<uint64_t> layers(num_types);
                    std::vector<int32_t> types(num_types);
                    uint32_t count = num_types;
                    command_status = exynos990_hwc2_session_get_changed_composition_types(
                            session_, &count, layers.data(), types.data());
                    if (command_status != HWC2_ERROR_NONE) {
                        out_results->push_back(commandError(
                                command_index, toComposerError(command_status)));
                        continue;
                    }
                    composer3::ChangedCompositionTypes changed;
                    changed.display = command.display;
                    changed.layers.reserve(count);
                    for (uint32_t i = 0; i < count; ++i) {
                        composer3::ChangedCompositionLayer layer;
                        layer.layer = static_cast<int64_t>(layers[i]);
                        layer.composition = static_cast<composer3::Composition>(types[i]);
                        changed.layers.push_back(layer);
                    }
                    out_results->push_back(composer3::CommandResultPayload::make<
                            composer3::CommandResultPayload::changedCompositionTypes>(
                            std::move(changed)));
                }
            }
            if (command.presentOrValidateDisplay) {
                uint32_t num_types = 0;
                uint32_t num_requests = 0;
                command_status = exynos990_hwc2_session_validate(session_, &num_types,
                                                                  &num_requests);
                if (command_status != HWC2_ERROR_NONE) {
                    out_results->push_back(commandError(
                            command_index, toComposerError(command_status)));
                    continue;
                }
                // Display/layer requests (CLEAR_CLIENT_TARGET for an HDR or
                // overlay layer below client-composited content, ...) are
                // returned to SurfaceFlinger; the frame then cannot be
                // presented directly and is reported as Validated.
                if (num_requests != 0) {
                    command_status = appendDisplayRequests(command.display, out_results);
                    if (command_status != HWC2_ERROR_NONE) {
                        out_results->push_back(commandError(
                                command_index, toComposerError(command_status)));
                        continue;
                    }
                }
                validate_pending_accept_ = true;
                if (num_types != 0 || num_requests != 0) {
                    if (num_types != 0) {
                        std::vector<uint64_t> layers(num_types);
                        std::vector<int32_t> types(num_types);
                        uint32_t count = num_types;
                        command_status = exynos990_hwc2_session_get_changed_composition_types(
                                session_, &count, layers.data(), types.data());
                        if (command_status != HWC2_ERROR_NONE) {
                            out_results->push_back(commandError(
                                    command_index, toComposerError(command_status)));
                            continue;
                        }
                        composer3::ChangedCompositionTypes changed;
                        changed.display = command.display;
                        changed.layers.reserve(count);
                        for (uint32_t i = 0; i < count; ++i) {
                            composer3::ChangedCompositionLayer layer;
                            layer.layer = static_cast<int64_t>(layers[i]);
                            layer.composition = static_cast<composer3::Composition>(types[i]);
                            changed.layers.push_back(layer);
                        }
                        out_results->push_back(composer3::CommandResultPayload::make<
                                composer3::CommandResultPayload::changedCompositionTypes>(
                                std::move(changed)));
                    }
                    composer3::PresentOrValidate result;
                    result.display = command.display;
                    result.result = composer3::PresentOrValidate::Result::Validated;
                    out_results->push_back(composer3::CommandResultPayload::make<
                            composer3::CommandResultPayload::presentOrValidateResult>(
                            std::move(result)));
                    continue;
                }

                // Unlike Composer3, Samsung HWC2 requires an explicit
                // accept even when validate reports no composition changes.
                // The client target was applied at the start of this command,
                // so accepting here preserves clientTarget -> accept -> present.
                command_status = exynos990_hwc2_session_accept_changes(session_);
                if (command_status != HWC2_ERROR_NONE) {
                    out_results->push_back(commandError(
                            command_index, toComposerError(command_status)));
                    continue;
                }
                validate_pending_accept_ = false;

                int32_t fence = -1;
                command_status = exynos990_hwc2_session_present(session_, &fence);
                if (command_status != HWC2_ERROR_NONE) {
                    out_results->push_back(commandError(
                            command_index, toComposerError(command_status)));
                    continue;
                }
                // HWC2 uses -1 as the valid "no fence" sentinel.  AIDL's
                // ParcelFileDescriptor is non-nullable, so serializing -1
                // aborts the whole executeCommands transaction.  An omitted
                // result is read by SurfaceFlinger as Fence::NO_FENCE.
                if (fence >= 0) {
                    composer3::PresentFence present;
                    present.display = command.display;
                    present.fence = ndk::ScopedFileDescriptor(fence);
                    out_results->push_back(composer3::CommandResultPayload::make<
                            composer3::CommandResultPayload::presentFence>(std::move(present)));
                }

                uint32_t release_count = 0;
                const int release_status =
                        exynos990_hwc2_session_get_release_fences(session_, &release_count,
                                                                  nullptr, nullptr);
                if (release_status == HWC2_ERROR_NONE && release_count != 0) {
                    std::vector<uint64_t> release_layers(release_count);
                    std::vector<int32_t> release_fences(release_count, -1);
                    uint32_t returned = release_count;
                    const int fetch_status = exynos990_hwc2_session_get_release_fences(
                            session_, &returned, release_layers.data(), release_fences.data());
                    if (fetch_status != HWC2_ERROR_NONE) {
                        for (int fd : release_fences) if (fd >= 0) ::close(fd);
                        out_results->push_back(commandError(
                                command_index, toComposerError(fetch_status)));
                        continue;
                    }
                    composer3::ReleaseFences releases;
                    releases.display = command.display;
                    releases.layers.reserve(returned);
                    for (uint32_t i = 0; i < returned; ++i) {
                        if (release_fences[i] < 0) continue;
                        rememberCameraReleaseFence(release_layers[i], release_fences[i]);
                        composer3::ReleaseFences::Layer release;
                        release.layer = static_cast<int64_t>(release_layers[i]);
                        release.fence = ndk::ScopedFileDescriptor(release_fences[i]);
                        releases.layers.push_back(std::move(release));
                    }
                    out_results->push_back(composer3::CommandResultPayload::make<
                            composer3::CommandResultPayload::releaseFences>(std::move(releases)));
                }
                composer3::PresentOrValidate result;
                result.display = command.display;
                result.result = composer3::PresentOrValidate::Result::Presented;
                out_results->push_back(composer3::CommandResultPayload::make<
                        composer3::CommandResultPayload::presentOrValidateResult>(
                        std::move(result)));
                continue;
            }
            if (command.presentDisplay) {
                if (validate_pending_accept_) {
                    command_status = exynos990_hwc2_session_accept_changes(session_);
                    if (command_status != HWC2_ERROR_NONE) {
                        out_results->push_back(commandError(
                                command_index, toComposerError(command_status)));
                        continue;
                    }
                    validate_pending_accept_ = false;
                }
                int32_t fence = -1;
                command_status = exynos990_hwc2_session_present(session_, &fence);
                if (command_status != HWC2_ERROR_NONE) {
                    out_results->push_back(commandError(
                            command_index, toComposerError(command_status)));
                    continue;
                }
                if (fence >= 0) {
                    composer3::PresentFence present;
                    present.display = command.display;
                    present.fence = ndk::ScopedFileDescriptor(fence);
                    out_results->push_back(composer3::CommandResultPayload::make<
                            composer3::CommandResultPayload::presentFence>(std::move(present)));
                }
                uint32_t release_count = 0;
                const int release_status =
                        exynos990_hwc2_session_get_release_fences(session_, &release_count,
                                                                  nullptr, nullptr);
                if (release_status == HWC2_ERROR_NONE && release_count != 0) {
                    std::vector<uint64_t> release_layers(release_count);
                    std::vector<int32_t> release_fences(release_count, -1);
                    uint32_t returned = release_count;
                    const int fetch_status = exynos990_hwc2_session_get_release_fences(
                            session_, &returned, release_layers.data(), release_fences.data());
                    if (fetch_status != HWC2_ERROR_NONE) {
                        for (int fd : release_fences) if (fd >= 0) ::close(fd);
                        out_results->push_back(commandError(
                                command_index, toComposerError(fetch_status)));
                        continue;
                    }
                    composer3::ReleaseFences releases;
                    releases.display = command.display;
                    releases.layers.reserve(returned);
                    for (uint32_t i = 0; i < returned; ++i) {
                        if (release_fences[i] < 0) continue;
                        rememberCameraReleaseFence(release_layers[i], release_fences[i]);
                        composer3::ReleaseFences::Layer release;
                        release.layer = static_cast<int64_t>(release_layers[i]);
                        release.fence = ndk::ScopedFileDescriptor(release_fences[i]);
                        releases.layers.push_back(std::move(release));
                    }
                    out_results->push_back(composer3::CommandResultPayload::make<
                            composer3::CommandResultPayload::releaseFences>(std::move(releases)));
                }
            }
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getActiveConfig(int64_t display, int32_t* out_config) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_config) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getActiveConfig");
        }
        uint32_t config = 0;
        const int error = exynos990_hwc2_session_get_active_config(session_, &config);
        if (error != HWC2_ERROR_NONE) return displayError(error, "getActiveConfig");
        const int cache_error = ensureDisplayConfigCacheLocked();
        if (cache_error == HWC2_ERROR_NONE && findDisplayConfigLocked(config)) {
            active_config_id_ = static_cast<int32_t>(config);
        }
        *out_config = static_cast<int32_t>(config);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayConfigs(int64_t display, std::vector<int32_t>* out_configs)
            override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_configs) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayConfigs");
        }
        const int error = ensureDisplayConfigCacheLocked();
        if (error != HWC2_ERROR_NONE) return displayError(error, "getDisplayConfigs");
        out_configs->clear();
        out_configs->reserve(display_configs_.size());
        for (const auto& config : display_configs_) out_configs->push_back(config.id);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayAttribute(int64_t display, int32_t config,
                                           composer3::DisplayAttribute attribute,
                                           int32_t* out_value) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_value) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayAttribute");
        }
        if (config < 0 || attribute == composer3::DisplayAttribute::INVALID) {
            return serviceError(composer3::IComposerClient::EX_BAD_PARAMETER,
                                "invalid display attribute query");
        }
        const int cache_error = ensureDisplayConfigCacheLocked();
        if (cache_error != HWC2_ERROR_NONE) return displayError(cache_error, "getDisplayAttribute");
        const DisplayConfigState* state = findDisplayConfigLocked(static_cast<uint32_t>(config));
        if (!state) return displayError(HWC2_ERROR_BAD_CONFIG, "getDisplayAttribute");
        switch (static_cast<int32_t>(attribute)) {
            case HWC2_ATTRIBUTE_WIDTH: *out_value = state->width; return ndk::ScopedAStatus::ok();
            case HWC2_ATTRIBUTE_HEIGHT: *out_value = state->height; return ndk::ScopedAStatus::ok();
            case HWC2_ATTRIBUTE_VSYNC_PERIOD: *out_value = state->vsync_period_ns; return ndk::ScopedAStatus::ok();
            case HWC2_ATTRIBUTE_DPI_X: *out_value = state->dpi_x; return ndk::ScopedAStatus::ok();
            case HWC2_ATTRIBUTE_DPI_Y: *out_value = state->dpi_y; return ndk::ScopedAStatus::ok();
            case HWC2_ATTRIBUTE_CONFIG_GROUP: *out_value = state->group; return ndk::ScopedAStatus::ok();
            default: break;
        }
        const int error = exynos990_hwc2_session_get_display_attribute(
                session_, static_cast<uint32_t>(config), static_cast<int32_t>(attribute), out_value);
        return error == HWC2_ERROR_NONE ? ndk::ScopedAStatus::ok()
                                        : displayError(error, "getDisplayAttribute");
    }

    ndk::ScopedAStatus getDisplayConnectionType(
            int64_t display, composer3::DisplayConnectionType* out_type) override {
        if (!out_type) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display)) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayConnectionType");
        }
        *out_type = composer3::DisplayConnectionType::INTERNAL;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayName(int64_t display, std::string* out_name) override {
        if (!out_name) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display)) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayName");
        }
        *out_name = "Primary Display";
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayVsyncPeriod(int64_t display, int32_t* out_period) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_period) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayVsyncPeriod");
        }
        const int error = ensureDisplayConfigCacheLocked();
        if (error != HWC2_ERROR_NONE) return displayError(error, "getDisplayVsyncPeriod");
        uint32_t active = 0;
        if (exynos990_hwc2_session_get_active_config(session_, &active) != HWC2_ERROR_NONE) {
            active = static_cast<uint32_t>(active_config_id_);
        }
        const DisplayConfigState* state = findDisplayConfigLocked(active);
        if (!state) return displayError(HWC2_ERROR_BAD_CONFIG, "getDisplayVsyncPeriod");
        active_config_id_ = state->id;
        vsync_period_ns_ = state->vsync_period_ns;
        *out_period = state->vsync_period_ns;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayConfigurations(
            int64_t display, int32_t max_frame_interval_ns,
            std::vector<composer3::DisplayConfiguration>* out_configs) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        (void)max_frame_interval_ns;
        if (!out_configs) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayConfigurations");
        }
        const int error = ensureDisplayConfigCacheLocked();
        if (error != HWC2_ERROR_NONE) return displayError(error, "getDisplayConfigurations");
        out_configs->clear();
        out_configs->reserve(display_configs_.size());
        for (const auto& state : display_configs_) {
            composer3::DisplayConfiguration config;
            config.configId = state.id;
            config.width = state.width;
            config.height = state.height;
            config.vsyncPeriod = state.vsync_period_ns;
            if (state.dpi_x > 0 && state.dpi_y > 0) {
                config.dpi = composer3::DisplayConfiguration::Dpi{
                        static_cast<float>(state.dpi_x) / 1000.0f,
                        static_cast<float>(state.dpi_y) / 1000.0f};
            } else {
                config.dpi.reset();
            }
            config.configGroup = state.group;
            config.vrrConfig.reset();
            config.hdrOutputType = composer3::OutputType::SDR;
            out_configs->push_back(std::move(config));
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setActiveConfig(int64_t display, int32_t config) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (display != 0 || config < 0) {
            return serviceError(composer3::IComposerClient::EX_BAD_PARAMETER,
                                "invalid display or config");
        }
        const int error = applyDisplayConfigLocked(config);
        if (error != HWC2_ERROR_NONE) return displayError(error, "setActiveConfig");
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayPhysicalOrientation(
            int64_t display, graphics_common::Transform* out_transform) override {
        if (!out_transform) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display)) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayPhysicalOrientation");
        }
        *out_transform = graphics_common::Transform::NONE;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getColorModes(int64_t display,
                                     std::vector<composer3::ColorMode>* out_modes) override {
        if (!out_modes) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display)) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getColorModes");
        }
        out_modes->assign(1, composer3::ColorMode::NATIVE);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getMaxVirtualDisplayCount(int32_t* out_count) override {
        if (!out_count) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        *out_count = 0;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus createVirtualDisplay(
            int32_t, int32_t, graphics_common::PixelFormat, int32_t,
            composer3::VirtualDisplay*) override {
        return unsupported("Exynos 990 does not expose virtual displays through HWC2");
    }

    ndk::ScopedAStatus destroyVirtualDisplay(int64_t) override {
        return unsupported("virtual displays are not supported");
    }

    ndk::ScopedAStatus getDataspaceSaturationMatrix(
            graphics_common::Dataspace, std::vector<float>* out_matrix) override {
        if (!out_matrix) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        out_matrix->assign({1.0f, 0.0f, 0.0f, 0.0f,
                            0.0f, 1.0f, 0.0f, 0.0f,
                            0.0f, 0.0f, 1.0f, 0.0f,
                            0.0f, 0.0f, 0.0f, 1.0f});
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayCapabilities(
            int64_t display, std::vector<composer3::DisplayCapability>* out_capabilities) override {
        if (!out_capabilities) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayCapabilities");
        out_capabilities->clear();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayIdentificationData(
            int64_t, composer3::DisplayIdentification*) override {
        return unsupported("display identification is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getDisplayedContentSample(
            int64_t, int64_t, int64_t, composer3::DisplayContentSample*) override {
        return unsupported("content sampling is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getDisplayedContentSamplingAttributes(
            int64_t, composer3::DisplayContentSamplingAttributes*) override {
        return unsupported("content sampling is not exported by the stock HWC2");
    }

    // HDR: the Exynos 990 HWC2 exports getHdrCapabilities and the per-frame
    // metadata entry points.  Without them SurfaceFlinger treats the panel as
    // SDR-only and tone-maps every PQ/HLG layer on the GPU.  When the HWC2
    // lacks an entry point the answer stays empty, as before.
    ndk::ScopedAStatus getHdrCapabilities(int64_t display,
                                          composer3::HdrCapabilities* out_caps) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_caps) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getHdrCapabilities");
        }
        *out_caps = {};
        uint32_t count = 0;
        float max_lum = 0.0f, max_avg = 0.0f, min_lum = 0.0f;
        int error = exynos990_hwc2_session_get_hdr_capabilities(session_, &count, nullptr, &max_lum,
                                                                &max_avg, &min_lum);
        if (error == HWC2_ERROR_UNSUPPORTED) return ndk::ScopedAStatus::ok();
        if (error != HWC2_ERROR_NONE) return displayError(error, "getHdrCapabilities");
        std::vector<int32_t> types(count);
        if (count) {
            error = exynos990_hwc2_session_get_hdr_capabilities(session_, &count, types.data(),
                                                                &max_lum, &max_avg, &min_lum);
            if (error != HWC2_ERROR_NONE) return displayError(error, "getHdrCapabilities");
            types.resize(count);
        }
        for (const int32_t type : types) {
            out_caps->types.push_back(static_cast<graphics_common::Hdr>(type));
        }
        out_caps->maxLuminance = max_lum;
        out_caps->maxAverageLuminance = max_avg;
        out_caps->minLuminance = min_lum;
        __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                            "HDR capabilities: %u types, luminance max %.1f avg %.1f min %.3f",
                            count, max_lum, max_avg, min_lum);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getPerFrameMetadataKeys(
            int64_t display, std::vector<composer3::PerFrameMetadataKey>* out_keys) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_keys) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        out_keys->clear();
        if (!isPrimaryDisplay(display) || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getPerFrameMetadataKeys");
        }
        uint32_t count = 0;
        int error = exynos990_hwc2_session_get_per_frame_metadata_keys(session_, &count, nullptr);
        if (error == HWC2_ERROR_UNSUPPORTED) return ndk::ScopedAStatus::ok();
        if (error != HWC2_ERROR_NONE) return displayError(error, "getPerFrameMetadataKeys");
        std::vector<int32_t> keys(count);
        if (count) {
            error = exynos990_hwc2_session_get_per_frame_metadata_keys(session_, &count,
                                                                       keys.data());
            if (error != HWC2_ERROR_NONE) return displayError(error, "getPerFrameMetadataKeys");
            keys.resize(count);
        }
        for (const int32_t key : keys) {
            out_keys->push_back(static_cast<composer3::PerFrameMetadataKey>(key));
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getReadbackBufferAttributes(
            int64_t, composer3::ReadbackBufferAttributes*) override {
        return unsupported("readback buffers are not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getReadbackBufferFence(int64_t, ndk::ScopedFileDescriptor*) override {
        return unsupported("readback buffers are not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getRenderIntents(
            int64_t display, composer3::ColorMode,
            std::vector<composer3::RenderIntent>* out_intents) override {
        if (!out_intents) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "getRenderIntents");
        out_intents->clear();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getSupportedContentTypes(
            int64_t display, std::vector<composer3::ContentType>* out_types) override {
        if (!out_types) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "getSupportedContentTypes");
        out_types->clear();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getDisplayDecorationSupport(
            int64_t display,
            std::optional<graphics_common::DisplayDecorationSupport>* out_support) override {
        if (!out_support) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "getDisplayDecorationSupport");
        }
        out_support->reset();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setActiveConfigWithConstraints(
            int64_t display, int32_t config,
            const composer3::VsyncPeriodChangeConstraints& constraints,
            composer3::VsyncPeriodChangeTimeline* out_timeline) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (!out_timeline) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0 || config < 0 || !session_) {
            return serviceError(composer3::IComposerClient::EX_BAD_PARAMETER,
                                "invalid display, config, or Composer3 session");
        }
        const int cache_error = ensureDisplayConfigCacheLocked();
        if (cache_error != HWC2_ERROR_NONE) {
            return displayError(cache_error, "setActiveConfigWithConstraints");
        }
        const DisplayConfigState* requested = findDisplayConfigLocked(
                static_cast<uint32_t>(config));
        const DisplayConfigState* active = findDisplayConfigLocked(
                static_cast<uint32_t>(active_config_id_));
        if (!requested) return displayError(HWC2_ERROR_BAD_CONFIG, "setActiveConfigWithConstraints");
        if (constraints.seamlessRequired && active && active->group != requested->group) {
            return displayError(HWC2_ERROR_SEAMLESS_NOT_ALLOWED,
                                "resolution changes cross physical HWC groups");
        }

        // The stock Exynos 990 HWC2 constraints entry point reports timing but
        // skips the DDI scaler transaction.  The legacy entry point is the
        // authoritative physical transition, so use it and return its timing
        // in the Composer3 format expected by SurfaceFlinger.
        const int error = applyDisplayConfigLocked(config);
        if (error != HWC2_ERROR_NONE) return displayError(error, "setActiveConfigWithConstraints");

        const int64_t now = monotonicTimeNanos();
        const int64_t period = std::max<int64_t>(1, requested->vsync_period_ns);
        const int64_t desired = std::max(now, constraints.desiredTimeNanos);
        const int64_t applied_time = ((desired + period - 1) / period) * period;
        out_timeline->newVsyncAppliedTimeNanos = applied_time;
        out_timeline->refreshTimeNanos = applied_time;
        out_timeline->refreshRequired = false;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setBootDisplayConfig(int64_t, int32_t) override {
        return unsupported("boot display configuration is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus clearBootDisplayConfig(int64_t) override {
        return unsupported("boot display configuration is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getPreferredBootDisplayConfig(int64_t, int32_t*) override {
        return unsupported("boot display configuration is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus setAutoLowLatencyMode(int64_t, bool) override {
        return unsupported("auto low latency mode is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus setClientTargetSlotCount(int64_t, int32_t) override {
        return unsupported("client target slot count is fixed by the HWC2 backend");
    }

    ndk::ScopedAStatus setColorMode(int64_t display, composer3::ColorMode mode,
                                    composer3::RenderIntent) override {
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "setColorMode");
        if (mode != composer3::ColorMode::NATIVE) {
            return unsupported("the stock HWC2 exposes only the native color mode");
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setContentType(int64_t display, composer3::ContentType) override {
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "setContentType");
        return unsupported("content type is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus setDisplayedContentSamplingEnabled(
            int64_t, bool, composer3::FormatColorComponent, int64_t) override {
        return unsupported("content sampling is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus setReadbackBuffer(
            int64_t, const hardware_common::NativeHandle&, const ndk::ScopedFileDescriptor&) override {
        return unsupported("readback buffers are not exported by the stock HWC2");
    }

    ndk::ScopedAStatus setIdleTimerEnabled(int64_t, int32_t) override {
        return unsupported("idle timer is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getOverlaySupport(composer3::OverlayProperties* out_properties) override {
        if (!out_properties) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        // Returning an empty capability set tells SurfaceFlinger to use client
        // composition without making the startup path fail on an optional
        // HWC3 metadata query.
        out_properties->combinations.clear();
        out_properties->supportMixedColorSpaces = false;
        out_properties->lutProperties.reset();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getHdrConversionCapabilities(
            std::vector<graphics_common::HdrConversionCapability>* out_capabilities) override {
        if (!out_capabilities) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        out_capabilities->clear();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setHdrConversionStrategy(
            const graphics_common::HdrConversionStrategy&, graphics_common::Hdr*) override {
        return unsupported("HDR conversion is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus setRefreshRateChangedCallbackDebugEnabled(int64_t, bool) override {
        return unsupported("refresh rate debug callbacks are not exported by the stock HWC2");
    }

    ndk::ScopedAStatus notifyExpectedPresent(
            int64_t, const composer3::ClockMonotonicTimestamp&, int32_t) override {
        return unsupported("expected present timing is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getMaxLayerPictureProfiles(int64_t display, int32_t* out_count) override {
        if (!out_count) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "getMaxLayerPictureProfiles");
        *out_count = 0;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus startHdcpNegotiation(
            int64_t, const aidl::android::hardware::drm::HdcpLevels&) override {
        return unsupported("HDCP negotiation is not exported by the stock HWC2");
    }

    ndk::ScopedAStatus getLuts(
            int64_t display, const std::vector<composer3::Buffer>&,
            std::vector<composer3::Luts>* out_luts) override {
        if (!out_luts) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        if (display != 0) return displayError(HWC2_ERROR_BAD_DISPLAY, "getLuts");
        out_luts->clear();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus setPowerMode(int64_t display, composer3::PowerMode mode) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (display != 0 || !session_) return displayError(HWC2_ERROR_BAD_DISPLAY, "setPowerMode");
        const int error = exynos990_hwc2_session_set_power_mode(
                session_, static_cast<int32_t>(mode));
        return error == HWC2_ERROR_NONE ? ndk::ScopedAStatus::ok()
                                        : displayError(error, "setPowerMode");
    }

    ndk::ScopedAStatus setVsyncEnabled(int64_t display, bool enabled) override {
        std::lock_guard<std::mutex> lock(hwc_mutex_);
        if (display != 0 || !session_) {
            return displayError(HWC2_ERROR_BAD_DISPLAY, "setVsyncEnabled");
        }
        const int error = exynos990_hwc2_session_set_vsync_enabled(session_, enabled ? 1 : 0);
        return error == HWC2_ERROR_NONE ? ndk::ScopedAStatus::ok()
                                        : displayError(error, "setVsyncEnabled");
    }

  private:
    int ensureDisplayConfigCacheLocked() {
        if (!display_configs_.empty() && !display_config_cache_stale_.load()) return HWC2_ERROR_NONE;
        if (!session_) return HWC2_ERROR_NO_RESOURCES;

        uint32_t count = 0;
        int error = exynos990_hwc2_session_get_display_configs(session_, &count, nullptr);
        if (error != HWC2_ERROR_NONE) return error;
        if (count == 0 || count > 64) return HWC2_ERROR_NO_RESOURCES;
        std::vector<uint32_t> ids(count);
        error = exynos990_hwc2_session_get_display_configs(session_, &count, ids.data());
        if (error != HWC2_ERROR_NONE) return error;

        std::vector<DisplayConfigState> refreshed;
        refreshed.reserve(count);
        std::map<std::pair<int32_t, int32_t>, int32_t> fallback_groups;
        for (uint32_t id : ids) {
            if (std::any_of(refreshed.begin(), refreshed.end(),
                            [id](const DisplayConfigState& state) {
                                return state.id == static_cast<int32_t>(id);
                            })) return HWC2_ERROR_BAD_CONFIG;
            DisplayConfigState state;
            state.id = static_cast<int32_t>(id);
            const auto query = [&](int32_t attribute, int32_t* value) {
                return exynos990_hwc2_session_get_display_attribute(session_, id, attribute, value);
            };
            if (query(HWC2_ATTRIBUTE_WIDTH, &state.width) != HWC2_ERROR_NONE ||
                query(HWC2_ATTRIBUTE_HEIGHT, &state.height) != HWC2_ERROR_NONE ||
                query(HWC2_ATTRIBUTE_VSYNC_PERIOD, &state.vsync_period_ns) != HWC2_ERROR_NONE ||
                state.width <= 0 || state.height <= 0 || state.vsync_period_ns <= 0) {
                return HWC2_ERROR_BAD_CONFIG;
            }
            (void)query(HWC2_ATTRIBUTE_DPI_X, &state.dpi_x);
            (void)query(HWC2_ATTRIBUTE_DPI_Y, &state.dpi_y);
            if (query(HWC2_ATTRIBUTE_CONFIG_GROUP, &state.group) != HWC2_ERROR_NONE ||
                state.group < 0) {
                const auto geometry = std::make_pair(state.width, state.height);
                const auto [group, inserted] = fallback_groups.emplace(geometry, state.id);
                (void)inserted;
                state.group = group->second;
            }
            refreshed.push_back(state);
        }

        uint32_t active = 0;
        if (exynos990_hwc2_session_get_active_config(session_, &active) == HWC2_ERROR_NONE) {
            const auto active_it = std::find_if(refreshed.begin(), refreshed.end(),
                                                [active](const DisplayConfigState& state) {
                                                    return state.id == static_cast<int32_t>(active);
                                                });
            if (active_it != refreshed.end()) {
                active_config_id_ = active_it->id;
                vsync_period_ns_ = active_it->vsync_period_ns;
            }
        }
        display_configs_ = std::move(refreshed);
        display_config_cache_stale_.store(false);
        __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                            "Published %zu canonical HWC2 display configurations; active=%d",
                            display_configs_.size(), active_config_id_);
        return HWC2_ERROR_NONE;
    }

    const DisplayConfigState* findDisplayConfigLocked(uint32_t id) const {
        const auto it = std::find_if(display_configs_.begin(), display_configs_.end(),
                                     [id](const DisplayConfigState& state) {
                                         return state.id == static_cast<int32_t>(id);
                                     });
        return it == display_configs_.end() ? nullptr : &*it;
    }

    int applyDisplayConfigLocked(int32_t config) {
        const int cache_error = ensureDisplayConfigCacheLocked();
        if (cache_error != HWC2_ERROR_NONE) return cache_error;
        const DisplayConfigState* requested = findDisplayConfigLocked(static_cast<uint32_t>(config));
        if (!requested) return HWC2_ERROR_BAD_CONFIG;
        // The legacy entry point is the vendor's physical DDI-scaler and panel
        // transaction. The HWC2.4 constraints entry point alone changes only
        // logical geometry on this generation.
        const int error = exynos990_hwc2_session_set_active_config(
                session_, static_cast<uint32_t>(config));
        if (error != HWC2_ERROR_NONE) return error;
        synchronizePanelMode(session_, static_cast<uint32_t>(config));
        active_config_id_ = requested->id;
        vsync_period_ns_ = requested->vsync_period_ns;
        return HWC2_ERROR_NONE;
    }

    static composer3::CommandResultPayload commandError(size_t index, int32_t error) {
        composer3::CommandError result;
        result.commandIndex = static_cast<int32_t>(index);
        result.errorCode = error;
        return composer3::CommandResultPayload::make<composer3::CommandResultPayload::error>(
                std::move(result));
    }

    int applyDisplayCommand(const composer3::DisplayCommand& command) {
        for (const auto& layer : command.layers) {
            const int error = applyLayerCommand(layer);
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.clientTarget) {
            const auto& buffer = command.clientTarget->buffer;
            native_handle_t* handle = handleForBuffer(kClientTargetKey, buffer);
            if (!handle) return HWC2_ERROR_BAD_PARAMETER;
            const int fence = duplicateFence(buffer.fence);
            const int error = exynos990_hwc2_session_set_client_target(
                    session_, handle, fence, static_cast<int32_t>(command.clientTarget->dataspace),
                    nullptr, 0);
            if (error != HWC2_ERROR_NONE && fence >= 0) ::close(fence);
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.virtualDisplayOutputBuffer) return HWC2_ERROR_UNSUPPORTED;
        // The proprietary HWC2 implementation may retain region and matrix
        // pointers past the call.  Composer3 owns those vectors only for the
        // duration of this transaction, so omit these optional hints rather
        // than handing HWC2 dangling pointers.
        return HWC2_ERROR_NONE;
    }

    // Converts HWC2 getDisplayRequests() into a Composer3 DisplayRequest
    // payload.  Called with hwc_mutex_ held, right after a validate.
    int appendDisplayRequests(int64_t display,
                              std::vector<composer3::CommandResultPayload>* out_results) {
        int32_t display_mask = 0;
        uint32_t count = 0;
        int error = exynos990_hwc2_session_get_display_requests(session_, &display_mask, &count,
                                                                nullptr, nullptr);
        if (error != HWC2_ERROR_NONE) return error;
        std::vector<uint64_t> layers(count);
        std::vector<int32_t> masks(count);
        if (count) {
            error = exynos990_hwc2_session_get_display_requests(session_, &display_mask, &count,
                                                                layers.data(), masks.data());
            if (error != HWC2_ERROR_NONE) return error;
        }
        composer3::DisplayRequest request;
        request.display = display;
        request.mask = display_mask;
        request.layerRequests.reserve(count);
        for (uint32_t i = 0; i < count; ++i) {
            composer3::DisplayRequest::LayerRequest layer;
            layer.layer = static_cast<int64_t>(layers[i]);
            layer.mask = masks[i];
            request.layerRequests.push_back(layer);
        }
        out_results->push_back(composer3::CommandResultPayload::make<
                composer3::CommandResultPayload::displayRequest>(std::move(request)));
        return HWC2_ERROR_NONE;
    }

    int applyLayerCommand(const composer3::LayerCommand& command) {
        const uint64_t layer = static_cast<uint64_t>(command.layer);
        if (command.layer < 0) return HWC2_ERROR_BAD_LAYER;
        if (command.layerLifecycleBatchCommandType !=
            composer3::LayerLifecycleBatchCommandType::MODIFY) {
            /* HWC2 allocates the layer handle itself, while Composer3's batch
             * form has no return slot for that handle. Keep this path explicit
             * until a caller-side handle allocator is available. */
            return HWC2_ERROR_UNSUPPORTED;
        }
        if (command.bufferSlotsToClear) {
            for (const int32_t slot : *command.bufferSlotsToClear) {
                eraseHandle({layer, slot});
            }
        }
        int error = HWC2_ERROR_NONE;
        native_handle_t* command_handle = nullptr;
        int command_fence = -1;
        if (command.composition) {
            int32_t composition = static_cast<int32_t>(command.composition->composition);
            error = exynos990_hwc2_session_set_layer_composition(
                    session_, layer, composition);
            if (error != HWC2_ERROR_NONE) {
                return error;
            }
        }
        if (command.color) {
            error = exynos990_hwc2_session_set_layer_color(
                    session_, layer, command.color->r, command.color->g,
                    command.color->b, command.color->a);
            if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_UNSUPPORTED &&
                error != HWC2_ERROR_BAD_PARAMETER) return error;
        }
        if (command.dataspace) {
            int32_t dataspace = static_cast<int32_t>(command.dataspace->dataspace);
            const auto private_camera = private_camera_yuv_layers_.find(layer);
            const auto converted_camera = converted_camera_layers_.find(layer);
            if (private_camera != private_camera_yuv_layers_.end() && private_camera->second &&
                (converted_camera == converted_camera_layers_.end() || !converted_camera->second)) {
                // Keep the dataspace supplied by SurfaceFlinger.  The camera
                // producer/HWC2 pair owns the interpretation of private
                // format 0x11d; forcing HAL_DATASPACE_V0_JFIF here changes
                // the Exynos color-conversion path and can turn a valid
                // camera frame into a uniform green one.  We only log the
                // value so a later bridge-specific conversion can be added
                // from evidence, without guessing at the vendor enum.
                __android_log_print(ANDROID_LOG_DEBUG, "Composer3Bridge",
                                    "Preserving camera dataspace=0x%x for private 0x11d layer=%llu",
                                    dataspace, static_cast<unsigned long long>(layer));
            }
            error = exynos990_hwc2_session_set_layer_dataspace(
                    session_, layer, dataspace);
            if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_UNSUPPORTED &&
                error != HWC2_ERROR_BAD_PARAMETER) return error;
        }
        if (command.displayFrame) {
            const auto& frame = *command.displayFrame;
            error = exynos990_hwc2_session_set_layer_display_frame(
                    session_, layer, frame.left, frame.top, frame.right, frame.bottom);
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.sourceCrop) {
            const auto& crop = *command.sourceCrop;
            error = exynos990_hwc2_session_set_layer_source_crop(
                    session_, layer, crop.left, crop.top, crop.right, crop.bottom);
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.transform) {
            error = exynos990_hwc2_session_set_layer_transform(
                    session_, layer, static_cast<int32_t>(command.transform->transform));
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.blendMode) {
            error = exynos990_hwc2_session_set_layer_blend_mode(
                    session_, layer, static_cast<int32_t>(command.blendMode->blendMode));
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.planeAlpha) {
            error = exynos990_hwc2_session_set_layer_plane_alpha(
                    session_, layer, command.planeAlpha->alpha);
            if (error != HWC2_ERROR_NONE) return error;
        }
        if (command.z) {
            error = exynos990_hwc2_session_set_layer_z_order(
                    session_, layer, static_cast<uint32_t>(command.z->z));
            if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_UNSUPPORTED &&
                error != HWC2_ERROR_BAD_PARAMETER) return error;
        }
        if (command.sidebandStream && command.sidebandStream->fds.size() != 0) {
            return HWC2_ERROR_UNSUPPORTED;
        }
        // The stock HIDL composer completes the layer state before it calls
        // setLayerBuffer. Exynos HWC2 uses that state to classify private
        // camera format 0x11d and route it through MPP/G2D. Submitting the
        // buffer first through Composer3 made it look like an RGB allocation
        // and forced the bridge's CPU converter.
        if (command.buffer) {
            command_handle = handleForBuffer(layer, *command.buffer);
            if (!command_handle) return HWC2_ERROR_BAD_PARAMETER;
            command_fence = duplicateFence(command.buffer->fence);
            error = exynos990_hwc2_session_set_layer_buffer(
                    session_, layer, command_handle, command_fence);
            if (error != HWC2_ERROR_NONE && command_fence >= 0) ::close(command_fence);
            if (error != HWC2_ERROR_NONE) return error;
        }
        // HDR10 static (SMPTE 2086 / CTA 861.3) and HDR10+ (blob) metadata.
        // The keys and the blob layout are the HWC2 2.2/2.3 ones, which the
        // Composer3 enum mirrors.  Unsupported or rejected metadata never
        // fails the layer: composition must not depend on optional hints.
        if (command.perFrameMetadata) {
            std::vector<int32_t> keys;
            std::vector<float> values;
            for (const auto& item : *command.perFrameMetadata) {
                if (!item) continue;
                keys.push_back(static_cast<int32_t>(item->key));
                values.push_back(item->value);
            }
            if (!keys.empty()) {
                (void)exynos990_hwc2_session_set_layer_per_frame_metadata(
                        session_, layer, static_cast<uint32_t>(keys.size()), keys.data(),
                        values.data());
            }
        }
        if (command.perFrameMetadataBlob) {
            std::vector<int32_t> keys;
            std::vector<uint32_t> sizes;
            std::vector<uint8_t> blobs;
            for (const auto& item : *command.perFrameMetadataBlob) {
                if (!item) continue;
                keys.push_back(static_cast<int32_t>(item->key));
                sizes.push_back(static_cast<uint32_t>(item->blob.size()));
                blobs.insert(blobs.end(), item->blob.begin(), item->blob.end());
            }
            if (!keys.empty()) {
                (void)exynos990_hwc2_session_set_layer_per_frame_metadata_blobs(
                        session_, layer, static_cast<uint32_t>(keys.size()), keys.data(),
                        sizes.data(), blobs.data());
            }
        }
        // The Exynos HWC2 module has no entry points for the remaining optional
        // HWC3 brightness/LUT hints.  They are advisory; retaining the core
        // buffer and geometry state is sufficient for composition.
        return HWC2_ERROR_NONE;
    }

    void setBufferHandle(const HwcBufferKey& key, native_handle_t* replacement) {
        const auto it = buffer_handles_.find(key);
        if (it == buffer_handles_.end()) {
            buffer_handles_.emplace(key, replacement);
            return;
        }
        // The Samsung HWC2 implementation can consume a buffer handle
        // asynchronously during validate/present. Do not close the previous
        // handle immediately when a Composer3 slot is reused; keep a short
        // retirement queue instead.
        if (it->second != replacement) {
            if (!camera_pool_handles_.contains(it->second)) retireHandle(key, it->second);
            it->second = replacement;
        }
    }

    native_handle_t* convertCameraSource(uint64_t layer, const native_handle_t* source,
                                         const ndk::ScopedFileDescriptor& fence) {
        // executeCommands() owns hwc_mutex_.  Waiting here for a camera
        // producer fence blocks every unrelated SystemUI transaction behind
        // the preview.  Once a valid converted frame exists, preserve it when
        // the next producer frame is still in flight and retry on the next
        // Composer transaction.  This is normal buffer-queue backpressure,
        // not a raw-handle fallback: the current RGBA buffer remains stable
        // and the camera source slot/fence is refreshed on every command.
        const auto current = camera_layer_current_output_.find(layer);
        if (current != camera_layer_current_output_.end() && current->second) {
            const int64_t now = monotonicTimeNanos();
            const auto last = camera_layer_last_convert_ns_.find(layer);
            if (last != camera_layer_last_convert_ns_.end() &&
                now - last->second < cameraConvertIntervalNanos()) {
                return current->second;
            }
        }
        if (fence.get() >= 0 && !fenceSignaled(fence.get())) {
            if (current != camera_layer_current_output_.end() && current->second) {
                static std::atomic<uint32_t> skipped_camera_fences{0};
                const uint32_t skipped = ++skipped_camera_fences;
                if ((skipped & 0x3fU) == 1U) {
                    __android_log_print(ANDROID_LOG_DEBUG, "Composer3Bridge",
                                        "Camera frame still pending; retaining last RGB frame (%u skipped)",
                                        skipped);
                }
                return current->second;
            }
        }
        auto& output_pool = camera_output_pool_[layer];
        native_handle_t* reusable_output = acquireCameraOutput(layer);
        bool force_raw_fallback = false;
        if (!reusable_output && output_pool.size() >= kCameraOutputHardLimit) {
            __android_log_print(ANDROID_LOG_WARN, "Composer3Bridge",
                                "Camera output pool busy layer=%llu size=%zu",
                                static_cast<unsigned long long>(layer), output_pool.size());
            force_raw_fallback = true;
        }
        native_handle_t* converted = force_raw_fallback ? nullptr :
                camera_rgb_converter_.convert(source, duplicateFence(fence), reusable_output);
        if (!converted) return nullptr;
        converted_camera_layers_[layer] = true;
        converted_handles_.insert(converted);
        if (!reusable_output) {
            output_pool.push_back(converted);
            camera_pool_handles_.insert(converted);
        }
        camera_layer_current_output_[layer] = converted;
        camera_layer_last_convert_ns_[layer] = monotonicTimeNanos();
        return converted;
    }

    void replaceCameraSource(const HwcBufferKey& key, native_handle_t* source) {
        const auto old = camera_source_handles_.find(key);
        if (old != camera_source_handles_.end()) {
            importer_.releaseRaw(old->second);
            old->second = source;
        } else {
            camera_source_handles_.emplace(key, source);
        }
    }

    void releaseCameraSource(const HwcBufferKey& key) {
        const auto source = camera_source_handles_.find(key);
        if (source == camera_source_handles_.end()) return;
        importer_.releaseRaw(source->second);
        camera_source_handles_.erase(source);
    }

    void releaseCameraSources(uint64_t layer) {
        for (auto it = camera_source_handles_.begin(); it != camera_source_handles_.end();) {
            if (it->first.first == layer) {
                importer_.releaseRaw(it->second);
                it = camera_source_handles_.erase(it);
            } else {
                ++it;
            }
        }
    }

    native_handle_t* handleForBuffer(uint64_t layer, const composer3::Buffer& buffer) {
        const HwcBufferKey key{layer, buffer.slot};
        if (buffer.handle) {
            native_handle_t* replacement = importer_.import(*buffer.handle);
            if (!replacement) return nullptr;
            if (layer != kClientTargetKey) {
                const bool private_camera = importer_.isPrivateCameraYuv(replacement);
                private_camera_yuv_layers_[layer] = private_camera;
                if (private_camera) {
                    // The original y2s camera mapper does not pass its
                    // Stable-C imported handle to the Mali camera helpers.
                    // It receives the producer's native_handle, retains it
                    // through Gralloc1 and calls lock_flex_async(nullptr,
                    // handle, ...).  Keep Stable-C limited to format
                    // identification above, then reproduce that exact raw
                    // handle contract for the AIDL camera path.
                    native_handle_t* raw = importer_.cloneRaw(*buffer.handle);
                    if (!raw) {
                        importer_.release(replacement);
                        return nullptr;
                    }
                    importer_.release(replacement);

                    if (cameraMppPathEnabled()) {
                        // In MPP mode the stock HWC owns the private handle;
                        // do not lock, copy or allocate an RGBA companion.
                        // The layer state has already been submitted above,
                        // so its format and dataspace are available when
                        // setLayerBuffer() receives this raw handle.
                        releaseCameraSource(key);
                        replacement = raw;
                        converted_camera_layers_[layer] = false;
                        raw_handles_.insert(raw);
                        __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                                            "Camera MPP path: forwarding raw 0x11d handle");
                    } else {
                        // A Composer3 buffer slot transfers its native handle
                        // once. Later frames normally carry only that slot and a
                        // new acquire fence. Keep the retained stock handle per
                        // slot so every subsequent fence can be converted too.
                        native_handle_t* converted = convertCameraSource(layer, raw, buffer.fence);
                        if (converted) {
                            replaceCameraSource(key, raw);
                            replacement = converted;
                        } else {
                            // Keep ownership of the original handle if the
                            // source cannot be mapped. This fallback preserves
                            // the previous behavior for non-camera/private
                            // formats while making the failure explicit in logs.
                            releaseCameraSource(key);
                            replacement = raw;
                            converted_camera_layers_[layer] = false;
                            raw_handles_.insert(raw);
                            __android_log_print(ANDROID_LOG_WARN, "Composer3Bridge",
                                                "Camera RGB conversion unavailable; using raw handle");
                        }
                    }
                } else {
                    releaseCameraSource(key);
                    converted_camera_layers_[layer] = false;
                }
            }
            setBufferHandle(key, replacement);
        } else if (layer != kClientTargetKey) {
            // No handle does not mean no frame: SurfaceFlinger is reusing a
            // registered slot and supplies only a fresh acquire fence. The
            // previous bridge returned its old RGBA output here, producing a
            // short loop until Home forced a new SurfaceView and new slots.
            const auto source = camera_source_handles_.find(key);
            if (source != camera_source_handles_.end()) {
                native_handle_t* converted = convertCameraSource(
                        layer, source->second, buffer.fence);
                if (converted) setBufferHandle(key, converted);
            }
        }
        const auto it = buffer_handles_.find(key);
        return it == buffer_handles_.end() ? nullptr : it->second;
    }

    void eraseHandle(const HwcBufferKey& key) {
        releaseCameraSource(key);
        const auto it = buffer_handles_.find(key);
        if (it == buffer_handles_.end()) return;
        // A buffer-slot clear is not a lifetime guarantee for the proprietary
        // Exynos HWC2 implementation. It can still dereference the old
        // private handle from its asynchronous preprocessing worker after the
        // Composer3 transaction has completed. Retire it together with the
        // other replaced handles and release it only after session_close().
        retireHandle(key, it->second);
        buffer_handles_.erase(it);
    }

    void retireHandle(const HwcBufferKey& key, native_handle_t* handle) {
        if (!handle) return;
        auto& retired = retired_handles_[key];
        retired.push_back(handle);
        while (retired.size() > kRetiredHandleLimit) {
            releaseHandle(retired.front());
            retired.pop_front();
        }
    }

    void releaseOwnedCameraHandle(native_handle_t* handle) {
        if (!handle) return;
        const auto fence = camera_output_release_fences_.find(handle);
        if (fence != camera_output_release_fences_.end()) {
            if (fence->second >= 0) ::close(fence->second);
            camera_output_release_fences_.erase(fence);
        }
        camera_pool_handles_.erase(handle);
        converted_handles_.erase(handle);
        camera_rgb_converter_.release(handle);
    }

    void releaseOwnedCameraHandles(uint64_t layer) {
        const auto pool = camera_output_pool_.find(layer);
        if (pool == camera_output_pool_.end()) {
            camera_layer_last_convert_ns_.erase(layer);
            return;
        }
        for (native_handle_t* handle : pool->second) releaseOwnedCameraHandle(handle);
        camera_output_pool_.erase(pool);
        camera_output_cursor_.erase(layer);
        camera_layer_current_output_.erase(layer);
        camera_layer_last_convert_ns_.erase(layer);
    }

    static bool fenceSignaled(int fd) {
        if (fd < 0) return true;
        pollfd descriptor{fd, POLLIN, 0};
        int status = 0;
        do {
            status = ::poll(&descriptor, 1, 0);
        } while (status < 0 && errno == EINTR);
        return status == 1 && (descriptor.revents & (POLLIN | POLLERR | POLLHUP));
    }

    native_handle_t* acquireCameraOutput(uint64_t layer) {
        const auto pool = camera_output_pool_.find(layer);
        if (pool == camera_output_pool_.end() || pool->second.empty()) return nullptr;
        auto& cursor = camera_output_cursor_[layer];
        for (size_t attempt = 0; attempt < pool->second.size(); ++attempt) {
            native_handle_t* candidate = pool->second[(cursor + attempt) % pool->second.size()];
            const auto fence = camera_output_release_fences_.find(candidate);
            if (fence == camera_output_release_fences_.end()) {
                cursor = (cursor + attempt + 1) % pool->second.size();
                return candidate;
            }
            if (!fenceSignaled(fence->second)) continue;
            ::close(fence->second);
            camera_output_release_fences_.erase(fence);
            cursor = (cursor + attempt + 1) % pool->second.size();
            return candidate;
        }
        return nullptr;
    }

    void rememberCameraReleaseFence(uint64_t layer, int fd) {
        const auto current = camera_layer_current_output_.find(layer);
        if (current == camera_layer_current_output_.end() || !current->second || fd < 0) return;
        const auto old = camera_output_release_fences_.find(current->second);
        if (old != camera_output_release_fences_.end()) {
            if (old->second >= 0) ::close(old->second);
            camera_output_release_fences_.erase(old);
        }
        const int duplicate = ::dup(fd);
        if (duplicate >= 0) camera_output_release_fences_[current->second] = duplicate;
    }

    void releaseHandle(native_handle_t* handle) {
        if (!handle) return;
        if (camera_pool_handles_.contains(handle)) return;
        const auto raw = raw_handles_.find(handle);
        if (raw != raw_handles_.end()) {
            raw_handles_.erase(raw);
            importer_.releaseRaw(handle);
            return;
        }
        const auto converted = converted_handles_.find(handle);
        if (converted != converted_handles_.end()) {
            converted_handles_.erase(converted);
            camera_rgb_converter_.release(handle);
            return;
        }
        importer_.release(handle);
    }

    static void onHotplug(void* context, uint64_t display, int32_t connected) {
        auto* self = static_cast<Hwc2ComposerClient*>(context);
        if (self) self->display_config_cache_stale_.store(true);
        if (!self || !self->callback_) return;
        const auto event = connected == HWC2_CONNECTION_CONNECTED
                ? graphics_common::DisplayHotplugEvent::CONNECTED
                : graphics_common::DisplayHotplugEvent::DISCONNECTED;
        (void)self->callback_->onHotplugEvent(static_cast<int64_t>(display), event);
    }

    static void onRefresh(void* context, uint64_t display) {
        auto* self = static_cast<Hwc2ComposerClient*>(context);
        if (self && self->callback_) (void)self->callback_->onRefresh(static_cast<int64_t>(display));
    }

    static void onVsync(void* context, uint64_t display, int64_t timestamp,
                       int64_t vsync_period_nanos) {
        auto* self = static_cast<Hwc2ComposerClient*>(context);
        if (!self || !self->callback_) return;
        int32_t period = static_cast<int32_t>(vsync_period_nanos);
        if (period <= 0) period = self->vsync_period_ns_;
        if (period <= 0) period = 16666666;
        self->vsync_period_ns_ = period;
        (void)self->callback_->onVsync(static_cast<int64_t>(display), timestamp, period);
    }

    static void onVsyncPeriodTimingChanged(void* context, uint64_t display,
                                           int64_t applied, int64_t refresh,
                                           int64_t refresh_required) {
        auto* self = static_cast<Hwc2ComposerClient*>(context);
        if (!self || !self->callback_) return;
        composer3::VsyncPeriodChangeTimeline timeline;
        timeline.newVsyncAppliedTimeNanos = applied;
        timeline.refreshTimeNanos = refresh;
        timeline.refreshRequired = refresh_required != 0;
        (void)self->callback_->onVsyncPeriodTimingChanged(static_cast<int64_t>(display), timeline);
    }

    static void onSeamlessPossible(void* context, uint64_t display) {
        auto* self = static_cast<Hwc2ComposerClient*>(context);
        if (self && self->callback_) {
            (void)self->callback_->onSeamlessPossible(static_cast<int64_t>(display));
        }
    }

    static ndk::ScopedAStatus serviceError(int32_t code, const char* message) {
        return ndk::ScopedAStatus::fromServiceSpecificErrorWithMessage(code, message);
    }

    static ndk::ScopedAStatus unsupported(const char* message) {
        return serviceError(composer3::IComposerClient::EX_UNSUPPORTED, message);
    }

    static ndk::ScopedAStatus displayError(int error, const char* message) {
        if (error == HWC2_ERROR_BAD_DISPLAY) {
            return serviceError(composer3::IComposerClient::EX_BAD_DISPLAY, message);
        }
        if (error == HWC2_ERROR_BAD_CONFIG) {
            return serviceError(composer3::IComposerClient::EX_BAD_CONFIG, message);
        }
        return serviceError(composer3::IComposerClient::EX_UNSUPPORTED, message);
    }

    exynos990_hwc2_session* session_ = nullptr;
    std::mutex hwc_mutex_;
    std::shared_ptr<composer3::IComposerCallback> callback_;
    std::map<HwcBufferKey, native_handle_t*> buffer_handles_;
    std::map<HwcBufferKey, std::deque<native_handle_t*>> retired_handles_;
    std::map<HwcBufferKey, native_handle_t*> camera_source_handles_;
    std::map<uint64_t, std::deque<native_handle_t*>> camera_output_pool_;
    std::map<uint64_t, size_t> camera_output_cursor_;
    std::map<uint64_t, native_handle_t*> camera_layer_current_output_;
    std::map<uint64_t, int64_t> camera_layer_last_convert_ns_;
    std::map<native_handle_t*, int> camera_output_release_fences_;
    std::set<native_handle_t*> camera_pool_handles_;
    std::set<native_handle_t*> raw_handles_;
    std::set<native_handle_t*> converted_handles_;
    std::map<uint64_t, bool> private_camera_yuv_layers_;
    std::map<uint64_t, bool> converted_camera_layers_;
    StableMapperImporter importer_;
    CameraRgbConverter camera_rgb_converter_;
    std::vector<DisplayConfigState> display_configs_;
    std::atomic_bool display_config_cache_stale_{true};
    int32_t active_config_id_ = -1;
    int32_t vsync_period_ns_ = 0;
    bool validate_pending_accept_ = false;
};

class Hwc2Composer final : public composer3::BnComposer {
  public:
    ndk::ScopedAStatus createClient(
            std::shared_ptr<composer3::IComposerClient>* out_client) override {
        if (!out_client) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        *out_client = ndk::SharedRefBase::make<Hwc2ComposerClient>();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getCapabilities(std::vector<composer3::Capability>* out_capabilities)
            override {
        if (!out_capabilities) return ndk::ScopedAStatus::fromExceptionCode(EX_NULL_POINTER);
        // The Exynos 990 HWC2 returns valid sync_file descriptors, but their
        // signal timestamps are not reliable enough for modern SurfaceFlinger
        // frame pacing. This is the corresponding HWC2/AIDL capability.
        out_capabilities->assign(1, composer3::Capability::PRESENT_FENCE_IS_NOT_RELIABLE);
        return ndk::ScopedAStatus::ok();
    }
};

}  // namespace

extern "C" __attribute__((visibility("default"))) int exynos990_composer3_contract_probe(
        int32_t* composer_version, int32_t* client_version) {
    if (!composer_version || !client_version) return EX_NULL_POINTER;

    auto composer = ndk::SharedRefBase::make<Hwc2Composer>();
    auto status = composer->getInterfaceVersion(composer_version);
    if (!status.isOk()) return status.getStatus();

    std::shared_ptr<composer3::IComposerClient> client;
    status = composer->createClient(&client);
    if (!status.isOk() || !client) return status.isOk() ? STATUS_UNKNOWN_ERROR : status.getStatus();

    status = client->getInterfaceVersion(client_version);
    return status.isOk() ? STATUS_OK : status.getStatus();
}

// The installable service keeps this shared object as its implementation
// library. Keep the service object alive for the lifetime of servicemanager;
// the returned raw binder pointer is retained by the static shared_ptr.
extern "C" __attribute__((visibility("default"))) AIBinder*
exynos990_composer3_service_binder() {
    static auto service = ndk::SharedRefBase::make<Hwc2Composer>();
    // BnCInterface::asBinder() returns an SpAIBinder temporary.  Returning
    // only its raw pointer drops the temporary's strong reference as soon as
    // this function returns; servicemanager then dereferences a dead binder
    // while flattening the addService transaction.  Keep a process-lifetime
    // strong reference alongside the implementation object.
    static ndk::SpAIBinder binder;
    if (binder.get() == nullptr) binder = service->asBinder();
    return binder.get();
}
