#pragma once

#include <hardware/gralloc1.h>

#include <cstddef>
#include <cstdint>

// Contrato recuperado do gralloc.exynos990.so do y2s. Estes valores não são
// offsets do SGR do S26+: são os campos que o próprio mali_gralloc_lock_* do
// Exynos 990 lê no private_handle_t do vendor.
namespace exynos990::graphics {

constexpr uint64_t kAidlCpuReadMask = 0x0fULL;
constexpr uint64_t kAidlCpuWriteMask = 0xf0ULL;
constexpr uint64_t kAidlGpuTexture = 1ULL << 8;
constexpr uint64_t kAidlGpuRenderTarget = 1ULL << 9;
constexpr uint64_t kAidlComposerOverlay = 1ULL << 11;
constexpr uint64_t kAidlComposerClientTarget = 1ULL << 12;
constexpr uint64_t kAidlProtected = 1ULL << 14;
constexpr uint64_t kAidlComposerCursor = 1ULL << 15;
constexpr uint64_t kAidlVideoEncoder = 1ULL << 16;
constexpr uint64_t kAidlCameraOutput = 1ULL << 17;
constexpr uint64_t kAidlCameraInput = 1ULL << 18;
constexpr uint64_t kAidlRenderscript = 1ULL << 20;
constexpr uint64_t kAidlVideoDecoder = 1ULL << 22;
constexpr uint64_t kAidlSensorDirectData = 1ULL << 23;
constexpr uint64_t kAidlGpuDataBuffer = 1ULL << 24;
// These AIDL usage bits have no lossless equivalent in the Exynos 990
// Gralloc1 descriptor. Do not silently discard them when the allocator is
// exposed globally; isSupported() must report false instead.
constexpr uint64_t kAidlGpuCubeMap = 1ULL << 25;
constexpr uint64_t kAidlGpuMipmapComplete = 1ULL << 26;
constexpr uint64_t kAidlHwImageEncoder = 1ULL << 27;
constexpr uint64_t kAidlFrontBuffer = 1ULL << 32;
constexpr uint64_t kAidlVendorMask = (0xfULL << 28) | (0xffffULL << 48);
constexpr uint64_t kAidlUnsupportedUsageMask = kAidlGpuCubeMap |
        kAidlGpuMipmapComplete | kAidlHwImageEncoder | kAidlFrontBuffer;

static_assert(kAidlCameraOutput == GRALLOC1_PRODUCER_USAGE_CAMERA,
              "AIDL CAMERA_OUTPUT must match Gralloc1 CAMERA");
static_assert(kAidlCameraInput == GRALLOC1_CONSUMER_USAGE_CAMERA,
              "AIDL CAMERA_INPUT must match Gralloc1 CAMERA");

struct PrivateHandleLayout {
    // The y2s handle carries three distinct format-related fields. Do not
    // collapse them into one "format" offset: different vendor entrypoints
    // read different fields from the same private handle.
    static constexpr size_t kFrameworkFormat = 0x30;
    static constexpr size_t kInternalFormat = 0x48;
    static constexpr size_t kAllocationFormat = 0x50;
    // Source-compatibility alias for existing plane-layout code. This is the
    // allocation format, not the internal-format field at +0x48.
    static constexpr size_t kFormat = kAllocationFormat;
    static constexpr size_t kYStride = 0x5c;
    static constexpr size_t kChromaOffset = 0x68;
    static constexpr size_t kChromaStride = 0x6c;
    static constexpr size_t kSecondChromaOffset = 0x78;
};

constexpr uint32_t kExynosNv12 = 0x200;
constexpr uint32_t kExynosNv21 = 0x201;
constexpr uint32_t kYv12 = 0x32315659;
// Vendor camera preview/output format observed in the original y2s
// gralloc1 handle.  It is a semiplanar YUV allocation backed by separate
// DMA-BUFs; it is not a public Android pixel format and must never be
// interpreted with the S26+ SGR handle layout.
constexpr int32_t kExynosCameraYuv = 0x11d;
// Samsung Camera's Motion Photo/filters side channel allocates this related
// private NV21 buffer.  The stock Mali driver explicitly requires its
// GRALLOC1_FUNCTION_LOCK_FLEX path as well; treating it as a generic linear
// format makes callers receive an invalid CPU address.
constexpr int32_t kExynosCameraMotionYuv = 0x11e;

constexpr inline bool isExynosPrivateCameraYuv(int32_t format) {
    return format == kExynosCameraYuv || format == kExynosCameraMotionYuv;
}

constexpr inline uint64_t toProducerUsage(uint64_t usage) {
    uint64_t result = usage & kAidlVendorMask;
    switch (usage & kAidlCpuWriteMask) {
        case 0x20: result |= GRALLOC1_PRODUCER_USAGE_CPU_WRITE; break;
        case 0x30: result |= GRALLOC1_PRODUCER_USAGE_CPU_WRITE_OFTEN; break;
    }
    switch (usage & kAidlCpuReadMask) {
        case 0x02: result |= GRALLOC1_PRODUCER_USAGE_CPU_READ; break;
        case 0x03: result |= GRALLOC1_PRODUCER_USAGE_CPU_READ_OFTEN; break;
    }
    result |= usage & (kAidlGpuRenderTarget | kAidlProtected | kAidlCameraOutput |
                       kAidlVideoDecoder | kAidlSensorDirectData);
    return result;
}

constexpr inline uint64_t toConsumerUsage(uint64_t usage) {
    uint64_t result = usage & kAidlVendorMask;
    switch (usage & kAidlCpuReadMask) {
        case 0x02: result |= GRALLOC1_CONSUMER_USAGE_CPU_READ; break;
        case 0x03: result |= GRALLOC1_CONSUMER_USAGE_CPU_READ_OFTEN; break;
    }
    result |= usage & (kAidlGpuTexture | kAidlComposerOverlay |
                       kAidlComposerClientTarget | kAidlComposerCursor |
                       kAidlVideoEncoder | kAidlCameraInput | kAidlRenderscript);
    if (usage & kAidlGpuDataBuffer) result |= GRALLOC1_CONSUMER_USAGE_GPU_DATA_BUFFER;
    return result;
}

constexpr inline uint64_t toAidlUsage(uint64_t producer, uint64_t consumer) {
    // Bit 23 has different meanings in the two Gralloc1 domains. Preserve the
    // domains until after that ambiguity has been resolved.
    uint64_t usage = (producer | consumer) & kAidlVendorMask;
    const uint64_t cpuRead = producer | consumer;
    if (cpuRead & GRALLOC1_CONSUMER_USAGE_CPU_READ_OFTEN) {
        usage |= 0x03ULL;
    } else if (cpuRead & GRALLOC1_CONSUMER_USAGE_CPU_READ) {
        usage |= 0x02ULL;
    }
    if (producer & GRALLOC1_PRODUCER_USAGE_CPU_WRITE_OFTEN) {
        usage |= 0x30ULL;
    } else if (producer & GRALLOC1_PRODUCER_USAGE_CPU_WRITE) {
        usage |= 0x20ULL;
    }
    usage |= producer & (GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET |
                         GRALLOC1_PRODUCER_USAGE_PROTECTED |
                         GRALLOC1_PRODUCER_USAGE_VIDEO_DECODER |
                         GRALLOC1_PRODUCER_USAGE_SENSOR_DIRECT_DATA);
    usage |= consumer & (GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE |
                         GRALLOC1_CONSUMER_USAGE_HWCOMPOSER |
                         GRALLOC1_CONSUMER_USAGE_CLIENT_TARGET |
                         GRALLOC1_CONSUMER_USAGE_CURSOR |
                         GRALLOC1_CONSUMER_USAGE_VIDEO_ENCODER |
                         GRALLOC1_CONSUMER_USAGE_RENDERSCRIPT);
    if (producer & GRALLOC1_PRODUCER_USAGE_CAMERA) usage |= kAidlCameraOutput;
    if (consumer & GRALLOC1_CONSUMER_USAGE_CAMERA) usage |= kAidlCameraInput;
    if (consumer & GRALLOC1_CONSUMER_USAGE_GPU_DATA_BUFFER) usage |= kAidlGpuDataBuffer;
    return usage;
}

static_assert((toProducerUsage(kAidlCameraOutput | kAidlCameraInput) &
               GRALLOC1_PRODUCER_USAGE_CAMERA) != 0,
              "CAMERA_OUTPUT must reach the producer callback");
static_assert((toProducerUsage(kAidlCameraOutput | kAidlCameraInput) &
               GRALLOC1_CONSUMER_USAGE_CAMERA) == 0,
              "CAMERA_INPUT must not leak into the producer callback");
static_assert((toConsumerUsage(kAidlCameraOutput | kAidlCameraInput) &
               GRALLOC1_CONSUMER_USAGE_CAMERA) != 0,
              "CAMERA_INPUT must reach the consumer callback");
static_assert((toConsumerUsage(kAidlCameraOutput | kAidlCameraInput) &
               GRALLOC1_PRODUCER_USAGE_CAMERA) == 0,
              "CAMERA_OUTPUT must not leak into the consumer callback");

}  // namespace exynos990::graphics
