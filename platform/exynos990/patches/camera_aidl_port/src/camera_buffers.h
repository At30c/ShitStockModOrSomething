#pragma once

#include <aidl/android/hardware/camera/device/BufferCache.h>
#include <aidl/android/hardware/camera/device/StreamBuffer.h>
#include <hardware/camera3.h>

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>

namespace exynos990::camera {

// Registro de handles que atravessam o limite Binder -> Camera3. Cada handle
// é reconstruído com FDs duplicados: o parcel AIDL pode ser destruído logo que
// processCaptureRequest retorna, mas o HAL pode devolver o buffer bem depois.
class Camera3Buffers final {
  public:
    Camera3Buffers() = default;
    ~Camera3Buffers();

    Camera3Buffers(const Camera3Buffers&) = delete;
    Camera3Buffers& operator=(const Camera3Buffers&) = delete;

    // Cria/atualiza um buffer cacheado ou obtém a cópia já conhecida. O
    // resultado pertence ao registro até takeReturned() ou clear().
    int acquire(const ::aidl::android::hardware::camera::device::StreamBuffer& source,
                camera3_stream_t* stream, camera3_stream_buffer_t* output);
    // Retém uma stream que o backend Samsung não aceita no configure call.
    // O buffer continua pertencendo ao framework, mas precisa ser importado
    // para que o adaptador possa preenchê-lo antes de devolvê-lo ao AIDL.
    int retainFrameworkOnly(
            const ::aidl::android::hardware::camera::device::StreamBuffer& source,
            camera3_stream_t* stream);
    // Preenche uma stream YUV auxiliar com um frame neutro e libera a entrada.
    // Isso mantém o contrato de thumbnail da Camera2 quando o JPEG nativo já
    // contém a miniatura, sem enviar uma quarta porta YUV ao Exynos HAL.
    bool completeFrameworkOnly(int32_t streamId, int64_t bufferId);
    // Preflight sem tomar posse de FDs. Usado para validar o lote inteiro
    // antes de qualquer request alcançar o HAL.
    int canAcquire(const ::aidl::android::hardware::camera::device::StreamBuffer& source,
                   camera3_stream_t* stream) const;
    // Remove somente buffers que já voltaram do HAL. AIDL BufferCache significa
    // que o framework não voltará a enviar o handle deste par stream/buffer.
    int remove(const ::aidl::android::hardware::camera::device::BufferCache& cache);
    // Localiza um buffer que o HAL devolveu e transfere o registro de volta à
    // sessão. O método não fecha release_fence: essa posse será definida pelo
    // adaptador de CaptureResult.
    bool takeReturned(const camera3_stream_buffer_t& native, int32_t* streamId, int64_t* bufferId);
    // Cancela a transferência quando process_capture_request falha antes de o
    // HAL assumir os buffers. Fecha apenas o acquire fence duplicado aqui.
    void cancel(const camera3_stream_buffer_t& native);
    void clear();

  private:
    struct Key {
        int32_t streamId;
        int64_t bufferId;
        bool operator<(const Key& other) const {
            return streamId != other.streamId ? streamId < other.streamId : bufferId < other.bufferId;
        }
    };
    struct NativeHandleDeleter {
        void operator()(native_handle_t* handle) const;
    };
    struct Entry {
        std::unique_ptr<native_handle_t, NativeHandleDeleter> handle;
        // O Camera3 HIDL importa o handle no GraphicBufferMapper antes de
        // entregá-lo ao HAL. O blob Exynos usa o handle importado para o
        // caminho YUV; manter apenas a cópia Binder provoca falha em
        // m_sendYuvStreamResult().
        buffer_handle_t importedHandle = nullptr;
        // camera3_stream_buffer_t recebe um ponteiro para buffer_handle_t, e
        // não o native_handle_t diretamente.
        buffer_handle_t handleReference = nullptr;
        // O caminho HIDL mantém o handle importado pelo HandleImporter AOSP;
        // o fallback Samsung importa apenas os fds ION no handle privado.
        bool importedByAospHandleImporter = false;
        bool importedByStableCMapper = false;
        camera3_stream_t* stream = nullptr;
        bool inFlight = false;
    };

    static native_handle_t* fromAidl(
            const ::aidl::android::hardware::common::NativeHandle& source);
    static int duplicateFence(const ::aidl::android::hardware::common::NativeHandle& source);

    mutable std::mutex mutex_;
    std::map<Key, Entry> entries_;
};

}  // namespace exynos990::camera
