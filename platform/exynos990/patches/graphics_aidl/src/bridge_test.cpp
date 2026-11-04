#include <aidl/android/hardware/graphics/allocator/IAllocator.h>
#include <aidl/android/hardware/graphics/common/BufferUsage.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <android/binder_ibinder.h>
#include <android/hardware/graphics/mapper/IMapper.h>
#include <cutils/native_handle.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <hardware/gralloc1.h>
#include <hardware/hardware.h>
#include <system/graphics.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <string>
#include <vector>
#include <fstream>

#include "metadata.h"

extern "C" AIBinder* AServiceManager_checkService(const char* instance);

template <typename T>
bool decodeStandardScalar(AIMapper* mapper, buffer_handle_t buffer, int64_t type, T* value) {
    const int32_t required = mapper->v5.getStandardMetadata(buffer, type, nullptr, 0);
    if (required <= 0) return false;
    std::vector<uint8_t> encoded(required);
    if (mapper->v5.getStandardMetadata(buffer, type, encoded.data(), encoded.size()) != required)
        return false;

    size_t offset = 0;
    auto read = [&](void* output, size_t size) {
        if (offset > encoded.size() || size > encoded.size() - offset) return false;
        std::memcpy(output, encoded.data() + offset, size);
        offset += size;
        return true;
    };
    int64_t nameLength = 0;
    if (!read(&nameLength, sizeof(nameLength)) || nameLength < 0 ||
        static_cast<uint64_t>(nameLength) > encoded.size() - offset)
        return false;
    constexpr char kStandardName[] = "android.hardware.graphics.common.StandardMetadataType";
    if (static_cast<size_t>(nameLength) != sizeof(kStandardName) - 1 ||
        std::memcmp(encoded.data() + offset, kStandardName, sizeof(kStandardName) - 1) != 0)
        return false;
    offset += static_cast<size_t>(nameLength);
    int64_t encodedType = 0;
    return read(&encodedType, sizeof(encodedType)) && encodedType == type &&
           read(value, sizeof(*value)) && offset == encoded.size();
}

std::vector<uint8_t> encodeStandardScalar(int64_t type, int32_t value) {
    exynos990::metadata::Writer sizing(nullptr, 0);
    const int32_t required = sizing.standard<int32_t>(type, value);
    std::vector<uint8_t> encoded(required);
    exynos990::metadata::Writer writer(encoded.data(), encoded.size());
    if (writer.standard<int32_t>(type, value) != required) encoded.clear();
    return encoded;
}

