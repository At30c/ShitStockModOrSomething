#pragma once

#include "camera3_module.h"
#include "camera_buffers.h"
#include "camera_streams.h"

#include <aidl/android/hardware/camera/device/BnCameraDeviceSession.h>
#include <aidl/android/hardware/camera/device/ICameraDeviceCallback.h>
#include <aidl/android/hardware/camera/device/StreamBuffer.h>
#include <aidl/vendor/samsung/hardware/camera/device/BnSehCameraDeviceSession.h>

#include <atomic>
#include <array>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <vector>

namespace exynos990::camera {

// Sessão AIDL V4 dona de um camera3_device_t. A abertura e o encerramento
// pertencem a esta classe para que nenhum request alcance o HAL sem callbacks
// e sem um caminho de flush/close.
class CameraSession final : public ::aidl::android::hardware::camera::device::BnCameraDeviceSession {
  public:
    static std::shared_ptr<CameraSession> create(
        std::shared_ptr<Camera3Module> module, int cameraId, int publicId,
        std::string openId,
        std::shared_ptr<::aidl::android::hardware::camera::device::ICameraDeviceCallback> callback,
        int* error);
    ~CameraSession() override;

    // SharedRefBase constrói o objeto para manter a lifetime Binder correta.
    // A factory create() é o único caminho que inicializa e publica a sessão.
    CameraSession(std::shared_ptr<Camera3Module> module, int cameraId, int publicId,
                  std::string openId,
                  camera3_device_t* device,
                  std::shared_ptr<::aidl::android::hardware::camera::device::ICameraDeviceCallback> callback);

    ::ndk::ScopedAStatus close() override;
    ::ndk::ScopedAStatus configureStreams(
        const ::aidl::android::hardware::camera::device::StreamConfiguration& configuration,
        std::vector<::aidl::android::hardware::camera::device::HalStream>* output) override;
    ::ndk::ScopedAStatus constructDefaultRequestSettings(
        ::aidl::android::hardware::camera::device::RequestTemplate type,
        ::aidl::android::hardware::camera::device::CameraMetadata* output) override;
    ::ndk::ScopedAStatus flush() override;
    ::ndk::ScopedAStatus getCaptureRequestMetadataQueue(
        ::aidl::android::hardware::common::fmq::MQDescriptor<int8_t,
            ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>* output) override;
    ::ndk::ScopedAStatus getCaptureResultMetadataQueue(
        ::aidl::android::hardware::common::fmq::MQDescriptor<int8_t,
            ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>* output) override;
    ::ndk::ScopedAStatus isReconfigurationRequired(
        const ::aidl::android::hardware::camera::device::CameraMetadata& oldParams,
        const ::aidl::android::hardware::camera::device::CameraMetadata& newParams,
        bool* output) override;
    ::ndk::ScopedAStatus processCaptureRequest(
        const std::vector<::aidl::android::hardware::camera::device::CaptureRequest>& requests,
        const std::vector<::aidl::android::hardware::camera::device::BufferCache>& caches,
        int32_t* processed) override;
    ::ndk::ScopedAStatus signalStreamFlush(const std::vector<int32_t>& streamIds,
                                            int32_t streamConfigCounter) override;
    ::ndk::ScopedAStatus switchToOffline(
        const std::vector<int32_t>& streamsToKeep,
        ::aidl::android::hardware::camera::device::CameraOfflineSessionInfo* offlineInfo,
        std::shared_ptr<::aidl::android::hardware::camera::device::ICameraOfflineSession>* output) override;
    ::ndk::ScopedAStatus repeatingRequestEnd(int32_t frameNumber,
                                              const std::vector<int32_t>& streamIds) override;
    ::ndk::ScopedAStatus configureStreamsV2(
        const ::aidl::android::hardware::camera::device::StreamConfiguration& configuration,
        ::aidl::android::hardware::camera::device::ConfigureStreamsRet* output) override;

    // Samsung parameter string (samsungcamera=..., shootingmode=..., sw-vdis=...).
    // The Exynos HAL only honours stream options and Samsung capture modes
    // after HAL3_camera_device_set_parameters() has received it.
    ::ndk::ScopedAStatus setVendorParameters(const std::string& parameters);

  protected:
    ::ndk::SpAIBinder createBinder() override;

  private:
    int initialize();
    int closeNative();
    void handleResult(const camera3_capture_result_t* result);
    void handleNotify(const camera3_notify_msg_t* message);
    camera3_buffer_request_status_t handleRequestStreamBuffers(
        uint32_t count, const camera3_buffer_request_t* requests, uint32_t* returnedCount,
        camera3_stream_buffer_ret_t* returned);
    void handleReturnStreamBuffers(uint32_t count, const camera3_stream_buffer_t* const* buffers);
    static void onResult(const camera3_callback_ops_t*, const camera3_capture_result_t* result);
    static void onNotify(const camera3_callback_ops_t*, const camera3_notify_msg_t* message);
    static camera3_buffer_request_status_t onRequestStreamBuffers(
        const camera3_callback_ops_t*, uint32_t count, const camera3_buffer_request_t* requests,
        uint32_t* returnedCount, camera3_stream_buffer_ret_t* returned);
    static void onReturnStreamBuffers(const camera3_callback_ops_t*, uint32_t count,
                                      const camera3_stream_buffer_t* const* buffers);
    static ::ndk::ScopedAStatus unsupported(const char* operation);

