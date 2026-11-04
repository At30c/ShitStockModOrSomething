#include "camera_buffers.h"

#include <aidl/android/hardware/common/NativeHandle.h>
#include <cutils/native_handle.h>

#include <cerrno>
#include <cstring>
#include <unistd.h>
#include <android/log.h>
#include <hardware/hardware.h>
#include <hardware/gralloc.h>
#include <dlfcn.h>
#include <android/dlext.h>
#include <array>
#include <algorithm>
#include <cstddef>
#include <fcntl.h>
#include <poll.h>
#include <mutex>
#include <sys/system_properties.h>

#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, "camera_aidl_port", __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, "camera_aidl_port", __VA_ARGS__)

namespace exynos990::camera {
namespace aidl_common = ::aidl::android::hardware::common;
namespace aidl_device = ::aidl::android::hardware::camera::device;

namespace {

using ImportIonHandles = int (*)(native_handle_t*);
using FreeIonHandles = void (*)(native_handle_t*);
using ImportCompatHandle = int (*)(const native_handle_t*, buffer_handle_t*);
using FreeCompatHandle = int (*)(buffer_handle_t);

bool preservePrivatePreviewHandle() {
    char value[PROP_VALUE_MAX]{};
    // This is deliberately opt-in while validating the original S20+ private
    // preview format.  The property is read at import time so a test can be
    // disabled without changing the ABI of the handle passed to Camera3.
    return __system_property_get("vendor.camera.aidl.preserve_private_handle", value) > 0 &&
            value[0] == '1' && value[1] == '\0';
}

// O CameraDeviceSession HIDL original não chama diretamente o helper ION da
// câmera. Ele usa HandleImporter, que seleciona o mapper HIDL 2/3/4 disponível,
// cria um handle importado separado e depois o libera com freeBuffer(). Esse
// ABI é exportado por camera.device@3.2-impl.so no vendor do y2s. Mantemos uma
// instância privada para reproduzir exatamente essa posse sem depender do
// provider HIDL estar registrado.
using HandleImporterCtor = void (*)(void*);
using HandleImporterImport = bool (*)(void*, const native_handle_t*&);
using HandleImporterFree = void (*)(void*, const native_handle_t*);

struct AospHandleImporterBridge final {
    void* library = nullptr;
    HandleImporterCtor construct = nullptr;
    HandleImporterImport import = nullptr;
    HandleImporterFree free = nullptr;
    alignas(std::max_align_t) std::array<std::byte, 0x100> storage{};
    bool initialized = false;
    bool available = false;
};

AospHandleImporterBridge& aospHandleImporter() {
    static AospHandleImporterBridge bridge;
    static std::once_flag once;
    std::call_once(once, [] {
        bridge.library = dlopen("/vendor/lib64/camera.device@3.2-impl.so", RTLD_NOW);
        if (!bridge.library)
            bridge.library = dlopen("camera.device@3.2-impl.so", RTLD_NOW);
        // Somente para a validação isolada, o módulo original pode estar
        // ausente da imagem porque o serviço HIDL foi removido. O arquivo
        // copiado para /data/local/tmp permite testar o mesmo HandleImporter
        // sem adicioná-lo à vendor final.
        if (!bridge.library) {
            // A linker namespace de vendor não permite dlopen direto de
            // /data/local/tmp. Use o mecanismo Android de carregar por FD;
            // as dependências continuam sendo resolvidas no namespace do
            // provider, como ocorre com o serviço HIDL original.
            const int fd = open("/data/local/tmp/camera.device@3.2-impl.so",
                                O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                android_dlextinfo extension{};
                extension.flags = ANDROID_DLEXT_USE_LIBRARY_FD;
                extension.library_fd = fd;
                bridge.library = android_dlopen_ext("camera.device@3.2-impl.so",
                                                    RTLD_NOW, &extension);
                close(fd);
            }
        }
        // Em aparelhos de teste em que o fragmento HIDL foi removido da
        // imagem, o arquivo donor pode ser montado sobre um slot de biblioteca
        // vendor já existente (sem criar caminho fora do namespace).
        if (!bridge.library)
            bridge.library = dlopen("/vendor/lib64/libcamera2ndk_vendor.so", RTLD_NOW);
        if (!bridge.library) {
            ALOGE("Camera3Buffers: AOSP HandleImporter library unavailable: %s", dlerror());
            return;
        }
        bridge.construct = reinterpret_cast<HandleImporterCtor>(dlsym(
                bridge.library,
                "_ZN7android8hardware6camera6common4V1_06helper14HandleImporterC1Ev"));
        bridge.import = reinterpret_cast<HandleImporterImport>(dlsym(
                bridge.library,
                "_ZN7android8hardware6camera6common4V1_06helper14HandleImporter12importBufferERPK13native_handle"));
        bridge.free = reinterpret_cast<HandleImporterFree>(dlsym(
                bridge.library,
                "_ZN7android8hardware6camera6common4V1_06helper14HandleImporter10freeBufferEPK13native_handle"));
        bridge.available = bridge.construct && bridge.import && bridge.free;
        if (!bridge.available) {
            ALOGE("Camera3Buffers: AOSP HandleImporter symbols unavailable");
            return;
        }
        bridge.construct(bridge.storage.data());
        bridge.initialized = true;
        ALOGI("Camera3Buffers: using HIDL-compatible AOSP HandleImporter");
    });
    return bridge;
}

void* grallocMapperHandle() {
    static void* handle = [] {
        void* value = dlopen("/vendor/lib64/libGrallocMapperCamera.so",
                             RTLD_NOW | RTLD_NOLOAD);
        if (!value) value = dlopen("libGrallocMapperCamera.so", RTLD_NOW | RTLD_NOLOAD);
        if (!value) value = dlopen("/vendor/lib64/libGrallocMapperCamera.so", RTLD_NOW);
        return value;
    }();
    return handle;
}

struct StableCMapperBridge final {
    void* library = nullptr;
    ImportCompatHandle import = nullptr;
    FreeCompatHandle free = nullptr;
    bool available = false;
};

StableCMapperBridge& stableCMapper() {
    static StableCMapperBridge bridge;
    static std::once_flag once;
    std::call_once(once, [] {
        // The global graphics bridge is already part of the y2s vendor image.
        // Its import path clones the Mali private_handle_t and calls the stock
        // Gralloc1 retain/release callbacks, which is the ownership contract
        // expected by libexynoscamera3.so.  Use this C ABI instead of loading a
        // HIDL implementation from /data, which is outside the vendor linker
        // namespace on some boots.
        bridge.library = dlopen("/vendor/lib64/hw/mapper.exynos990_compat.so",
                                RTLD_NOW | RTLD_LOCAL);
        if (!bridge.library) {
            ALOGE("Camera3Buffers: Stable-C mapper unavailable: %s", dlerror());
            return;
        }
        bridge.import = reinterpret_cast<ImportCompatHandle>(dlsym(
                bridge.library, "exynos990_aidl_camera_import"));
        bridge.free = reinterpret_cast<FreeCompatHandle>(dlsym(
                bridge.library, "exynos990_aidl_camera_free"));
        bridge.available = bridge.import && bridge.free;
        if (!bridge.available)
            ALOGE("Camera3Buffers: Stable-C camera import exports unavailable");
        else
            ALOGI("Camera3Buffers: using Stable-C Gralloc1 retain/release import");
    });
    return bridge;
}

int importWithGraphicMapper(native_handle_t* raw, buffer_handle_t* imported,
                            bool* importedByAospHandleImporter,
                            bool* importedByStableCMapper) {
    if (!raw || !imported) return -EINVAL;
    if (importedByAospHandleImporter) *importedByAospHandleImporter = false;
    if (importedByStableCMapper) *importedByStableCMapper = false;

    // The S26+ AIDL provider imports the raw binder handle with
    // GraphicBufferMapper::importBufferNoValidate() before it reaches the
    // camera HAL.  On the y2s, the vendor HIDL HandleImporter is the ABI-safe
    // front-end for that same framework operation.  Use it first so the
    // active global mapper (Stable-C when AIDL graphics is enabled, legacy
    // mapper otherwise) owns the imported-handle lifetime.  Calling our
    // private Stable-C bridge first used to create a second wrapper around the
    // Mali handle and made ownership depend on which graphics mode happened to
    // start first.
    AospHandleImporterBridge& aosp = aospHandleImporter();
    if (aosp.available && aosp.initialized) {
        const native_handle_t* candidate = raw;
        if (aosp.import(aosp.storage.data(), candidate) && candidate) {
            *imported = const_cast<native_handle_t*>(candidate);
            if (importedByAospHandleImporter) *importedByAospHandleImporter = true;
            ALOGI("Camera3Buffers: imported handle through AOSP HandleImporter raw=%p imported=%p",
                  static_cast<void*>(raw), static_cast<const void*>(candidate));
            return 0;
        }
        ALOGE("Camera3Buffers: GraphicBufferMapper import failed; trying local compatibility fallback");
    }

    // This path is only for a vendor image where the legacy HandleImporter
    // library is absent.  It retains/releases the original S20+ Mali
    // private_handle_t; it never converts it to the S26+ SGR layout.
    StableCMapperBridge& stableC = stableCMapper();
    if (stableC.available) {
        buffer_handle_t candidate = nullptr;
        const int status = stableC.import(raw, &candidate);
        if (status == 0 && candidate) {
            *imported = candidate;
            if (importedByStableCMapper) *importedByStableCMapper = true;
            ALOGI("Camera3Buffers: imported handle through Stable-C fallback raw=%p imported=%p",
                  static_cast<const void*>(raw), static_cast<const void*>(candidate));
            return 0;
        }
        ALOGE("Camera3Buffers: Stable-C fallback import failed status=%d", status);
    }

    void* mapper = grallocMapperHandle();
    auto import = mapper ? reinterpret_cast<ImportIonHandles>(dlsym(
            mapper, "_Z25import_exynos_ion_handlesP16private_handle_t")) : nullptr;
    if (!import) {
        ALOGE("Camera3Buffers: Samsung gralloc mapper import symbol is unavailable");
        return -ENOSYS;
    }
    // Samsung's mapper imports the ION fds in the private handle itself. This
    // is the same operation performed by GraphicBufferMapper::importBufferNoValidate;
    // the handle remains valid until free_exynos_ion_handles() is called.
    const int status = import(raw);
    *imported = raw;
    if (status != 0 || !*imported) {
        ALOGE("Camera3Buffers: GraphicBufferMapper import failed status=%d raw=%p imported=%p",
              status, static_cast<void*>(raw),
              imported ? static_cast<const void*>(*imported) : nullptr);
        return status != 0 ? status : -EINVAL;
    }
    return 0;
}

void freeImportedHandle(buffer_handle_t imported, bool importedByAospHandleImporter,
                        bool importedByStableCMapper) {
    if (!imported) return;
    if (importedByStableCMapper) {
        StableCMapperBridge& stableC = stableCMapper();
        if (stableC.available) {
            const int status = stableC.free(imported);
            if (status != 0)
                ALOGE("Camera3Buffers: Stable-C mapper free failed status=%d", status);
            return;
        }
    }
    if (importedByAospHandleImporter) {
        AospHandleImporterBridge& aosp = aospHandleImporter();
        if (aosp.available && aosp.initialized) {
            aosp.free(aosp.storage.data(), imported);
            return;
        }
    }
    void* mapper = grallocMapperHandle();
    auto freeHandles = mapper ? reinterpret_cast<FreeIonHandles>(dlsym(
            mapper, "_Z23free_exynos_ion_handlesP16private_handle_t")) : nullptr;
    if (freeHandles) freeHandles(const_cast<native_handle_t*>(imported));
}

}  // namespace

void Camera3Buffers::NativeHandleDeleter::operator()(native_handle_t* handle) const {
    if (!handle) return;
    (void)native_handle_close(handle);
    (void)native_handle_delete(handle);
}

Camera3Buffers::~Camera3Buffers() {
    clear();
}

native_handle_t* Camera3Buffers::fromAidl(const aidl_common::NativeHandle& source) {
    if (source.fds.size() > NATIVE_HANDLE_MAX_FDS || source.ints.size() > NATIVE_HANDLE_MAX_INTS)
        return nullptr;
    native_handle_t* handle = native_handle_create(static_cast<int>(source.fds.size()),
                                                    static_cast<int>(source.ints.size()));
    if (!handle) return nullptr;
    for (size_t index = 0; index < source.fds.size(); ++index) {
        const int fd = source.fds[index].get();
        if (fd < 0 || (handle->data[index] = dup(fd)) < 0) {
            (void)native_handle_close(handle);
            (void)native_handle_delete(handle);
            return nullptr;
        }
    }
    for (size_t index = 0; index < source.ints.size(); ++index)
        handle->data[source.fds.size() + index] = source.ints[index];
    return handle;
}

int Camera3Buffers::duplicateFence(const aidl_common::NativeHandle& source) {
    // NativeHandle vazio representa fence -1. Camera3 aceita no máximo um fd.
    if (source.fds.empty() && source.ints.empty()) return -1;
    if (source.fds.size() != 1 || !source.ints.empty() || source.fds[0].get() < 0) return -EINVAL;
    const int copied = dup(source.fds[0].get());
    return copied < 0 ? -errno : copied;
}

int Camera3Buffers::acquire(const aidl_device::StreamBuffer& source, camera3_stream_t* stream,
                            camera3_stream_buffer_t* output) {
    if (!stream || !output || source.bufferId < 0 ||
        source.status != aidl_device::BufferStatus::OK) return -EINVAL;
    const Key key{source.streamId, source.bufferId};
    std::scoped_lock lock(mutex_);
    auto iterator = entries_.find(key);
    if (iterator == entries_.end()) {
        if (source.buffer.fds.empty() && source.buffer.ints.empty()) return -ENOENT;
        // A Samsung Camera abre diversos pools na primeira sessão. Imprimir
        // cada palavra privada de cada handle torna esse caminho I/O-bound,
        // mas não acrescenta informação depois que a ABI foi validada.
        Entry entry;
        entry.handle.reset(fromAidl(source.buffer));
        if (!entry.handle) return -EINVAL;
        if (importWithGraphicMapper(entry.handle.get(), &entry.importedHandle,
                                    &entry.importedByAospHandleImporter,
                                    &entry.importedByStableCMapper) != 0) {
            entry.handle.reset();
            return -EINVAL;
        }
        entry.stream = stream;
        iterator = entries_.emplace(key, std::move(entry)).first;
        // Entry foi movido para o nó estável do std::map. O ponteiro salvo
        // antes do move apontava para o membro do objeto temporário e ficava
        // pendente; o HAL Exynos só dereferencia esse campo quando entrega o
        // frame YUV, por isso a falha aparecia em m_sendYuvStreamResult().
        // Stream format 34 is the implementation-defined preview allocation.
        // configure_streams() translates it in place to the y2s private Mali
        // format 0x11d before process_capture_request().  Accept both values
        // because Camera3Buffers sees the post-configuration stream object.
        // Importing it is still required to establish the
        // CameraService ownership, but the backend/HWC pair must receive the
        // untouched private handle.  An imported mapper handle is safe for
        // public YUV/JPEG buffers, but changes the private-handle identity of
        // this opaque preview route.
        const bool privatePreview = preservePrivatePreviewHandle() &&
                (iterator->second.stream->format == 34 ||
                 iterator->second.stream->format == 0x11d);
        iterator->second.handleReference = privatePreview ? iterator->second.handle.get()
                                                         : iterator->second.importedHandle;
        if (privatePreview) {
            ALOGI("Camera3Buffers: preserving raw private preview handle stream=%d buffer=%lld raw=%p imported=%p",
                  source.streamId, static_cast<long long>(source.bufferId),
                  static_cast<void*>(iterator->second.handle.get()),
                  static_cast<const void*>(iterator->second.importedHandle));
        }
    }
    Entry& entry = iterator->second;
    if (entry.inFlight || entry.stream != stream) return -EBUSY;
    const int acquireFence = duplicateFence(source.acquireFence);
    if (acquireFence < -1) return acquireFence;
    entry.inFlight = true;
    *output = {
            .stream = stream,
            .buffer = &entry.handleReference,
            .status = CAMERA3_BUFFER_STATUS_OK,
            .acquire_fence = acquireFence,
            .release_fence = -1,
    };
    return 0;
}

int Camera3Buffers::retainFrameworkOnly(const aidl_device::StreamBuffer& source,
                                        camera3_stream_t* stream) {
    camera3_stream_buffer_t retained{};
    const int status = acquire(source, stream, &retained);
    if (status != 0) return status;
    // A framework-only buffer is not submitted to the vendor HAL, so its
    // acquire fence would otherwise leak. Wait before touching the memory;
    // CameraService normally supplies -1 for this still-thumbnail path.
    if (retained.acquire_fence >= 0) {
        struct pollfd fencePoll{retained.acquire_fence, POLLIN, 0};
        const int waitStatus = poll(&fencePoll, 1, 5000);
        (void)close(retained.acquire_fence);
        if (waitStatus != 0) {
            ALOGE("Camera3Buffers: framework-only acquire fence wait failed stream=%d status=%d",
                  source.streamId, waitStatus);
            std::scoped_lock lock(mutex_);
            const Key key{source.streamId, source.bufferId};
            auto iterator = entries_.find(key);
            if (iterator != entries_.end()) iterator->second.inFlight = false;
            return -ETIMEDOUT;
        }
    }
    return 0;
}

bool Camera3Buffers::completeFrameworkOnly(int32_t streamId, int64_t bufferId) {
    std::scoped_lock lock(mutex_);
    const Key key{streamId, bufferId};
    auto iterator = entries_.find(key);
    if (iterator == entries_.end() || !iterator->second.inFlight ||
        !iterator->second.importedHandle || !iterator->second.stream) {
        ALOGE("Camera3Buffers: framework-only buffer is not retained stream=%d buffer=%lld",
              streamId, static_cast<long long>(bufferId));
        return false;
    }

    const hw_module_t* hardwareModule = nullptr;
    int status = hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &hardwareModule);
    if (status != 0 || !hardwareModule) {
        ALOGE("Camera3Buffers: unable to load gralloc for framework-only stream=%d status=%d",
              streamId, status);
        iterator->second.inFlight = false;
        return false;
    }
    const auto* gralloc = reinterpret_cast<const gralloc_module_t*>(hardwareModule);
    void* address = nullptr;
    const int width = static_cast<int>(iterator->second.stream->width);
    const int height = static_cast<int>(iterator->second.stream->height);
    const int usage = static_cast<int>(GRALLOC_USAGE_SW_WRITE_OFTEN);
    bool filled = false;