bool validateYuvPlaneLayouts(AIMapper* mapper, buffer_handle_t buffer) {
    constexpr int64_t kPlaneLayouts = 15;
    const int32_t required =
            mapper->v5.getStandardMetadata(buffer, kPlaneLayouts, nullptr, 0);
    if (required <= 0) {
        std::fprintf(stderr, "YUV metadata required=%d\n", required);
        return false;
    }
    std::vector<uint8_t> encoded(required);
    const int32_t actual =
            mapper->v5.getStandardMetadata(buffer, kPlaneLayouts, encoded.data(), encoded.size());
    if (actual != required) {
        std::fprintf(stderr, "YUV metadata actual=%d required=%d\n", actual, required);
        return false;
    }
    size_t offset = 0;
    auto read = [&](void* value, size_t bytes) {
        if (offset > encoded.size() || bytes > encoded.size() - offset) return false;
        std::memcpy(value, encoded.data() + offset, bytes);
        offset += bytes;
        return true;
    };
    auto skipString = [&]() {
        int64_t length = 0;
        if (!read(&length, sizeof(length)) || length < 0 ||
            static_cast<uint64_t>(length) > encoded.size() - offset) return false;
        offset += static_cast<size_t>(length);
        return true;
    };
    int64_t encodedType = 0, planeCount = 0;
    if (!skipString() || !read(&encodedType, sizeof(encodedType)) ||
        encodedType != kPlaneLayouts || !read(&planeCount, sizeof(planeCount)) ||
        planeCount <= 0 || planeCount > 8) return false;
    bool foundY = false, foundCb = false, foundCr = false;
    bool planeGeometryValid = true;
    constexpr int64_t expectedWidth = 640;
    constexpr int64_t expectedHeight = 480;
    for (int64_t planeIndex = 0; planeIndex < planeCount; ++planeIndex) {
        int64_t componentCount = 0;
        int64_t planeComponent = -1;
        if (!read(&componentCount, sizeof(componentCount)) ||
            componentCount <= 0 || componentCount > 4) return false;
        for (int64_t componentIndex = 0; componentIndex < componentCount; ++componentIndex) {
            int64_t component = 0, componentOffset = 0, componentSize = 0;
            if (!skipString() || !read(&component, sizeof(component)) ||
                !read(&componentOffset, sizeof(componentOffset)) ||
                !read(&componentSize, sizeof(componentSize)) || componentOffset < 0 ||
                componentSize <= 0) return false;
            if (componentIndex == 0) planeComponent = component;
            foundY |= component == FLEX_COMPONENT_Y;
            foundCb |= component == FLEX_COMPONENT_Cb;
            foundCr |= component == FLEX_COMPONENT_Cr;
        }
        int64_t fields[8] = {};
        for (int64_t& field : fields) {
            if (!read(&field, sizeof(field))) return false;
        }
        // offsetInBytes may be zero. Every other PlaneLayout scalar must be
        // positive for GraphicBufferMapper::lockYCbCr to construct a plane.
        if (fields[0] < 0 || fields[1] <= 0 || fields[2] <= 0 || fields[3] <= 0 ||
            fields[4] <= 0 || fields[5] <= 0 || fields[6] <= 0 || fields[7] <= 0) {
            std::fprintf(stderr, "YUV metadata invalid plane=%lld fields=%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld\n",
                         static_cast<long long>(planeIndex),
                         static_cast<long long>(fields[0]), static_cast<long long>(fields[1]),
                         static_cast<long long>(fields[2]), static_cast<long long>(fields[3]),
                         static_cast<long long>(fields[4]), static_cast<long long>(fields[5]),
                         static_cast<long long>(fields[6]), static_cast<long long>(fields[7]));
            return false;
        }
        if (componentCount != 1) {
            planeGeometryValid = false;
            continue;
        }
        const int64_t expectedPlaneWidth = planeComponent == FLEX_COMPONENT_Y
                ? expectedWidth : (expectedWidth + 1) / 2;
        const int64_t expectedPlaneHeight = planeComponent == FLEX_COMPONENT_Y
                ? expectedHeight : (expectedHeight + 1) / 2;
        const int64_t expectedSubsampling = planeComponent == FLEX_COMPONENT_Y ? 1 : 2;
        // The private Exynos 990 YUV formats are either planar (8-bit samples)
        // or semiplanar (16-bit chroma samples); both must expose the same
        // geometry to GraphicBufferMapper.
        const bool sampleIncrementValid = planeComponent == FLEX_COMPONENT_Y
                ? fields[1] == 8 : (fields[1] == 8 || fields[1] == 16);
        planeGeometryValid &= fields[3] == expectedPlaneWidth &&
                fields[4] == expectedPlaneHeight &&
                fields[6] == expectedSubsampling && fields[7] == expectedSubsampling &&
                sampleIncrementValid && fields[5] >= fields[2] * fields[4];
        std::fprintf(stderr, "YUV plane component=%lld offset=%lld sample=%lld stride=%lld "
                     "geometry=%lldx%lld subsampling=%lldx%lld\n",
                     static_cast<long long>(planeComponent),
                     static_cast<long long>(fields[0]),
                     static_cast<long long>(fields[1]),
                     static_cast<long long>(fields[2]),
                     static_cast<long long>(fields[3]),
                     static_cast<long long>(fields[4]),
                     static_cast<long long>(fields[6]),
                     static_cast<long long>(fields[7]));
    }
    if (offset != encoded.size() || !foundY || !foundCb || !foundCr || !planeGeometryValid) {
        std::fprintf(stderr, "YUV metadata tail offset=%zu size=%zu found=%d/%d/%d planes=%lld\n",
                     offset, encoded.size(), foundY, foundCb, foundCr,
                     static_cast<long long>(planeCount));
        return false;
    }
    return true;
}