    struct InFlightRequest {
        std::vector<camera3_stream_buffer_t> outputBuffers;
        struct FrameworkOnlyBuffer {
            int32_t streamId = -1;
            int64_t bufferId = 0;
            bool retained = false;
        };
        std::vector<FrameworkOnlyBuffer> frameworkOnlyBuffers;
        // Physical settings are owned for the whole lifetime of the native
        // request. The Exynos HAL may inspect these arrays after
        // process_capture_request() returns, just like output_buffers.
        std::vector<std::string> physicalIds;
        std::vector<const char*> physicalIdPointers;
        std::vector<camera_metadata_t*> physicalSettings;
        std::vector<const camera_metadata_t*> physicalSettingPointers;
        camera_metadata_t* settings = nullptr;
        camera3_capture_request_t request{};

        ~InFlightRequest() {
            for (camera_metadata_t* metadata : physicalSettings) {
                if (metadata) free_camera_metadata(metadata);
            }
            physicalSettings.clear();
            physicalSettingPointers.clear();
            physicalIdPointers.clear();
        }
    };

    void clearInFlightLocked();
    void reapCompletedLocked();
    camera_metadata_t* normalizeRequestCrop(camera_metadata_t* metadata) const;

    std::shared_ptr<Camera3Module> module_;
    int cameraId_ = -1;
    int publicId_ = -1;
    std::string openId_;
    camera3_device_t* device_ = nullptr;
    std::shared_ptr<::aidl::android::hardware::camera::device::ICameraDeviceCallback> callback_;
    // O HAL devolve em cada callback o mesmo camera3_callback_ops_t recebido
    // em initialize(); o dono é recuperado por ele. Assim duas câmeras abertas
    // ao mesmo tempo (gravação dupla abre 0 e 1) não dividem um roteamento
    // global. `ops` precisa continuar sendo o primeiro membro.
    struct CallbackOps {
        camera3_callback_ops_t ops{};
        CameraSession* owner = nullptr;
    };
    CallbackOps callbacks_{};
    std::atomic<uint32_t> resultMetadataSamples_{0};
    std::mutex mutex_;
    // Vendor Camera3 calls can synchronously emit callbacks. Keep HAL calls
    // serialized without holding mutex_, so callback threads can progress.
    std::mutex nativeMutex_;
    bool closed_ = false;
    Camera3Streams streams_;
    Camera3Buffers buffers_;
    // Storage dos requests entregues ao HAL. O wrapper HIDL Samsung libera o
    // request e o array de buffers logo após process_capture_request(); só os
    // handles (por bufferId) persistem. Mantemos ainda uma janela curta de
    // requests concluídos como margem, liberada por reapCompletedLocked().
    std::map<uint32_t, InFlightRequest> inFlight_;
    std::deque<uint32_t> retainedCompleted_;
    // O backend Exynos possui somente oito Bayer buffers FLITE.  Este conjunto
    // representa requests que já entraram no HAL e ainda não devolveram nenhum
    // buffer de saída. Ele é separado de inFlight_, que guarda storage e não
    // pode determinar o limite do pipeline físico.
    std::set<uint32_t> pendingNativeFrames_;
    // CameraService pode enviar um lote maior que a janela FLITE. Aguarde a
    // devolução de um output antes de rejeitar o lote; devolver uma exceção
    // imediatamente faz o framework encerrar a sessão e mostra "Erro na
    // câmera", mesmo quando o HAL ainda está drenando os frames.
    std::condition_variable pendingCv_;
    // O callback do HAL pode chegar enquanto process_capture_request ainda
    // está retornando. Ele apenas marca o frame aqui; a remoção da entrada é
    // feita depois que a chamada nativa retorna.
    std::mutex completedMutex_;
    std::set<uint32_t> completedFrames_;
    bool hasRequestSettings_ = false;
    // CameraService envia settings apenas no primeiro request de uma sequência
    // repetida. O wrapper HIDL Samsung reutiliza o último metadata completo;
    // manter uma cópia própria reproduz esse contrato sem apontar para memória
    // pertencente ao Binder.
    camera_metadata_t* lastSettings_ = nullptr;
    // Samsung's Exynos 990 converter assumes a non-empty crop region even
    // when CameraService omits ANDROID_SCALER_CROP_REGION for a full-frame
    // request. Keep the active-array rectangle for that ABI repair.
    std::array<int32_t, 4> activeArray_{0, 0, 4032, 3024};
    std::shared_ptr<::aidl::vendor::samsung::hardware::camera::device::ISehCameraDeviceSession>
            sehExtension_;
    // Sessões que ainda aceitam callbacks do HAL. closeNative() remove a
    // sessão antes de flush()/close(), e callbacks tardios são descartados
    // como no antigo ponteiro único.
    static CameraSession* activeOwner(const camera3_callback_ops_t* ops);
    static std::mutex activeMutex_;
    static std::set<CameraSession*> active_;
};

// Binder anexado como extension da ICameraDeviceSession. cameraserver o
// resolve com AIBinder_getExtension() + ISehCameraDeviceSession::fromBinder(),
// o mesmo contrato do provider AIDL Samsung (A26/S26+).
class SehCameraDeviceSessionExtension final
    : public ::aidl::vendor::samsung::hardware::camera::device::BnSehCameraDeviceSession {
  public:
    explicit SehCameraDeviceSessionExtension(std::weak_ptr<CameraSession> session)
        : session_(std::move(session)) {}
    ::ndk::ScopedAStatus setParameters(const std::string& parameters) override;

  private:
    std::weak_ptr<CameraSession> session_;
};

}  // namespace exynos990::camera