    if (gralloc->lock_ycbcr) {
        android_ycbcr ycbcr{};
        status = gralloc->lock_ycbcr(gralloc, iterator->second.importedHandle, usage,
                                     0, 0, width, height, &ycbcr);
        if (status == 0 && ycbcr.y) {
            const size_t yStride = ycbcr.ystride ? ycbcr.ystride : static_cast<size_t>(width);
            const size_t chromaStride = ycbcr.cstride ? ycbcr.cstride :
                    static_cast<size_t>(std::max(1, width / 2));
            for (int row = 0; row < height; ++row)
                std::memset(static_cast<std::uint8_t*>(ycbcr.y) + row * yStride,
                            0x10, static_cast<size_t>(width));
            const int chromaRows = (height + 1) / 2;
            if (ycbcr.cb) {
                for (int row = 0; row < chromaRows; ++row)
                    std::memset(static_cast<std::uint8_t*>(ycbcr.cb) + row * chromaStride,
                                0x80, static_cast<size_t>(width / 2));
            }
            if (ycbcr.cr) {
                for (int row = 0; row < chromaRows; ++row)
                    std::memset(static_cast<std::uint8_t*>(ycbcr.cr) + row * chromaStride,
                                0x80, static_cast<size_t>(width / 2));
            }
            filled = true;
            ALOGI("Camera3Buffers: completed framework-only YUV stream=%d buffer=%lld ystride=%zu cstride=%zu",
                  streamId, static_cast<long long>(bufferId), yStride, chromaStride);
            (void)gralloc->unlock(gralloc, iterator->second.importedHandle);
        } else {
            ALOGE("Camera3Buffers: gralloc lock_ycbcr failed stream=%d status=%d", streamId, status);
        }
    }
    if (!filled && gralloc->lock) {
        status = gralloc->lock(gralloc, iterator->second.importedHandle, usage,
                               0, 0, width, height, &address);
        if (status == 0 && address) {
            const size_t stride = static_cast<size_t>(width);
            std::memset(address, 0x10, stride * static_cast<size_t>(height));
            // The fallback is used only by legacy grallocs which do not
            // expose lock_ycbcr. Keep the chroma area neutral as well.
            std::memset(static_cast<std::uint8_t*>(address) + stride * height, 0x80,
                        stride * static_cast<size_t>((height + 1) / 2));
            filled = true;
            ALOGI("Camera3Buffers: completed framework-only linear YUV stream=%d buffer=%lld",
                  streamId, static_cast<long long>(bufferId));
            (void)gralloc->unlock(gralloc, iterator->second.importedHandle);
        } else {
            ALOGE("Camera3Buffers: gralloc lock failed stream=%d status=%d", streamId, status);
        }
    }
    iterator->second.inFlight = false;
    return filled;
}