template <typename T>
T getGralloc1Function(gralloc1_device_t* device,
                      gralloc1_function_descriptor_t descriptor) {
    return reinterpret_cast<T>(device->getFunction(device, descriptor));
}

bool dumpLegacyFlexLayout(buffer_handle_t buffer, int32_t width, int32_t height) {
    const hw_module_t* module = nullptr;
    gralloc1_device_t* device = nullptr;
    if (hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &module) != 0 ||
        gralloc1_open(module, &device) != 0 || !device) {
        std::fprintf(stderr, "FAIL: cannot open legacy gralloc1 for YUV layout audit\n");
        return false;
    }
    const auto getPlanes = getGralloc1Function<GRALLOC1_PFN_GET_NUM_FLEX_PLANES>(
            device, GRALLOC1_FUNCTION_GET_NUM_FLEX_PLANES);
    const auto lockFlex = getGralloc1Function<GRALLOC1_PFN_LOCK_FLEX>(
            device, GRALLOC1_FUNCTION_LOCK_FLEX);
    const auto lock = getGralloc1Function<GRALLOC1_PFN_LOCK>(
            device, GRALLOC1_FUNCTION_LOCK);
    const auto unlock = getGralloc1Function<GRALLOC1_PFN_UNLOCK>(
            device, GRALLOC1_FUNCTION_UNLOCK);
    // The handle has already been imported and retained by Mapper. Do not
    // retain/release it through gralloc1 here: this vendor advertises
    // RELEASE_IMPLY_DELETE, so an extra release would invalidate Mapper's
    // imported handle and turn this diagnostic into a use-after-free.
    bool ok = getPlanes && lockFlex && lock && unlock;
    uint32_t planeCount = 0;
    if (ok) ok = getPlanes(device, buffer, &planeCount) == GRALLOC1_ERROR_NONE &&
                 planeCount > 0 && planeCount <= 8;
    std::vector<android_flex_plane_t> planes(planeCount);
    android_flex_layout_t layout{FLEX_FORMAT_INVALID, planeCount, planes.data()};
    gralloc1_rect_t rect{0, 0, width, height};
    if (ok) ok = lockFlex(device, buffer, 0, 3, &rect, &layout, -1) ==
                 GRALLOC1_ERROR_NONE;
    uintptr_t base = UINTPTR_MAX;
    if (ok) {
        for (int fdIndex = 0; fdIndex < buffer->numFds; ++fdIndex) {
            struct stat statBuffer{};
            if (fstat(buffer->data[fdIndex], &statBuffer) == 0) {
                std::printf("FD[%d]: number=%d size=%lld\n", fdIndex, buffer->data[fdIndex],
                            static_cast<long long>(statBuffer.st_size));
            }
        }
        for (uint32_t i = 0; i < layout.num_planes; ++i) {
            base = std::min(base, reinterpret_cast<uintptr_t>(layout.planes[i].top_left));
        }
        const size_t mapLength = static_cast<size_t>(width) * static_cast<size_t>(height) * 2;
        void* mapped = mmap(nullptr, mapLength, PROT_READ | PROT_WRITE, MAP_SHARED,
                            buffer->data[0], 0);
        if (mapped != MAP_FAILED) {
            std::printf("MMAP: base=%p len=%zu flex_delta=%lld\n", mapped, mapLength,
                        base != UINTPTR_MAX
                                ? static_cast<long long>(base - reinterpret_cast<uintptr_t>(mapped))
                                : -1LL);
            munmap(mapped, mapLength);
        } else {
            std::printf("MMAP: failed errno=%d\n", errno);
        }
        std::printf("FLEX: format=%d planes=%u base=%p\n", layout.format,
                    layout.num_planes, reinterpret_cast<void*>(base));
        {
            std::ifstream maps("/proc/self/maps");
            std::string line;
            const uintptr_t probe = reinterpret_cast<uintptr_t>(layout.planes[0].top_left);
            while (std::getline(maps, line)) {
                unsigned long long mapStart = 0, mapEnd = 0;
                if (std::sscanf(line.c_str(), "%llx-%llx", &mapStart, &mapEnd) == 2 &&
                    probe >= mapStart && probe < mapEnd) {
                    std::printf("MAP: %s\n", line.c_str());
                    break;
                }
            }
        }
        for (uint32_t i = 0; i < layout.num_planes; ++i) {
            const auto& plane = layout.planes[i];
            std::printf("FLEX[%u]: component=%d offset=%llu bits=%d used=%d hinc=%d "
                        "vinc=%d hsub=%d vsub=%d\n", i, plane.component,
                        static_cast<unsigned long long>(
                                reinterpret_cast<uintptr_t>(plane.top_left) - base),
                        plane.bits_per_component, plane.bits_used, plane.h_increment,
                        plane.v_increment, plane.h_subsampling, plane.v_subsampling);
        }
        int fence = -1;
        ok = unlock(device, buffer, &fence) == GRALLOC1_ERROR_NONE;
        if (fence >= 0) close(fence);
        void* ordinary = nullptr;
        fence = -1;
        const int32_t ordinaryError = lock(device, buffer, 0, 3, &rect, &ordinary, -1);
        std::printf("ORDINARY: error=%d base=%p delta_from_flex=%lld\n", ordinaryError,
                    ordinary, ordinary && base != UINTPTR_MAX
                            ? static_cast<long long>(reinterpret_cast<uintptr_t>(ordinary) - base)
                            : -1LL);
        if (ordinaryError == GRALLOC1_ERROR_NONE) {
            ok = unlock(device, buffer, &fence) == GRALLOC1_ERROR_NONE;
            if (fence >= 0) close(fence);
        }
    }
    gralloc1_close(device);
    return ok;
}

