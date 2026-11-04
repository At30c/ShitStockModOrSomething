#include "exynos990/graphics_backend.h"

#include <android/hardware/graphics/mapper/IMapper.h>
#include <hardware/hardware.h>

#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <vector>

namespace {

bool readModifier(AIMapper* mapper, buffer_handle_t buffer, uint64_t* modifier) {
    constexpr int64_t kModifierType = 8;
    const int32_t required = mapper->v5.getStandardMetadata(buffer, kModifierType, nullptr, 0);
    if (required <= 0) return false;
    std::vector<unsigned char> encoded(static_cast<size_t>(required));
    if (mapper->v5.getStandardMetadata(buffer, kModifierType, encoded.data(), encoded.size()) !=
        required) return false;

    size_t offset = 0;
    auto read = [&](void* output, size_t size) {
        if (offset > encoded.size() || size > encoded.size() - offset) return false;
        std::memcpy(output, encoded.data() + offset, size);
        offset += size;
        return true;
    };
    int64_t nameLength = 0, type = 0;
    if (!read(&nameLength, sizeof(nameLength)) || nameLength < 0 ||
        static_cast<uint64_t>(nameLength) > encoded.size() - offset) return false;
    offset += static_cast<size_t>(nameLength);
    if (!read(&type, sizeof(type)) || type != kModifierType || !read(modifier, sizeof(*modifier)))
        return false;
    return offset == encoded.size();
}

template <typename T>
T get(gralloc1_device_t* device, gralloc1_function_descriptor_t descriptor) {
    return reinterpret_cast<T>(device->getFunction(device, descriptor));
}

}  // namespace

int main(int argc, char** argv) {
    const exynos990_gralloc_backend_t* backend = exynos990_gralloc_backend();
    if (!backend || !backend->device || !backend->ready) {
        std::fprintf(stderr, "FAIL backend unavailable\n");
        return 1;
    }
    const hw_module_t* module = nullptr;
    if (hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &module) != 0 || !module || !module->dso) {
        std::fprintf(stderr, "FAIL stock gralloc unavailable\n");
        return 1;
    }
    const char* mapperPath = argc > 1 ? argv[1] : "/vendor/lib64/hw/mapper.exynos990_compat.so";
    void* library = dlopen(mapperPath, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        std::fprintf(stderr, "FAIL mapper dlopen: %s\n", dlerror());
        return 1;
    }
    auto loadMapper = reinterpret_cast<AIMapper_Error (*)(AIMapper**)>(
            dlsym(library, "AIMapper_loadIMapper"));
    AIMapper* mapper = nullptr;
    if (!loadMapper || loadMapper(&mapper) != AIMAPPER_ERROR_NONE || !mapper ||
        mapper->version != AIMAPPER_VERSION_5) {
        std::fprintf(stderr, "FAIL Stable-C mapper load\n");
        return 1;
    }

    auto create = get<GRALLOC1_PFN_CREATE_DESCRIPTOR>(
            backend->device, GRALLOC1_FUNCTION_CREATE_DESCRIPTOR);
    auto destroy = get<GRALLOC1_PFN_DESTROY_DESCRIPTOR>(
            backend->device, GRALLOC1_FUNCTION_DESTROY_DESCRIPTOR);
    auto setDimensions = get<GRALLOC1_PFN_SET_DIMENSIONS>(
            backend->device, GRALLOC1_FUNCTION_SET_DIMENSIONS);
    auto setFormat = get<GRALLOC1_PFN_SET_FORMAT>(backend->device, GRALLOC1_FUNCTION_SET_FORMAT);
    auto setLayers = get<GRALLOC1_PFN_SET_LAYER_COUNT>(
            backend->device, GRALLOC1_FUNCTION_SET_LAYER_COUNT);
    auto setProducer = get<GRALLOC1_PFN_SET_PRODUCER_USAGE>(
            backend->device, GRALLOC1_FUNCTION_SET_PRODUCER_USAGE);
    auto setConsumer = get<GRALLOC1_PFN_SET_CONSUMER_USAGE>(
            backend->device, GRALLOC1_FUNCTION_SET_CONSUMER_USAGE);
    auto allocate = get<GRALLOC1_PFN_ALLOCATE>(backend->device, GRALLOC1_FUNCTION_ALLOCATE);
    auto release = get<GRALLOC1_PFN_RELEASE>(backend->device, GRALLOC1_FUNCTION_RELEASE);
    if (!create || !destroy || !setDimensions || !setFormat || !setLayers || !setProducer ||
        !setConsumer || !allocate || !release) {
        std::fprintf(stderr, "FAIL stock Gralloc1 callbacks\n");
        return 1;
    }

    gralloc1_buffer_descriptor_t descriptor = 0;
    if (create(backend->device, &descriptor) != GRALLOC1_ERROR_NONE ||
        setDimensions(backend->device, descriptor, 1920, 1080) != GRALLOC1_ERROR_NONE ||
        setFormat(backend->device, descriptor, HAL_PIXEL_FORMAT_RGBA_8888) !=
                GRALLOC1_ERROR_NONE ||
        setLayers(backend->device, descriptor, 1) != GRALLOC1_ERROR_NONE ||
        setProducer(backend->device, descriptor, GRALLOC1_PRODUCER_USAGE_GPU_RENDER_TARGET) !=
                GRALLOC1_ERROR_NONE ||
        setConsumer(backend->device, descriptor,
                    GRALLOC1_CONSUMER_USAGE_GPU_TEXTURE | GRALLOC1_CONSUMER_USAGE_HWCOMPOSER) !=
                GRALLOC1_ERROR_NONE) {
        destroy(backend->device, descriptor);
        std::fprintf(stderr, "FAIL descriptor setup\n");
        return 1;
    }
    buffer_handle_t raw = nullptr;
    const int32_t allocation = allocate(backend->device, 1, &descriptor, &raw);
    destroy(backend->device, descriptor);
    if (allocation != GRALLOC1_ERROR_NONE || !raw) {
        std::fprintf(stderr, "FAIL stock allocation=%d\n", allocation);
        return 1;
    }
    buffer_handle_t imported = nullptr;
    const AIMapper_Error importError = mapper->v5.importBuffer(raw, &imported);
    uint64_t modifier = UINT64_MAX;
    const bool decoded = importError == AIMAPPER_ERROR_NONE && readModifier(mapper, imported, &modifier);
    const AIMapper_Error freeError = importError == AIMAPPER_ERROR_NONE
            ? mapper->v5.freeBuffer(imported) : importError;
    const int32_t releaseError = release(backend->device, raw);
    dlclose(library);

    if (!decoded || modifier != 0 || freeError != AIMAPPER_ERROR_NONE ||
        releaseError != GRALLOC1_ERROR_NONE) {
        std::fprintf(stderr, "FAIL import=%d decoded=%d modifier=0x%016llx free=%d release=%d\n",
                     importError, decoded, static_cast<unsigned long long>(modifier), freeError,
                     releaseError);
        return 1;
    }
    std::printf("PASS y2s stock RGBA handle: DRM modifier=0x%016llx (linear)\n",
                static_cast<unsigned long long>(modifier));
    return 0;
}