int Camera3Buffers::canAcquire(const aidl_device::StreamBuffer& source, camera3_stream_t* stream) const {
    if (!stream || source.bufferId < 0 || source.status != aidl_device::BufferStatus::OK) return -EINVAL;
    const Key key{source.streamId, source.bufferId};
    std::scoped_lock lock(mutex_);
    const auto iterator = entries_.find(key);
    if (iterator == entries_.end()) {
        return source.buffer.fds.empty() && source.buffer.ints.empty() ? -ENOENT : 0;
    }
    return iterator->second.inFlight || iterator->second.stream != stream ? -EBUSY : 0;
}

int Camera3Buffers::remove(const aidl_device::BufferCache& cache) {
    const Key key{cache.streamId, cache.bufferId};
    std::scoped_lock lock(mutex_);
    auto iterator = entries_.find(key);
    if (iterator == entries_.end()) return 0;
    if (iterator->second.inFlight) return -EBUSY;
    freeImportedHandle(iterator->second.importedHandle,
                       iterator->second.importedByAospHandleImporter,
                       iterator->second.importedByStableCMapper);
    entries_.erase(iterator);
    return 0;
}

bool Camera3Buffers::takeReturned(const camera3_stream_buffer_t& native, int32_t* streamId,
                                  int64_t* bufferId) {
    if (!native.buffer || !streamId || !bufferId) return false;
    std::scoped_lock lock(mutex_);
    const native_handle_t* handle = *native.buffer;
    for (auto& [key, entry] : entries_) {
        const bool sameHandle = entry.handle.get() == handle || entry.handleReference == handle;
        if (!sameHandle || entry.stream != native.stream || !entry.inFlight) continue;
        entry.inFlight = false;
        *streamId = key.streamId;
        *bufferId = key.bufferId;
        return true;
    }
    ALOGE("Camera3Buffers: returned buffer is not in flight stream=%p handle=%p",
          static_cast<const void*>(native.stream), static_cast<const void*>(handle));
    return false;
}

void Camera3Buffers::cancel(const camera3_stream_buffer_t& native) {
    std::scoped_lock lock(mutex_);
    if (native.acquire_fence >= 0) (void)close(native.acquire_fence);
    if (!native.buffer) return;
    const native_handle_t* handle = *native.buffer;
    for (auto& [key, entry] : entries_) {
        if ((entry.handle.get() == handle || entry.handleReference == handle) &&
            entry.stream == native.stream) {
            entry.inFlight = false;
            return;
        }
    }
}

void Camera3Buffers::clear() {
    std::scoped_lock lock(mutex_);
    for (auto& [key, entry] : entries_)
        freeImportedHandle(entry.importedHandle, entry.importedByAospHandleImporter,
                           entry.importedByStableCMapper);
    entries_.clear();
}

}  // namespace exynos990::camera