int main(int argc, char** argv) {
    namespace allocator = aidl::android::hardware::graphics::allocator;
    namespace common = aidl::android::hardware::graphics::common;
    static_assert(static_cast<uint64_t>(common::BufferUsage::CAMERA_OUTPUT) ==
                          GRALLOC1_PRODUCER_USAGE_CAMERA,
                  "AIDL CAMERA_OUTPUT must match the Exynos Gralloc1 producer bit");
    static_assert(static_cast<uint64_t>(common::BufferUsage::CAMERA_INPUT) ==
                          GRALLOC1_CONSUMER_USAGE_CAMERA,
                  "AIDL CAMERA_INPUT must match the Exynos Gralloc1 consumer bit");
    constexpr const char* kInstance =
            "android.hardware.graphics.allocator.IAllocator/default";
    const char* mapperPath = argc > 1 ? argv[1] : "/vendor/lib64/hw/mapper.exynos990_compat.so";
    const long iterations = argc > 2 ? std::strtol(argv[2], nullptr, 10) : 1;
    if (iterations < 1 || iterations > 1000000) {
        std::fprintf(stderr, "FAIL: invalid iteration count\n");
        return 1;
    }

    ndk::SpAIBinder binder(AServiceManager_checkService(kInstance));
    if (!binder.get()) {
        std::fprintf(stderr, "FAIL: allocator service is not registered\n");
        return 1;
    }
    auto service = allocator::IAllocator::fromBinder(binder);
    if (!service) {
        std::fprintf(stderr, "FAIL: allocator binder conversion\n");
        return 1;
    }

    std::string suffix;
    auto status = service->getIMapperLibrarySuffix(&suffix);
    if (!status.isOk() || suffix != "exynos990_compat") {
        std::fprintf(stderr, "FAIL: mapper suffix status=%d suffix=%s\n",
                     status.getStatus(), suffix.c_str());
        return 1;
    }

    allocator::BufferDescriptorInfo descriptor;
    descriptor.width = 64;
    descriptor.height = 64;
    descriptor.layerCount = 1;
    descriptor.format = common::PixelFormat::RGBA_8888;
    // Exercise the actual camera producer route instead of testing only a
    // CPU-linear buffer.  The mapper must preserve CAMERA_OUTPUT when it
    // round-trips the imported handle's usage metadata.
    descriptor.usage = static_cast<common::BufferUsage>(
            static_cast<uint64_t>(common::BufferUsage::CPU_READ_OFTEN) |
            static_cast<uint64_t>(common::BufferUsage::CAMERA_OUTPUT));
    bool supported = false;
    status = service->isSupported(descriptor, &supported);
    if (!status.isOk() || !supported) {
        std::fprintf(stderr, "FAIL: descriptor not supported\n");
        return 1;
    }
    allocator::BufferDescriptorInfo unsupportedDescriptor = descriptor;
    unsupportedDescriptor.usage = static_cast<common::BufferUsage>(
            static_cast<uint64_t>(descriptor.usage) | (1ULL << 25));  // GPU_CUBE_MAP
    status = service->isSupported(unsupportedDescriptor, &supported);
    if (!status.isOk() || supported) {
        std::fprintf(stderr, "FAIL: unsupported GPU_CUBE_MAP descriptor advertised\n");
        return 1;
    }
    allocator::BufferDescriptorInfo invalidDescriptor = descriptor;
    invalidDescriptor.width = 0;
    status = service->isSupported(invalidDescriptor, &supported);
    if (!status.isOk() || supported) {
        std::fprintf(stderr, "FAIL: invalid zero-width descriptor advertised\n");
        return 1;
    }

    void* library = dlopen(mapperPath, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        std::fprintf(stderr, "FAIL: dlopen mapper: %s\n", dlerror());
        return 1;
    }
    auto loadMapper = reinterpret_cast<AIMapper_Error (*)(AIMapper**)>(
            dlsym(library, "AIMapper_loadIMapper"));
    AIMapper* mapper = nullptr;
    if (!loadMapper || loadMapper(&mapper) != AIMAPPER_ERROR_NONE || !mapper ||
        mapper->version != AIMAPPER_VERSION_5) {
        std::fprintf(stderr, "FAIL: load Mapper 5\n");
        return 1;
    }

    // Import must reject malformed transport handles before calling into the
    // proprietary Gralloc1 callbacks. This catches the class of truncated
    // Binder parcels that otherwise tends to surface as a vendor crash.
    native_handle_t* malformed = native_handle_create(0, 0);
    if (!malformed) return 1;
    malformed->version = 0;
    buffer_handle_t malformedImported = nullptr;
    const AIMapper_Error malformedError =
            mapper->v5.importBuffer(malformed, &malformedImported);
    native_handle_delete(malformed);
    if (malformedError != AIMAPPER_ERROR_BAD_BUFFER || malformedImported != nullptr) {
        std::fprintf(stderr, "FAIL: malformed native handle accepted error=%d imported=%p\n",
                     malformedError, malformedImported);
        return 1;
    }

    const AIMapper_MetadataTypeDescription* descriptions = nullptr;
    size_t descriptionCount = 0;
    const AIMapper_Error listError =
            mapper->v5.listSupportedMetadataTypes(&descriptions, &descriptionCount);
    if (listError != AIMAPPER_ERROR_NONE || !descriptions || descriptionCount < 21) {
        std::fprintf(stderr,
                     "FAIL: Stable-C metadata description list is incomplete "
                     "error=%d list=%p count=%zu mapper=%s\n",
                     listError, static_cast<const void*>(descriptions), descriptionCount,
                     mapperPath);
        return 1;
    }

    int32_t lastStride = 0;
    size_t lastFds = 0;
    size_t lastInts = 0;
    for (long current = 0; current < iterations; ++current) {
        descriptor.width = 64 + static_cast<int32_t>((current % 8) * 64);
        descriptor.height = 64 + static_cast<int32_t>(((current / 8) % 8) * 64);

        allocator::AllocationResult result;
        status = service->allocate2(descriptor, 1, &result);
        if (!status.isOk() || result.buffers.size() != 1) {
            std::fprintf(stderr,
                         "FAIL[%ld]: allocation status=%d service=%d buffers=%zu\n",
                         current, status.getStatus(), status.getServiceSpecificError(),
                         result.buffers.size());
            return 1;
        }
        const auto& parcelHandle = result.buffers.front();
        native_handle_t* raw =
                native_handle_create(parcelHandle.fds.size(), parcelHandle.ints.size());
        if (!raw) return 1;
        bool duplicateFailed = false;
        for (size_t i = 0; i < parcelHandle.fds.size(); ++i) {
            raw->data[i] = dup(parcelHandle.fds[i].get());
            if (raw->data[i] < 0) duplicateFailed = true;
        }
        for (size_t i = 0; i < parcelHandle.ints.size(); ++i) {
            raw->data[parcelHandle.fds.size() + i] = parcelHandle.ints[i];
        }
        if (duplicateFailed) {
            native_handle_close(raw);
            native_handle_delete(raw);
            std::fprintf(stderr, "FAIL[%ld]: duplicate native handle fds\n", current);
            return 1;
        }

        buffer_handle_t imported = nullptr;
        if (mapper->v5.importBuffer(raw, &imported) != AIMAPPER_ERROR_NONE || !imported) {
            native_handle_close(raw);
            native_handle_delete(raw);
            std::fprintf(stderr, "FAIL[%ld]: mapper importBuffer\n", current);
            return 1;
        }
        buffer_handle_t secondImport = nullptr;
        if (mapper->v5.importBuffer(raw, &secondImport) != AIMAPPER_ERROR_NONE || !secondImport) {
            mapper->v5.freeBuffer(imported);
            native_handle_close(raw);
            native_handle_delete(raw);
            std::fprintf(stderr, "FAIL[%ld]: second mapper importBuffer\n", current);
            return 1;
        }
        uint64_t firstId = 0;
        uint64_t secondId = 0;
        uint64_t decodedWidth = 0;
        uint64_t decodedUsage = 0;
        int32_t decodedDataspace = -1;
        int32_t secondDataspace = -1;
        const std::vector<uint8_t> dataspace = encodeStandardScalar(17, 0x12345678);
        const AIMapper_Error setDataspace =
                mapper->v5.setStandardMetadata(imported, 17, dataspace.data(), dataspace.size());
        const uintptr_t nullAddress = 0;
        const void* nullMetadataPtr = reinterpret_cast<const void*>(nullAddress);
        const AIMapper_Error nullMetadata =
                mapper->v5.setStandardMetadata(imported, 17, nullMetadataPtr, 1);
        const bool metadataValid =
                decodeStandardScalar(mapper, imported, 1, &firstId) &&
                decodeStandardScalar(mapper, secondImport, 1, &secondId) &&
                decodeStandardScalar(mapper, imported, 3, &decodedWidth) &&
                decodeStandardScalar(mapper, imported, 9, &decodedUsage) &&
                decodeStandardScalar(mapper, imported, 17, &decodedDataspace) &&
                decodeStandardScalar(mapper, secondImport, 17, &secondDataspace) &&
                mapper->v5.getStandardMetadata(imported, 12, nullptr, 0) > 0 &&
                mapper->v5.getStandardMetadata(imported, 13, nullptr, 0) > 0 &&
                mapper->v5.getStandardMetadata(imported, 14, nullptr, 0) > 0 &&
                mapper->v5.getStandardMetadata(imported, 15, nullptr, 0) > 0 &&
                mapper->v5.getStandardMetadata(imported, 16, nullptr, 0) > 0;
        // The AIDL contract defines an all-zero region as the full buffer.
        // Exercise that form once so a camera/client that omits the explicit
        // bounds cannot regress into a zero-size Gralloc1 lock.
        ARect region = current == 0
                ? ARect{0, 0, 0, 0}
                : ARect{0, 0, descriptor.width, descriptor.height};
        void* pixels = nullptr;
        AIMapper_Error lockError = mapper->v5.lock(imported, 3, region, -1, &pixels);
        AIMapper_Error flushError = lockError == AIMAPPER_ERROR_NONE
                ? mapper->v5.flushLockedBuffer(imported)
                : lockError;
        AIMapper_Error rereadError = lockError == AIMAPPER_ERROR_NONE
                ? mapper->v5.rereadLockedBuffer(imported)
                : lockError;
        int releaseFence = -1;
        AIMapper_Error unlockError = lockError == AIMAPPER_ERROR_NONE
                ? mapper->v5.unlock(imported, &releaseFence)
                : lockError;
        if (releaseFence >= 0) close(releaseFence);
        AIMapper_Error freeError = mapper->v5.freeBuffer(imported);
        AIMapper_Error secondImportFreeError = mapper->v5.freeBuffer(secondImport);
        AIMapper_Error secondFreeError = mapper->v5.freeBuffer(imported);
        native_handle_close(raw);
        native_handle_delete(raw);

        if (!metadataValid || setDataspace != AIMAPPER_ERROR_NONE ||
            nullMetadata != AIMAPPER_ERROR_BAD_VALUE ||
            decodedDataspace != 0x12345678 || secondDataspace != 0x12345678 ||
            firstId == 0 || firstId != secondId ||
            decodedWidth != static_cast<uint64_t>(descriptor.width) ||
            decodedUsage != static_cast<uint64_t>(descriptor.usage) ||
            lockError != AIMAPPER_ERROR_NONE ||
            flushError != AIMAPPER_ERROR_NONE || rereadError != AIMAPPER_ERROR_NONE ||
            unlockError != AIMAPPER_ERROR_NONE || freeError != AIMAPPER_ERROR_NONE ||
            secondImportFreeError != AIMAPPER_ERROR_NONE ||
            secondFreeError != AIMAPPER_ERROR_BAD_BUFFER) {
            std::fprintf(stderr,
                         "FAIL[%ld]: metadata=%d ids=%llu/%llu width=%llu/%d lock=%d "
                         "flush=%d reread=%d unlock=%d free=%d secondImportFree=%d secondFree=%d\n",
                         current, metadataValid, static_cast<unsigned long long>(firstId),
                         static_cast<unsigned long long>(secondId),
                         static_cast<unsigned long long>(decodedWidth), descriptor.width,
                         lockError, flushError, rereadError, unlockError, freeError,
                         secondImportFreeError, secondFreeError);
            return 1;
        }
        lastStride = result.stride;
        lastFds = parcelHandle.fds.size();
        lastInts = parcelHandle.ints.size();
    }

    // Camera preview/post-processing uses flexible YUV buffers.  Gralloc1
    // requires LOCK_FLEX for these even though Mapper 5 exposes one lock()
    // entry point returning the address of the first plane.
    descriptor.width = 640;
    descriptor.height = 480;
    descriptor.format = common::PixelFormat::YCBCR_420_888;
    descriptor.usage = static_cast<common::BufferUsage>(
            static_cast<uint64_t>(common::BufferUsage::CPU_READ_OFTEN) |
            static_cast<uint64_t>(common::BufferUsage::CAMERA_OUTPUT));
    allocator::AllocationResult yuvResult;
    status = service->allocate2(descriptor, 1, &yuvResult);
    if (!status.isOk() || yuvResult.buffers.size() != 1) {
        std::fprintf(stderr, "FAIL: YCbCr allocation status=%d service=%d buffers=%zu\n",
                     status.getStatus(), status.getServiceSpecificError(),
                     yuvResult.buffers.size());
        return 1;
    }
    const auto& yuvParcel = yuvResult.buffers.front();
    native_handle_t* yuvRaw = native_handle_create(yuvParcel.fds.size(), yuvParcel.ints.size());
    if (!yuvRaw) return 1;
    for (size_t i = 0; i < yuvParcel.fds.size(); ++i) yuvRaw->data[i] = dup(yuvParcel.fds[i].get());
    for (size_t i = 0; i < yuvParcel.ints.size(); ++i) {
        yuvRaw->data[yuvParcel.fds.size() + i] = yuvParcel.ints[i];
    }
    std::fprintf(stderr, "YUV native handle fds=%d ints=%d\n", yuvRaw->numFds,
                 yuvRaw->numInts);
    for (int i = 0; i < yuvRaw->numInts; ++i) {
        std::fprintf(stderr, "  int[%d] @0x%zx = 0x%08x\n", i,
                     offsetof(native_handle_t, data) +
                             static_cast<size_t>(yuvRaw->numFds + i) * sizeof(int),
                     static_cast<unsigned int>(yuvRaw->data[yuvRaw->numFds + i]));
    }
    buffer_handle_t yuvImported = nullptr;
    AIMapper_Error yuvImport = mapper->v5.importBuffer(yuvRaw, &yuvImported);
    const bool yuvMetadataValid = yuvImport == AIMAPPER_ERROR_NONE &&
            validateYuvPlaneLayouts(mapper, yuvImported);
    uint64_t yuvDecodedUsage = 0;
    const bool yuvUsageValid = yuvImport == AIMAPPER_ERROR_NONE &&
            decodeStandardScalar(mapper, yuvImported, 9, &yuvDecodedUsage);
    const bool flexLayoutValid = dumpLegacyFlexLayout(
            yuvImported, descriptor.width, descriptor.height);
    void* yuvData = nullptr;
    const ARect yuvRegion{0, 0, descriptor.width, descriptor.height};
    AIMapper_Error yuvLock = yuvImport == AIMAPPER_ERROR_NONE
            ? mapper->v5.lock(yuvImported, 3, yuvRegion, -1,
                              &yuvData)
            : yuvImport;
    int yuvReleaseFence = -1;
    AIMapper_Error yuvUnlock = yuvLock == AIMAPPER_ERROR_NONE
            ? mapper->v5.unlock(yuvImported, &yuvReleaseFence)
            : yuvLock;
    if (yuvReleaseFence >= 0) close(yuvReleaseFence);
    AIMapper_Error yuvFree = yuvImport == AIMAPPER_ERROR_NONE
            ? mapper->v5.freeBuffer(yuvImported)
            : yuvImport;
    native_handle_close(yuvRaw);
    native_handle_delete(yuvRaw);
    if (yuvImport != AIMAPPER_ERROR_NONE || !yuvMetadataValid || !yuvUsageValid ||
        yuvDecodedUsage != static_cast<uint64_t>(descriptor.usage) || !flexLayoutValid ||
        yuvLock != AIMAPPER_ERROR_NONE || !yuvData ||
        yuvUnlock != AIMAPPER_ERROR_NONE || yuvFree != AIMAPPER_ERROR_NONE) {
        std::fprintf(stderr,
                     "FAIL: YCbCr import=%d metadata=%d usage=%d decodedUsage=%llu expected=%llu "
                     "flex=%d lock=%d data=%p unlock=%d free=%d\n",
                     yuvImport, yuvMetadataValid, yuvUsageValid,
                     static_cast<unsigned long long>(yuvDecodedUsage),
                     static_cast<unsigned long long>(descriptor.usage), flexLayoutValid,
                     yuvLock, yuvData, yuvUnlock, yuvFree);
        return 1;
    }
    dlclose(library);

    std::printf("PASS: suffix=%s iterations=%ld lastStride=%d fds=%zu ints=%zu yuvLock=ok\n",
                suffix.c_str(), iterations, lastStride, lastFds, lastInts);
    return 0;
}

