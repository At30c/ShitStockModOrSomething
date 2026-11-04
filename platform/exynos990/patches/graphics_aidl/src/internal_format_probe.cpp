#include "exynos990/graphics_backend.h"

#include <hardware/hardware.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

#include "exynos990/graphics_contract.h"

namespace {

template <typename T>
T load(gralloc1_device_t* device, gralloc1_function_descriptor_t descriptor) {
    return reinterpret_cast<T>(device->getFunction(device, descriptor));
}

bool probe(const exynos990_gralloc_backend_t* backend, gralloc1_device_t* device,
           int32_t format, uint64_t producerUsage, uint64_t consumerUsage,
           const char* name) {
    auto create = load<GRALLOC1_PFN_CREATE_DESCRIPTOR>(device,
                                                       GRALLOC1_FUNCTION_CREATE_DESCRIPTOR);
    auto destroy = load<GRALLOC1_PFN_DESTROY_DESCRIPTOR>(device,
                                                         GRALLOC1_FUNCTION_DESTROY_DESCRIPTOR);
    auto setDimensions = load<GRALLOC1_PFN_SET_DIMENSIONS>(device,
                                                           GRALLOC1_FUNCTION_SET_DIMENSIONS);
    auto setFormat = load<GRALLOC1_PFN_SET_FORMAT>(device, GRALLOC1_FUNCTION_SET_FORMAT);
    auto setLayers = load<GRALLOC1_PFN_SET_LAYER_COUNT>(device,
                                                        GRALLOC1_FUNCTION_SET_LAYER_COUNT);
    auto setProducer = load<GRALLOC1_PFN_SET_PRODUCER_USAGE>(
            device, GRALLOC1_FUNCTION_SET_PRODUCER_USAGE);
    auto setConsumer = load<GRALLOC1_PFN_SET_CONSUMER_USAGE>(
            device, GRALLOC1_FUNCTION_SET_CONSUMER_USAGE);
    auto allocate = load<GRALLOC1_PFN_ALLOCATE>(device, GRALLOC1_FUNCTION_ALLOCATE);
    auto release = load<GRALLOC1_PFN_RELEASE>(device, GRALLOC1_FUNCTION_RELEASE);
    if (!create || !destroy || !setDimensions || !setFormat || !setLayers || !setProducer ||
        !setConsumer || !allocate || !release || !backend->getFrameworkFormat) {
        std::printf("%s unavailable\n", name);
        return false;
    }

    gralloc1_buffer_descriptor_t descriptor = 0;
    if (create(device, &descriptor) != GRALLOC1_ERROR_NONE ||
        setDimensions(device, descriptor, 1920, 1080) != GRALLOC1_ERROR_NONE ||
        setFormat(device, descriptor, format) != GRALLOC1_ERROR_NONE ||
        setLayers(device, descriptor, 1) != GRALLOC1_ERROR_NONE ||
        setProducer(device, descriptor, producerUsage) != GRALLOC1_ERROR_NONE ||
        setConsumer(device, descriptor, consumerUsage) != GRALLOC1_ERROR_NONE) {
        destroy(device, descriptor);
        std::printf("%s descriptor failed\n", name);
        return false;
    }

    buffer_handle_t buffer = nullptr;
    const int32_t result = allocate(device, 1, &descriptor, &buffer);
    destroy(device, descriptor);
    if (result != GRALLOC1_ERROR_NONE || !buffer) {
        std::printf("%s allocate failed=%d\n", name, result);
        return false;
    }

    int packed = 0;
    const int32_t formatResult = backend->getFrameworkFormat(buffer, &packed);
    const auto* raw = reinterpret_cast<const uint8_t*>(buffer);
    uint32_t framework = 0, internalLow = 0, internalHigh = 0;
    uint32_t allocationLow = 0, allocationHigh = 0;
    std::memcpy(&framework, raw + exynos990::graphics::PrivateHandleLayout::kFrameworkFormat,
                sizeof(framework));
    std::memcpy(&internalLow, raw + exynos990::graphics::PrivateHandleLayout::kInternalFormat,
                sizeof(internalLow));
    std::memcpy(&internalHigh, raw + exynos990::graphics::PrivateHandleLayout::kInternalFormat +
                        sizeof(internalLow), sizeof(internalHigh));
    std::memcpy(&allocationLow,
                raw + exynos990::graphics::PrivateHandleLayout::kAllocationFormat,
                sizeof(allocationLow));
    std::memcpy(&allocationHigh,
                raw + exynos990::graphics::PrivateHandleLayout::kAllocationFormat +
                        sizeof(allocationLow), sizeof(allocationHigh));
    std::printf("%s requested=0x%x accessor_framework=0x%08x fields{framework=0x%08x "
                "internal=0x%08x%08x alloc=0x%08x%08x} result=%d fds=%d ints=%d\n",
                name, format, static_cast<unsigned int>(packed), framework,
                internalHigh, internalLow, allocationHigh, allocationLow, formatResult,
                buffer->numFds, buffer->numInts);
    for (int index = 0; index < buffer->numInts; ++index) {
        const uintptr_t offset = reinterpret_cast<uintptr_t>(&buffer->data[buffer->numFds + index]) -
                reinterpret_cast<uintptr_t>(buffer);
        if (offset >= 0x20 && offset <= 0x90) {
            std::printf("  %s int[%d] offset=0x%zx value=0x%08x\n", name, index, offset,
                        static_cast<unsigned int>(buffer->data[buffer->numFds + index]));
        }
    }
    int32_t gralloc1Format = 0;
    uint32_t stride = 0;
    backend->getFormat(device, buffer, &gralloc1Format);
    backend->getStride(device, buffer, &stride);
    std::printf("%s getFormat=0x%x stride=%u\n", name, gralloc1Format, stride);
    // O mapper precisa saber qual LOCK_FLEX descreve cada alocação: o
    // callback Gralloc1 ou o helper exportado usado pela câmera.
    auto dumpFlex = [&](const char* path, bool camera) {
        uint32_t count = 0;
        const int countError = camera
                ? backend->cameraGetNumFlexPlanes(nullptr, buffer, &count)
                : backend->getNumFlexPlanes(device, buffer, &count);
        if (countError != GRALLOC1_ERROR_NONE || count == 0 || count > 8) {
            std::printf("%s %s numFlexPlanes error=%d count=%u\n", name, path, countError, count);
            return;
        }
        android_flex_plane_t planes[8] = {};
        android_flex_layout_t layout{FLEX_FORMAT_INVALID, count, planes};
        int lockError;
        if (camera) {
            lockError = backend->cameraLockFlexAsync(nullptr, buffer, 0x33, 0, 0, 1920, 1080,
                                                     &layout, -1);
        } else {
            gralloc1_rect_t region{0, 0, 1920, 1080};
            lockError = backend->lockFlex(device, buffer, GRALLOC1_PRODUCER_USAGE_CPU_WRITE_OFTEN,
                                          0, &region, &layout, -1);
        }
        std::printf("%s %s lockFlex error=%d format=%d planes=%u\n", name, path, lockError,
                    layout.format, layout.num_planes);
        if (lockError != GRALLOC1_ERROR_NONE) return;
        for (uint32_t index = 0; index < layout.num_planes; ++index) {
            const android_flex_plane_t& plane = layout.planes[index];
            std::printf("  %s %s plane%u component=%d ptr=%p bits=%d/%d inc=%d/%d sub=%d/%d\n",
                        name, path, index, plane.component, plane.top_left,
                        plane.bits_per_component, plane.bits_used, plane.h_increment,
                        plane.v_increment, plane.h_subsampling, plane.v_subsampling);
        }
        if (camera) {
            backend->cameraUnlock(nullptr, buffer);
        } else {
            int fence = -1;
            backend->unlock(device, buffer, &fence);
        }
    };
    dumpFlex("gralloc1", false);
    if (backend->cameraReady) dumpFlex("camera", true);
    release(device, buffer);
    return formatResult == GRALLOC1_ERROR_NONE;
}

}  // namespace

int main(int argc, char** argv) {
    const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
    if (!backend || !backend->device || !backend->ready) {
        std::printf("backend unavailable\n");
        return 1;
    }
    gralloc1_device_t* device = backend->device;
    // internal_format_probe <format> <aidl-usage>: reproduz uma alocação vista
    // em log (por exemplo o ImageReader 0x22/0x20933 do Motion Photo) com a
    // mesma tradução de usage do allocator AIDL.
    if (argc == 3) {
        const auto format = static_cast<int32_t>(std::strtol(argv[1], nullptr, 0));
        const uint64_t usage = std::strtoull(argv[2], nullptr, 0);
        return probe(backend, device, format, exynos990::graphics::toProducerUsage(usage),
                     exynos990::graphics::toConsumerUsage(usage), "custom")
                ? 0 : 1;
    }
    const hw_module_t* module = nullptr;
    using SelectFormat = uint64_t (*)(uint64_t, int, uint64_t, int, uint64_t*);
    SelectFormat selectFormat = nullptr;
    if (hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &module) == 0 && module && module->dso) {
        selectFormat = reinterpret_cast<SelectFormat>(
                dlsym(module->dso,
                      "_Z26mali_gralloc_select_formatm24mali_gralloc_format_typemiPm"));
    }
    if (selectFormat) {
        const uint64_t usage = static_cast<uint64_t>(GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET) |
                static_cast<uint64_t>(GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE) |
                static_cast<uint64_t>(GRALLOC1_CONSUMER_USAGE_HWCOMPOSER);
        uint64_t selectedOut = 0;
        const uint64_t selectedReturn = selectFormat(
                HAL_PIXEL_FORMAT_RGBA_8888, 0, usage, 1920 * 1080 * 4, &selectedOut);
        std::printf("selected-rgba-gpu internal=0x%016llx out=0x%016llx\n",
                    static_cast<unsigned long long>(selectedReturn),
                    static_cast<unsigned long long>(selectedOut));
    } else {
        std::printf("mali_gralloc_select_format unavailable\n");
    }
    bool ok = true;
    ok &= probe(backend, device, HAL_PIXEL_FORMAT_RGBA_8888,
                GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET,
                GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE | GRALLOC1_CONSUMER_USAGE_HWCOMPOSER,
                "rgba-gpu");
    ok &= probe(backend, device, HAL_PIXEL_FORMAT_RGBA_8888,
                GRALLOC1_PRODUCER_USAGE_CPU_WRITE,
                GRALLOC1_CONSUMER_USAGE_CPU_READ,
                "rgba-linear");
    // Legacy Gralloc0.3 wrapper values used by the same y2s binary: these
    // requests let us observe whether the allocator preserves AFBC bits in
    // the native handle instead of assuming that select_format() alone is
    // sufficient proof.
    ok &= probe(backend, device, 0x00010001,
                GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET,
                GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE | GRALLOC1_CONSUMER_USAGE_HWCOMPOSER,
                "rgba-afbc-basic");
    ok &= probe(backend, device, 0x01010001,
                GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET,
                GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE | GRALLOC1_CONSUMER_USAGE_HWCOMPOSER,
                "rgba-afbc-tiled");
    ok &= probe(backend, device, HAL_PIXEL_FORMAT_YCBCR_420_888,
                GRALLOC1_PRODUCER_USAGE_CAMERA,
                GRALLOC1_CONSUMER_USAGE_CAMERA,
                "camera-yuv");
    return ok ? 0 : 1;
}
