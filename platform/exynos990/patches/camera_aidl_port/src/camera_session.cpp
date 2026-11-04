#include "camera_session.h"
#include "sigpipe_guard.h"

#include <aidl/android/hardware/camera/device/BufferStatus.h>
#include <aidl/android/hardware/camera/device/BufferRequest.h>
#include <aidl/android/hardware/camera/device/BufferRequestStatus.h>
#include <aidl/android/hardware/camera/device/CaptureResult.h>
#include <aidl/android/hardware/camera/device/PhysicalCameraMetadata.h>
#include <aidl/android/hardware/camera/device/ErrorCode.h>
#include <aidl/android/hardware/camera/device/ErrorMsg.h>
#include <aidl/android/hardware/camera/device/NotifyMsg.h>
#include <aidl/android/hardware/camera/device/ShutterMsg.h>
#include <aidl/android/hardware/camera/device/StreamBuffer.h>
#include <aidl/android/hardware/camera/device/StreamBufferRequestError.h>
#include <aidl/android/hardware/camera/device/StreamBufferRet.h>
#include <aidl/android/hardware/camera/device/StreamBuffersVal.h>
#include <aidl/android/hardware/common/NativeHandle.h>
#include <system/camera_metadata.h>
#include <android/log.h>

#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, "camera_aidl_port", __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, "camera_aidl_port", __VA_ARGS__)

#include <cerrno>
#include <algorithm>
#include <cinttypes>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <set>
#include <sys/system_properties.h>
#include <utility>
#include <vector>

namespace exynos990::camera {
namespace aidl_device = ::aidl::android::hardware::camera::device;

namespace {

// O provider compartilha o caminho Binder da UI. Os logs por frame serviram
// para validar a ABI, mas tornam a abertura da Samsung Camera I/O-bound.
// Conservamos as primeiras amostras e uma a cada 120 eventos.
bool shouldLogFrameSample(std::atomic<uint32_t>* counter) {
    const uint32_t sample = counter->fetch_add(1, std::memory_order_relaxed);
    return sample < 12 || sample % 120 == 0;
}

std::atomic<uint32_t> processSamples{0};
std::atomic<uint32_t> metadataSamples{0};
std::atomic<uint32_t> submitSamples{0};
std::atomic<uint32_t> resultSamples{0};

// The Samsung Camera app requests a YUV thumbnail companion together with
// the JPEG.  The Exynos 990 backend already embeds the thumbnail in the JPEG
// result, while the AIDL bridge currently keeps that companion out of the
// native configure call.  Returning an artificial ERROR buffer for it makes
// CameraService tear down an otherwise successful still capture.  Keep this
// switch explicit until the native thumbnail buffer path is implemented.
bool suppressFrameworkOnlyBufferError() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get(
            "vendor.camera.aidl.suppress_framework_only_error", value);
    return length > 0 && std::strcmp(value, "1") == 0;
}

// O FLITE do Exynos 990 tem oito Bayer buffers. Reservar duas posições para
// o sensor/3AA impede que a nona requisição alcance m_previewFrameHandler
// antes de um resultado anterior devolver seu buffer. O valor pode ser
// ajustado apenas para diagnóstico, mas nunca pode alcançar oito.
size_t maxPendingNativeFrames() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get(
            "vendor.camera.aidl.max_pending_requests", value);
    if (length <= 0) return 6;
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 1 || parsed > 7) return 6;
    return static_cast<size_t>(parsed);
}

}  // namespace

std::mutex CameraSession::activeMutex_;
std::set<CameraSession*> CameraSession::active_;

CameraSession* CameraSession::activeOwner(const camera3_callback_ops_t* ops) {
    if (!ops) return nullptr;
    CameraSession* owner = reinterpret_cast<const CallbackOps*>(ops)->owner;
    std::scoped_lock lock(activeMutex_);
    return active_.count(owner) ? owner : nullptr;
}

int physicalBackendIdForLogicalId(int publicId, const std::string& physicalId) {
    if (publicId != 20) return -1;
    if (physicalId == "0") return 0;
    if (physicalId == "2") return 2;
    if (physicalId == "50") return 2;
    if (physicalId == "52") return 4;
    return -1;
}

CameraSession::CameraSession(std::shared_ptr<Camera3Module> module, int cameraId, int publicId,
                             std::string openId, camera3_device_t* device,
                             std::shared_ptr<aidl_device::ICameraDeviceCallback> callback)
    : module_(std::move(module)), cameraId_(cameraId), publicId_(publicId),
      openId_(std::move(openId)), device_(device),
      callback_(std::move(callback)) {
    static_assert(offsetof(CallbackOps, ops) == 0, "HAL callback pointer must be the wrapper");
    callbacks_.owner = this;
    callbacks_.ops.process_capture_result = &CameraSession::onResult;
    callbacks_.ops.notify = &CameraSession::onNotify;
    // As entradas de buffer manager só fazem parte do contrato Camera3 3.6.
    // Um HAL 3.5 lê a mesma estrutura, mas exige estes ponteiros nulos; expor
    // callbacks novos a ele altera o contrato binário que o blob espera.
    if (device_ && device_->common.version >= CAMERA_DEVICE_API_VERSION_3_6) {
        callbacks_.ops.request_stream_buffers = &CameraSession::onRequestStreamBuffers;
        callbacks_.ops.return_stream_buffers = &CameraSession::onReturnStreamBuffers;
    }
}

CameraSession::~CameraSession() {
    protectNativeIpcFromSigpipe();
    (void)closeNative();
}

void CameraSession::clearInFlightLocked() {
    std::scoped_lock completedLock(completedMutex_);
    for (auto& [frame, request] : inFlight_) {
        if (request.settings) free_camera_metadata(request.settings);
    }
    inFlight_.clear();
    retainedCompleted_.clear();
    pendingNativeFrames_.clear();
    pendingCv_.notify_all();
    completedFrames_.clear();
    if (lastSettings_) {
        free_camera_metadata(lastSettings_);
        lastSettings_ = nullptr;
    }
    hasRequestSettings_ = false;
}

void CameraSession::reapCompletedLocked() {
    std::set<uint32_t> completed;
    {
        std::scoped_lock completedLock(completedMutex_);
        completed.swap(completedFrames_);
    }
    for (const uint32_t frame : completed) {
        if (inFlight_.find(frame) != inFlight_.end()) retainedCompleted_.push_back(frame);
    }
    // sehProcessOneCaptureRequest() libera o request logo após o HAL aceitá-lo;
    // a janela abaixo é só margem e mantém a memória limitada durante o preview.
    constexpr size_t kRetainedCompletedRequests = 32;
    while (retainedCompleted_.size() > kRetainedCompletedRequests) {
        auto it = inFlight_.find(retainedCompleted_.front());
        retainedCompleted_.pop_front();
        if (it == inFlight_.end()) continue;
        if (it->second.settings) free_camera_metadata(it->second.settings);
        inFlight_.erase(it);
    }
}

std::shared_ptr<CameraSession> CameraSession::create(
        std::shared_ptr<Camera3Module> module, int cameraId, int publicId, std::string openId,
        std::shared_ptr<aidl_device::ICameraDeviceCallback> callback, int* error) {
    if (error) *error = -EINVAL;
    if (!module || !callback) return nullptr;
    camera3_device_t* device = nullptr;
    const int openResult = module->open(openId, &device);
    ALOGI("CameraSession: native open metadata_id=%d open_id=%s result=%d device=%p", cameraId,
          openId.c_str(), openResult, device);
    if (openResult != 0) {
        if (error) *error = openResult;
        return nullptr;
    }
    auto session = ndk::SharedRefBase::make<CameraSession>(std::move(module), cameraId, publicId,
                                                            std::move(openId), device,
                                                            std::move(callback));
    {
        // Registrado antes de initialize(): o HAL pode emitir notify durante
        // a inicialização. Conflitos entre câmeras são decididos pelo
        // CameraService (resource_cost/conflicting_devices) e pelo HAL.
        std::scoped_lock lock(activeMutex_);
        active_.insert(session.get());
    }
    const int initResult = session->initialize();
    if (initResult != 0) {
        (void)session->close();
        if (error) *error = initResult;
        return nullptr;
    }
    // createBinder() anexa esta extension; ela precisa existir antes de o
    // binder da sessão ser criado para o cameraserver.
    session->sehExtension_ = ndk::SharedRefBase::make<SehCameraDeviceSessionExtension>(session);
    if (error) *error = 0;
    return session;
}

// asBinder() mantém o AIBinder apenas por referência fraca e o recria quando
// ele expira, então a extension tem de ser anexada a cada binder criado.
::ndk::SpAIBinder CameraSession::createBinder() {
    ::ndk::SpAIBinder binder = BnCameraDeviceSession::createBinder();
    if (sehExtension_) {
        const binder_status_t status =
                AIBinder_setExtension(binder.get(), sehExtension_->asBinder().get());
        ALOGI("CameraSession: ISehCameraDeviceSession extension status=%d", status);
    }
    return binder;
}

::ndk::ScopedAStatus SehCameraDeviceSessionExtension::setParameters(const std::string& parameters) {
    const auto session = session_.lock();
    if (!session) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    return session->setVendorParameters(parameters);
}

::ndk::ScopedAStatus CameraSession::setVendorParameters(const std::string& parameters) {
    protectNativeIpcFromSigpipe();
    std::scoped_lock nativeLock(nativeMutex_);
    camera3_device_t* device = nullptr;
    {
        std::scoped_lock lock(mutex_);
        if (closed_ || !device_ || !device_->ops)
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        device = device_;
    }
    // Samsung's sehSetParameters() calls camera3_device_ops::reserved[0]
    // (ops + 0x50) with the raw string; camera.exynos990.so installs
    // HAL3_camera_device_set_parameters() there. The return value is ignored
    // by the HIDL wrapper as well.
    using SetParameters = int (*)(const camera3_device_t*, const char*);
    auto setParametersFn = reinterpret_cast<SetParameters>(device->ops->reserved[0]);
    if (!setParametersFn) return unsupported("Camera3 backend has no set_parameters entry");
    const int result = setParametersFn(device, parameters.c_str());
    ALOGI("CameraSession: set_parameters length=%zu result=%d %.160s", parameters.size(), result,
          parameters.c_str());
    return ::ndk::ScopedAStatus::ok();
}

int CameraSession::initialize() {
    protectNativeIpcFromSigpipe();
    std::scoped_lock lock(mutex_);
    if (!device_ || !device_->ops || !device_->ops->initialize) return -ENODEV;
    if (module_ && cameraId_ >= 0) {
        camera_info info{};
        if (module_->getCameraInfo(cameraId_, &info) == 0 && info.static_camera_characteristics) {
            camera_metadata_entry active{};
            if (find_camera_metadata_entry(
                        const_cast<camera_metadata_t*>(info.static_camera_characteristics),
                        ANDROID_SENSOR_INFO_ACTIVE_ARRAY_SIZE, &active) == 0 &&
                active.type == TYPE_INT32 && active.count >= 4 && active.data.i32[2] > 0 &&
                active.data.i32[3] > 0) {
                activeArray_ = {active.data.i32[0], active.data.i32[1], active.data.i32[2],
                                active.data.i32[3]};
                ALOGI("CameraSession: active array id=%d [%d,%d,%d,%d]", cameraId_,
                      activeArray_[0], activeArray_[1], activeArray_[2], activeArray_[3]);
            }
        }
    }
    const int result = device_->ops->initialize(device_, &callbacks_.ops);
    ALOGI("CameraSession: native initialize result=%d device_version=0x%x callbacks=%p", result,
          device_->common.version, &callbacks_.ops);
    return result;
}

camera_metadata_t* CameraSession::normalizeRequestCrop(camera_metadata_t* metadata) const {
    if (!metadata) return nullptr;
    camera_metadata_entry crop{};
    const int cropStatus = find_camera_metadata_entry(metadata, ANDROID_SCALER_CROP_REGION, &crop);
    bool validCrop = cropStatus == 0 && crop.type == TYPE_INT32 && crop.count >= 4 &&
            crop.data.i32[2] > 0 && crop.data.i32[3] > 0;
    float zoomRatio = 1.0f;
    camera_metadata_entry zoom{};
    if (find_camera_metadata_entry(metadata, ANDROID_CONTROL_ZOOM_RATIO, &zoom) == 0 &&
        zoom.type == TYPE_FLOAT && zoom.count >= 1 && zoom.data.f[0] > 0.0f)
        zoomRatio = zoom.data.f[0];
    if (validCrop && zoomRatio <= 1.0001f) return metadata;

    int32_t rectangle[4] = {activeArray_[0], activeArray_[1], activeArray_[2], activeArray_[3]};
    if (zoomRatio > 1.0001f) {
        const float width = static_cast<float>(activeArray_[2]) / zoomRatio;
        const float height = static_cast<float>(activeArray_[3]) / zoomRatio;
        rectangle[0] = activeArray_[0] + static_cast<int32_t>((activeArray_[2] - width) * 0.5f);
        rectangle[1] = activeArray_[1] + static_cast<int32_t>((activeArray_[3] - height) * 0.5f);
        rectangle[2] = std::max(1, static_cast<int32_t>(width));
        rectangle[3] = std::max(1, static_cast<int32_t>(height));
    }
    if (cropStatus == 0 && crop.type == TYPE_INT32 && crop.count >= 4) {
        if (update_camera_metadata_entry(metadata, crop.index, rectangle, 4, nullptr) == 0)
            ALOGI("CameraSession: normalized crop [%d,%d,%d,%d] zoom=%.3f", rectangle[0],
                  rectangle[1], rectangle[2], rectangle[3], zoomRatio);
        return metadata;
    }
    const size_t entries = get_camera_metadata_entry_count(metadata);
    const size_t data = get_camera_metadata_data_count(metadata);
    camera_metadata_t* expanded = allocate_camera_metadata(entries + 1, data + 16);
    if (!expanded || append_camera_metadata(expanded, metadata) != 0 ||
        add_camera_metadata_entry(expanded, ANDROID_SCALER_CROP_REGION, rectangle, 4) != 0) {
        if (expanded) free_camera_metadata(expanded);
        ALOGE("CameraSession: unable to add default crop region");
        return metadata;
    }
    ALOGI("CameraSession: added crop [%d,%d,%d,%d] zoom=%.3f", rectangle[0], rectangle[1],
          rectangle[2], rectangle[3], zoomRatio);
    free_camera_metadata(metadata);
    return expanded;
}

int CameraSession::closeNative() {
    protectNativeIpcFromSigpipe();
    std::scoped_lock nativeLock(nativeMutex_);
    camera3_device_t* closing = nullptr;
    std::shared_ptr<Camera3Module> module;
    {
        std::scoped_lock lock(mutex_);
        if (closed_) return 0;
        closed_ = true;
        {
            std::scoped_lock activeLock(activeMutex_);
            active_.erase(this);
        }
        closing = device_;
        device_ = nullptr;
        callback_.reset();
        module = module_;
    }
    int result = 0;
    // Exynos can emit a final result while flush() is draining. Never hold
    // the session mutex across this vendor call.
    if (closing && closing->ops && closing->ops->flush)
        result = closing->ops->flush(closing);
    {
        std::scoped_lock lock(mutex_);
        buffers_.clear();
        clearInFlightLocked();
        streams_.clear();
    }
    if (closing && module) {
        const int closeResult = module->close(closing);
        if (result == 0) result = closeResult;
    }
    return result;
}

::ndk::ScopedAStatus CameraSession::unsupported(const char* operation) {
    return ::ndk::ScopedAStatus::fromExceptionCodeWithMessage(EX_UNSUPPORTED_OPERATION, operation);
}

::ndk::ScopedAStatus CameraSession::close() {
    return closeNative() == 0 ? ::ndk::ScopedAStatus::ok()
                                    : ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
}

::ndk::ScopedAStatus CameraSession::configureStreams(
        const aidl_device::StreamConfiguration& configuration,
        std::vector<aidl_device::HalStream>* output) {
    protectNativeIpcFromSigpipe();
    if (!output) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    std::scoped_lock lock(mutex_);
    if (closed_ || !device_) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    const int result = streams_.configure(device_, configuration, output);
    if (result != 0) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    // A nova configuração invalida a associação de streamId e handle anterior.
    buffers_.clear();
    clearInFlightLocked();
    hasRequestSettings_ = false;
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus CameraSession::constructDefaultRequestSettings(
        aidl_device::RequestTemplate type, aidl_device::CameraMetadata* output) {
    if (!output) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    std::scoped_lock lock(mutex_);
    if (closed_ || !device_ || !device_->ops || !device_->ops->construct_default_request_settings)
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    const camera_metadata_t* metadata = device_->ops->construct_default_request_settings(
            device_, static_cast<int>(type));
    if (!metadata) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    const size_t size = get_camera_metadata_compact_size(metadata);
    output->metadata.resize(size);
    if (!copy_camera_metadata(output->metadata.data(), size, metadata)) {
        output->metadata.clear();
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus CameraSession::flush() {
    protectNativeIpcFromSigpipe();
    std::scoped_lock nativeLock(nativeMutex_);
    camera3_device_t* device = nullptr;
    {
        std::scoped_lock lock(mutex_);
        if (closed_ || !device_ || !device_->ops || !device_->ops->flush)
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        device = device_;
    }
    const int result = device->ops->flush(device);
    if (result != 0)
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus CameraSession::getCaptureRequestMetadataQueue(
        ::aidl::android::hardware::common::fmq::MQDescriptor<int8_t,
                ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>* output) {
    if (output) *output = {};
    // Um descritor vazio é o fallback AIDL documentado: CameraService mantém
    // metadata inline quando a fila não é válida. Exceção aqui aborta open().
    return output ? ::ndk::ScopedAStatus::ok()
                  : ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

::ndk::ScopedAStatus CameraSession::getCaptureResultMetadataQueue(
        ::aidl::android::hardware::common::fmq::MQDescriptor<int8_t,
                ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>* output) {
    if (output) *output = {};
    return output ? ::ndk::ScopedAStatus::ok()
                  : ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

::ndk::ScopedAStatus CameraSession::isReconfigurationRequired(
        const aidl_device::CameraMetadata&, const aidl_device::CameraMetadata&, bool* output) {
    if (output) *output = true;
    // Sem converter session parameters não é seguro alegar compatibilidade.
    // O framework então chama configureStreams novamente.
    return output ? ::ndk::ScopedAStatus::ok()
                  : ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

::ndk::ScopedAStatus CameraSession::processCaptureRequest(
        const std::vector<aidl_device::CaptureRequest>& requests,
        const std::vector<aidl_device::BufferCache>& caches,
        int32_t* processed) {
    protectNativeIpcFromSigpipe();
    if (processed) *processed = 0;
    // Keep native HAL entry points serialized with flush/close, but do not
    // keep the session mutex while the vendor call runs. Exynos can deliver a
    // result synchronously from process_capture_request(); holding mutex_ here
    // starves handleResult(), leaks the eight FLITE buffers, and makes
    // CameraService watchdog abort during the next flush.
    std::scoped_lock nativeLock(nativeMutex_);
    std::unique_lock lock(mutex_);
    if (closed_ || !device_ || !device_->ops || !device_->ops->process_capture_request)
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    reapCompletedLocked();
    // Os descartes chegam antes dos novos requests. Nunca descarte um handle
    // ainda em voo: a framework deverá tentar de novo depois do callback.
    for (const auto& cache : caches) {
        if (buffers_.remove(cache) != 0)
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    // Nunca envie metade de um lote: AidlCamera3Device descarta os handles do
    // lote quando a chamada falha ou retorna uma contagem parcial.
    bool settingsAvailable = hasRequestSettings_ && lastSettings_ != nullptr;
    std::set<std::pair<int32_t, int64_t>> batchBuffers;
    for (const auto& request : requests) {
        if (shouldLogFrameSample(&processSamples)) {
            ALOGI("CameraSession: process entry frame=%d fmq=%zu metadata=%zu outputs=%zu",
                  request.frameNumber, request.fmqSettingsSize,
                  request.settings.metadata.size(), request.outputBuffers.size());
        }
        if (request.frameNumber < 0 || request.fmqSettingsSize != 0 || request.outputBuffers.empty() ||
            (!request.inputBuffer.buffer.fds.empty() || !request.inputBuffer.buffer.ints.empty()) ||
            request.inputWidth != 0 || request.inputHeight != 0)
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        if (!request.physicalCameraSettings.empty()) {
            const bool nativeLogical = cameraId_ == publicId_ && nativeLogicalCameraIds();
            if (!device_ || device_->common.version < CAMERA_DEVICE_API_VERSION_3_5 ||
                (!nativeLogical && publicId_ != 20))
                return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
            std::set<std::string> physicalIds;
            for (const auto& physical : request.physicalCameraSettings) {
                int physicalBackendId = -1;
                const bool knownPhysical = nativeLogical
                        ? parseNumericCameraId(physical.physicalCameraId, &physicalBackendId)
                        : physicalBackendIdForLogicalId(publicId_, physical.physicalCameraId) >= 0;
                if (physical.fmqSettingsSize != 0 || physical.physicalCameraId.empty() ||
                    physical.settings.metadata.empty() || !knownPhysical ||
                    !physicalIds.insert(physical.physicalCameraId).second)
                    return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
                const auto* metadata = reinterpret_cast<const camera_metadata_t*>(
                        physical.settings.metadata.data());
                size_t expectedSize = physical.settings.metadata.size();
                if (validate_camera_metadata_structure(metadata, &expectedSize) != 0 ||
                    expectedSize != physical.settings.metadata.size())
                    return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
            }
        }
        if (!request.settings.metadata.empty()) {
            const auto* settings = reinterpret_cast<const camera_metadata_t*>(request.settings.metadata.data());
            // validate_camera_metadata_structure() treats this argument as
            // the available byte capacity.  Passing zero makes even a valid
            // 48-byte request fail with "Metadata size ... <= expected size
            // (0)" before it reaches the native Camera3 HAL.
            size_t expectedSize = request.settings.metadata.size();
            if (validate_camera_metadata_structure(settings, &expectedSize) != 0 ||
                expectedSize != request.settings.metadata.size())
                return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
            settingsAvailable = true;
        } else if (!settingsAvailable) {
            return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
        for (const auto& source : request.outputBuffers) {
            camera3_stream_t* stream = streams_.find(source.streamId);
            if (!stream || !batchBuffers.emplace(source.streamId, source.bufferId).second ||
                buffers_.canAcquire(source, stream) != 0)
                return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
    }
    int32_t accepted = 0;
    for (const auto& request : requests) {
        // Não permita que o bridge entregue mais requests ao backend do que a
        // frente FLITE consegue drenar. O provider HIDL Samsung preservava
        // essa janela implicitamente; sem ela o nono frame esgota o pool de
        // oito Bayer buffers e o preview passa a repetir o último frame.
        const size_t pendingCap = maxPendingNativeFrames();
        if (pendingNativeFrames_.size() >= pendingCap) {
            ALOGI("CameraSession: waiting for FLITE slot pending=%zu cap=%zu before frame=%d",
                  pendingNativeFrames_.size(), pendingCap, request.frameNumber);
            const bool drained = pendingCv_.wait_for(
                    lock, std::chrono::milliseconds(1500), [this, pendingCap] {
                        return closed_ || pendingNativeFrames_.size() < pendingCap;
                    });
            if (!drained || closed_) {
                ALOGE("CameraSession: FLITE slot did not drain pending=%zu cap=%zu frame=%d",
                      pendingNativeFrames_.size(), pendingCap, request.frameNumber);
                return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
            }
            ALOGI("CameraSession: FLITE slot available pending=%zu frame=%d",
                  pendingNativeFrames_.size(), request.frameNumber);
        }
        // AIDL transporta a metadata como bytes; a Camera3 recebe o mesmo
        // blob. Só aceite um tamanho que a própria estrutura confirma.
        const camera_metadata_t* settings = nullptr;
        camera_metadata_t* ownedSettings = nullptr;
        camera_metadata_t* candidateLastSettings = nullptr;
        if (!request.settings.metadata.empty()) {
            const auto* transported = reinterpret_cast<const camera_metadata_t*>(
                    request.settings.metadata.data());
            size_t expectedSize = request.settings.metadata.size();
            if (validate_camera_metadata_structure(transported, &expectedSize) != 0 ||
                expectedSize != request.settings.metadata.size())
                break;
            // The AIDL vector is a compact Binder payload.  The Samsung
            // Camera3 implementation follows the old HIDL wrapper and may
            // inspect the packet's reserved capacity after this call, so do
            // not pass the Binder-owned bytes directly to the vendor HAL.
            // clone_camera_metadata() creates the aligned, owned packet used
            // by the native Camera3 contract and preserves every vendor tag.
            ownedSettings = clone_camera_metadata(transported);
            if (!ownedSettings) {
                ALOGE("CameraSession: unable to clone request metadata frame=%d",
                      request.frameNumber);
                break;
            }
            ownedSettings = normalizeRequestCrop(ownedSettings);
            if (shouldLogFrameSample(&metadataSamples)) {
                ALOGI("CameraSession: request metadata frame=%d transport=%zu header=%zu compact=%zu "
                      "owned=%zu entries=%zu data=%zu",
                      request.frameNumber, request.settings.metadata.size(),
                      get_camera_metadata_size(transported),
                      get_camera_metadata_compact_size(transported),
                      get_camera_metadata_size(ownedSettings),
                      get_camera_metadata_entry_count(ownedSettings),
                      get_camera_metadata_data_count(ownedSettings));
            }
            settings = ownedSettings;
            // lastSettings_ é atualizado somente depois de o HAL aceitar o
            // request. Assim uma falha não substitui uma configuração válida
            // por metadata que nunca foi consumido pelo backend.
            candidateLastSettings = clone_camera_metadata(ownedSettings);
            if (!candidateLastSettings) {
                ALOGE("CameraSession: unable to retain request metadata frame=%d",
                      request.frameNumber);
                free_camera_metadata(ownedSettings);
                break;
            }
        } else if (hasRequestSettings_ && lastSettings_) {
            // Requests repetidos normalmente carregam settings vazio no AIDL.
            // O Camera3 Samsung espera o último pacote completo, como fazia o
            // adaptador HIDL, e trata nullptr como uma configuração inválida.
            ownedSettings = clone_camera_metadata(lastSettings_);
            if (!ownedSettings) {
                ALOGE("CameraSession: unable to clone retained metadata frame=%d",
                      request.frameNumber);
                break;
            }
            ownedSettings = normalizeRequestCrop(ownedSettings);
            settings = ownedSettings;
        } else {
            // Após configureStreams o primeiro request precisa trazer settings.
            break;
        }
        std::vector<camera3_stream_buffer_t> outputs;
        outputs.reserve(request.outputBuffers.size());
        std::vector<InFlightRequest::FrameworkOnlyBuffer> frameworkOnlyBuffers;
        bool valid = true;
        for (size_t index = 0; index < request.outputBuffers.size(); ++index) {
            const auto& source = request.outputBuffers[index];
            camera3_stream_t* stream = streams_.find(source.streamId);
            if (!stream) {
                valid = false;
                for (const auto& buffer : outputs) buffers_.cancel(buffer);
                break;
            }
            if (!streams_.isNativeConfigured(source.streamId) &&
                !streams_.isNativeCaptureAllowed(source.streamId)) {
                // A framework-only companion stream has no HAL-owned priv and
                // must never enter ExynosCameraRequest. Retain/import its
                // framework buffer so the JPEG callback can complete it with
                // a neutral YUV thumbnail instead of returning ERROR_BUFFER.
                const int retainStatus = buffers_.retainFrameworkOnly(source, stream);
                if (retainStatus != 0) {
                    ALOGE("CameraSession: unable to retain framework-only stream=%d buffer=%lld status=%d",
                          source.streamId, static_cast<long long>(source.bufferId), retainStatus);
                    valid = false;
                    for (const auto& buffer : outputs) buffers_.cancel(buffer);
                    break;
                }
                frameworkOnlyBuffers.push_back({source.streamId, source.bufferId, true});
                continue;
            }
            camera3_stream_buffer_t nativeBuffer{};
            if (buffers_.acquire(source, stream, &nativeBuffer) != 0) {
                valid = false;
                for (const auto& buffer : outputs) buffers_.cancel(buffer);
                break;
            }
            outputs.push_back(nativeBuffer);
        }
        if (!valid) {
            if (ownedSettings) free_camera_metadata(ownedSettings);
            if (candidateLastSettings) free_camera_metadata(candidateLastSettings);
            break;
        }
        std::vector<std::string> physicalIds;
        std::vector<camera_metadata_t*> physicalSettings;
        physicalIds.reserve(request.physicalCameraSettings.size());
        physicalSettings.reserve(request.physicalCameraSettings.size());
        bool physicalValid = true;
        for (const auto& physical : request.physicalCameraSettings) {
            const auto* transported = reinterpret_cast<const camera_metadata_t*>(
                    physical.settings.metadata.data());
            camera_metadata_t* ownedPhysical = clone_camera_metadata(transported);
            if (!ownedPhysical) {
                physicalValid = false;
                break;
            }
            ownedPhysical = normalizeRequestCrop(ownedPhysical);
            physicalIds.push_back(physical.physicalCameraId);
            physicalSettings.push_back(ownedPhysical);
        }
        if (!physicalValid) {
            for (camera_metadata_t* metadata : physicalSettings) free_camera_metadata(metadata);
            for (const auto& buffer : outputs) buffers_.cancel(buffer);
            if (ownedSettings) free_camera_metadata(ownedSettings);
            if (candidateLastSettings) free_camera_metadata(candidateLastSettings);
            break;
        }
        camera3_capture_request_t native{
                .frame_number = static_cast<uint32_t>(request.frameNumber),
                .settings = settings,
                .input_buffer = nullptr,
                .num_output_buffers = static_cast<uint32_t>(outputs.size()),
                .output_buffers = outputs.data(),
                .num_physcam_settings = static_cast<uint32_t>(physicalIds.size()),
                .physcam_id = nullptr,
                .physcam_settings = nullptr,
        };
        if (inFlight_.find(native.frame_number) != inFlight_.end()) {
            for (const auto& buffer : outputs) buffers_.cancel(buffer);
            for (camera_metadata_t* metadata : physicalSettings) free_camera_metadata(metadata);
            if (ownedSettings) free_camera_metadata(ownedSettings);
            if (candidateLastSettings) free_camera_metadata(candidateLastSettings);
            break;
        }
        auto [inFlightIt, inserted] = inFlight_.try_emplace(native.frame_number);
        if (!inserted) {
            for (const auto& buffer : outputs) buffers_.cancel(buffer);
            for (camera_metadata_t* metadata : physicalSettings) free_camera_metadata(metadata);
            if (ownedSettings) free_camera_metadata(ownedSettings);
            if (candidateLastSettings) free_camera_metadata(candidateLastSettings);
            break;
        }
        InFlightRequest& retained = inFlightIt->second;
        retained.outputBuffers = std::move(outputs);
        retained.frameworkOnlyBuffers = std::move(frameworkOnlyBuffers);
        retained.physicalIds = std::move(physicalIds);
        retained.physicalSettings = std::move(physicalSettings);
        retained.physicalIdPointers.reserve(retained.physicalIds.size());
        retained.physicalSettingPointers.reserve(retained.physicalSettings.size());
        for (const std::string& physicalId : retained.physicalIds)
            retained.physicalIdPointers.push_back(physicalId.c_str());
        for (camera_metadata_t* metadata : retained.physicalSettings)
            retained.physicalSettingPointers.push_back(metadata);
        retained.settings = ownedSettings;
        retained.request = native;
        retained.request.output_buffers = retained.outputBuffers.data();
        retained.request.physcam_id = retained.physicalIdPointers.empty() ? nullptr :
                retained.physicalIdPointers.data();
        retained.request.physcam_settings = retained.physicalSettingPointers.empty() ? nullptr :
                retained.physicalSettingPointers.data();
        const bool logRequest = shouldLogFrameSample(&submitSamples);
        if (logRequest) {
            ALOGI("CameraSession: submitting native frame=%d outputs=%zu settings=%p",
                  request.frameNumber, retained.outputBuffers.size(),
                  static_cast<const void*>(settings));
        }
        camera3_device_t* nativeDevice = device_;
        camera3_capture_request_t* nativeRequest = &retained.request;
        // Insira antes de chamar o HAL: alguns blobs entregam o primeiro
        // resultado de forma síncrona dentro de process_capture_request().
        pendingNativeFrames_.insert(native.frame_number);
        lock.unlock();
        const int result = nativeDevice->ops->process_capture_request(nativeDevice, nativeRequest);
        lock.lock();
        reapCompletedLocked();
        if (result != 0 || logRequest)
            ALOGI("CameraSession: native frame=%d result=%d", request.frameNumber, result);
        if (result != 0) {
            pendingNativeFrames_.erase(native.frame_number);
            pendingCv_.notify_all();
            auto failed = inFlight_.find(native.frame_number);
            if (failed != inFlight_.end()) {
                for (const auto& buffer : failed->second.outputBuffers) buffers_.cancel(buffer);
                if (failed->second.settings) free_camera_metadata(failed->second.settings);
                inFlight_.erase(failed);
            }
            if (candidateLastSettings) free_camera_metadata(candidateLastSettings);
            break;
        }
        ownedSettings = nullptr;
        if (candidateLastSettings) {
            if (lastSettings_) free_camera_metadata(lastSettings_);
            lastSettings_ = candidateLastSettings;
            candidateLastSettings = nullptr;
        }
        hasRequestSettings_ = true;
        ++accepted;
    }
    if (processed) *processed = accepted;
    return accepted == static_cast<int32_t>(requests.size()) ? ::ndk::ScopedAStatus::ok()
            : ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
}

::ndk::ScopedAStatus CameraSession::signalStreamFlush(const std::vector<int32_t>& streamIds,
                                                       int32_t streamConfigCounter) {
    protectNativeIpcFromSigpipe();
    std::scoped_lock lock(mutex_);
    if (closed_ || !device_) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    // AIDL sends this oneway and can race a new configureStreams() call. The
    // S26+ provider tracks the generation in its HAL StreamConfiguration; the
    // old S20+ Camera3 entry point does not expose it, so enforce the rule at
    // the adapter boundary.
    if (streams_.isStaleFlush(streamConfigCounter)) {
        ALOGI("CameraSession: ignoring stale stream flush counter=%d", streamConfigCounter);
        return ::ndk::ScopedAStatus::ok();
    }
    if (!device_->ops || !device_->ops->signal_stream_flush) return ::ndk::ScopedAStatus::ok();
    // AIDL fornece ids; Camera3 recebe os endereços persistentes configurados.
    // O contador é de bookkeeping do framework e não existe no contrato 3.x.
    std::vector<const camera3_stream_t*> nativeStreams;
    for (const int32_t streamId : streamIds) {
        camera3_stream_t* stream = streams_.find(streamId);
        if (!stream) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        for (const auto* previous : nativeStreams) {
            if (previous == stream) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
        nativeStreams.push_back(stream);
    }
    if (!nativeStreams.empty())
        device_->ops->signal_stream_flush(device_, static_cast<uint32_t>(nativeStreams.size()),
                                          nativeStreams.data());
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus CameraSession::switchToOffline(
        const std::vector<int32_t>&, aidl_device::CameraOfflineSessionInfo* info,
        std::shared_ptr<aidl_device::ICameraOfflineSession>* output) {
    if (info) *info = {};
    if (output) output->reset();
    return unsupported("offline session requires request ownership implementation");
}

::ndk::ScopedAStatus CameraSession::repeatingRequestEnd(int32_t,
                                                         const std::vector<int32_t>&) {
    // O Camera3 3.5 não possui esse callback; não há estado próprio a limpar
    // enquanto o buffer manager entrega/recebe todos os buffers explicitamente.
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus CameraSession::configureStreamsV2(
        const aidl_device::StreamConfiguration& configuration, aidl_device::ConfigureStreamsRet* output) {
    if (!output) return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    return configureStreams(configuration, &output->halStreams);
}

void CameraSession::onResult(const camera3_callback_ops_t* ops,
                             const camera3_capture_result_t* result) {
    CameraSession* session = activeOwner(ops);
    if (session && result) session->handleResult(result);
}

void CameraSession::onNotify(const camera3_callback_ops_t* ops,
                             const camera3_notify_msg_t* message) {
    CameraSession* session = activeOwner(ops);
    if (session && message) session->handleNotify(message);
}

camera3_buffer_request_status_t CameraSession::onRequestStreamBuffers(
        const camera3_callback_ops_t* ops, uint32_t count,
        const camera3_buffer_request_t* requests, uint32_t* returnedCount,
        camera3_stream_buffer_ret_t* returned) {
    CameraSession* session = activeOwner(ops);
    if (!session) return CAMERA3_BUF_REQ_FAILED_UNKNOWN;
    return session->handleRequestStreamBuffers(count, requests, returnedCount, returned);
}

void CameraSession::onReturnStreamBuffers(const camera3_callback_ops_t* ops, uint32_t count,
                                          const camera3_stream_buffer_t* const* buffers) {
    CameraSession* session = activeOwner(ops);
    if (session) session->handleReturnStreamBuffers(count, buffers);
}

void CameraSession::handleResult(const camera3_capture_result_t* native) {
    if (shouldLogFrameSample(&resultSamples)) {
        ALOGI("CameraSession: result callback frame=%u buffers=%u input=%p result=%p",
              native ? native->frame_number : 0, native ? native->num_output_buffers : 0,
              native ? static_cast<const void*>(native->input_buffer) : nullptr,
              native ? static_cast<const void*>(native->result) : nullptr);
    }
    std::shared_ptr<aidl_device::ICameraDeviceCallback> callback;
    std::vector<InFlightRequest::FrameworkOnlyBuffer> frameworkOnlyBuffers;
    {
        std::scoped_lock lock(mutex_);
        if (closed_ || !callback_) return;
        callback = callback_;
        auto inFlight = inFlight_.find(native->frame_number);
        if (inFlight != inFlight_.end())
            frameworkOnlyBuffers = inFlight->second.frameworkOnlyBuffers;
    }
    aidl_device::CaptureResult result;
    result.frameNumber = static_cast<int32_t>(native->frame_number);
    result.fmqResultSize = 0;
    result.partialResult = static_cast<int32_t>(native->partial_result);
    // A CaptureResult sem reprocessamento precisa declarar explicitamente que
    // não possui input. O valor padrão do parcelable é streamId=0; enviado
    // assim, o CameraService interpreta a entrada como uma stream válida e
    // tenta desreferenciar a inputStream inexistente.
    result.inputBuffer.streamId = -1;
    result.inputBuffer.bufferId = 0;
    result.inputBuffer.buffer = {};
    result.inputBuffer.status = aidl_device::BufferStatus::ERROR;
    result.inputBuffer.acquireFence = {};
    result.inputBuffer.releaseFence = {};
    if (native->result) {
        // The frame number is generated by CameraService, while the sensor
        // timestamp belongs to the Exynos backend.  Sampling both here lets
        // us distinguish a recycled preview surface from a sensor/ISP stream
        // that has actually stopped advancing, without touching the buffer
        // contents or changing the timing of the HAL.
        // Contador por sessão: com duas câmeras abertas (gravação dupla) cada
        // uma precisa da própria amostragem para provar que avança.
        const uint32_t sample = resultMetadataSamples_.fetch_add(1, std::memory_order_relaxed);
        if (sample < 12 || sample % 120 == 0) {
            camera_metadata_entry timestamp{};
            camera_metadata_entry duration{};
            const int timestampStatus = find_camera_metadata_entry(
                    const_cast<camera_metadata_t*>(native->result), ANDROID_SENSOR_TIMESTAMP,
                    &timestamp);
            const int durationStatus = find_camera_metadata_entry(
                    const_cast<camera_metadata_t*>(native->result),
                    ANDROID_SENSOR_FRAME_DURATION, &duration);
            const int64_t sensorTimestamp = timestampStatus == 0 && timestamp.count >= 1 ?
                    timestamp.data.i64[0] : -1;
            const int64_t frameDuration = durationStatus == 0 && duration.count >= 1 ?
                    duration.data.i64[0] : -1;
            ALOGI("CameraSession: sensor timing camera=%d frame=%u timestamp=%" PRId64
                  " duration=%" PRId64 " sample=%u",
                  cameraId_, native->frame_number, sensorTimestamp, frameDuration, sample);
        }
        const size_t size = get_camera_metadata_compact_size(native->result);
        result.result.metadata.resize(size);
        if (!copy_camera_metadata(result.result.metadata.data(), size, native->result)) {
            result.result.metadata.clear();
            return;
        }
    }
    if (native->num_physcam_metadata > 0 && native->physcam_ids && native->physcam_metadata) {
        result.physicalCameraMetadata.reserve(native->num_physcam_metadata);
        for (uint32_t index = 0; index < native->num_physcam_metadata; ++index) {
            if (!native->physcam_ids[index] || !native->physcam_metadata[index]) continue;
            aidl_device::PhysicalCameraMetadata physical;
            physical.fmqMetadataSize = 0;
            physical.physicalCameraId = native->physcam_ids[index];
            const size_t size = get_camera_metadata_compact_size(native->physcam_metadata[index]);
            physical.metadata.metadata.resize(size);
            if (size == 0 || !copy_camera_metadata(physical.metadata.metadata.data(), size,
                                                    native->physcam_metadata[index])) {
                physical.metadata.metadata.clear();
                continue;
            }
            result.physicalCameraMetadata.push_back(std::move(physical));
        }
        ALOGI("CameraSession: physical result metadata frame=%u count=%zu", native->frame_number,
              result.physicalCameraMetadata.size());
    }
    result.outputBuffers.reserve(native->num_output_buffers);
    for (uint32_t index = 0; index < native->num_output_buffers; ++index) {
        const camera3_stream_buffer_t& source = native->output_buffers[index];
        int32_t streamId = 0;
        int64_t bufferId = 0;
        if (!buffers_.takeReturned(source, &streamId, &bufferId)) {
            // O HAL transferiu esta fence ao framework; se o resultado não
            // pertence à sessão, feche-a para não vazar um descritor.
            if (source.release_fence >= 0) (void)::close(source.release_fence);
            continue;
        }
        aidl_device::StreamBuffer buffer;
        buffer.streamId = streamId;
        buffer.bufferId = bufferId;
        buffer.status = source.status == CAMERA3_BUFFER_STATUS_OK ? aidl_device::BufferStatus::OK
                                                                    : aidl_device::BufferStatus::ERROR;
        if (source.release_fence >= 0)
            buffer.releaseFence.fds.emplace_back(source.release_fence);
        result.outputBuffers.push_back(std::move(buffer));
    }
    if (native->num_output_buffers > 0) {
        for (const auto& skipped : frameworkOnlyBuffers) {
            aidl_device::StreamBuffer buffer;
            buffer.streamId = skipped.streamId;
            buffer.bufferId = skipped.bufferId;
            // The JPEG path already contains the thumbnail. Fill the retained
            // YUV companion with a neutral frame and report it as successful;
            // Samsung Camera requires a real ImageReader image for its
            // thumbnail callback and tears the session down on ERROR_BUFFER.
            buffer.status = buffers_.completeFrameworkOnly(skipped.streamId, skipped.bufferId) ?
                    aidl_device::BufferStatus::OK : aidl_device::BufferStatus::ERROR;
            buffer.acquireFence = {};
            buffer.releaseFence = {};
            result.outputBuffers.push_back(std::move(buffer));
        }
    }
    // Não use FMQ até que a fila e a ordem de escrita estejam implementadas.
    // O retorno Binder preserva metadata e ownership da release fence.
    std::vector<aidl_device::CaptureResult> results;
    results.push_back(std::move(result));
    (void)callback->processCaptureResult(results);
    if (native->num_output_buffers > 0) {
        // Não espere o mutex Binder durante flush. A chamada nativa ainda
        // pode estar usando o array persistente; processCaptureRequest()
        // fará a remoção assim que retornar ao adaptador.
        // Um output concluído é o ponto em que o HAL devolve a posse do
        // request ao bridge. Metadata parcial não libera o slot porque o
        // Bayer correspondente ainda pode estar no ISP/3AA.
        {
            std::scoped_lock sessionLock(mutex_);
            pendingNativeFrames_.erase(native->frame_number);
            pendingCv_.notify_all();
        }
        std::scoped_lock completedLock(completedMutex_);
        completedFrames_.insert(native->frame_number);
    }
}

void CameraSession::handleNotify(const camera3_notify_msg_t* native) {
    std::shared_ptr<aidl_device::ICameraDeviceCallback> callback;
    aidl_device::NotifyMsg message;
    {
        std::scoped_lock lock(mutex_);
        if (closed_ || !callback_) return;
        callback = callback_;
        if (native->type == CAMERA3_MSG_SHUTTER) {
            aidl_device::ShutterMsg shutter;
            shutter.frameNumber = static_cast<int32_t>(native->message.shutter.frame_number);
            shutter.timestamp = static_cast<int64_t>(native->message.shutter.timestamp);
            // Camera3 3.x não expõe readout timestamp nem stream group state.
            shutter.readoutTimestamp = -1;
            message.set<aidl_device::NotifyMsg::Tag::shutter>(std::move(shutter));
        } else if (native->type == CAMERA3_MSG_ERROR) {
            int32_t streamId = -1;
            if (native->message.error.error_stream)
                (void)streams_.idFor(native->message.error.error_stream, &streamId);

            // The Exynos Camera3 backend emits ERROR_BUFFER for the Samsung
            // 512x384 thumbnail companion even when that stream deliberately
            // stays outside its native configure_streams() array.  The bridge
            // retains and completes that framework-side buffer together with
            // the JPEG result.  Forwarding the stale backend notification
            // first makes CameraService abort the otherwise successful photo.
            // Keep this narrowly gated: errors for every native stream still
            // reach the framework unchanged.
            if (native->message.error.error_code == CAMERA3_MSG_ERROR_BUFFER &&
                streamId >= 0 && !streams_.isNativeConfigured(streamId) &&
                !streams_.isNativeCaptureAllowed(streamId) &&
                suppressFrameworkOnlyBufferError()) {
                ALOGI("CameraSession: suppressing backend ERROR_BUFFER for framework-only stream=%d frame=%u",
                      streamId, native->message.error.frame_number);
                return;
            }
            aidl_device::ErrorMsg error;
            error.frameNumber = static_cast<int32_t>(native->message.error.frame_number);
            switch (native->message.error.error_code) {
                case CAMERA3_MSG_ERROR_DEVICE:
                    error.errorCode = aidl_device::ErrorCode::ERROR_DEVICE;
                    break;
                case CAMERA3_MSG_ERROR_REQUEST:
                    error.errorCode = aidl_device::ErrorCode::ERROR_REQUEST;
                    break;
                case CAMERA3_MSG_ERROR_RESULT:
                    error.errorCode = aidl_device::ErrorCode::ERROR_RESULT;
                    break;
                case CAMERA3_MSG_ERROR_BUFFER:
                    error.errorCode = aidl_device::ErrorCode::ERROR_BUFFER;
                    break;
                default:
                    return;  // extensão privada não tem representação AIDL V4.
            }
            error.errorStreamId = streamId;
            message.set<aidl_device::NotifyMsg::Tag::error>(std::move(error));
        } else {
            return;
        }
    }
    (void)callback->notify({std::move(message)});
}

camera3_buffer_request_status_t CameraSession::handleRequestStreamBuffers(
        uint32_t count, const camera3_buffer_request_t* requests, uint32_t* returnedCount,
        camera3_stream_buffer_ret_t* returned) {
    if (returnedCount) *returnedCount = 0;
    if (!requests || !returnedCount || !returned || count == 0) return CAMERA3_BUF_REQ_FAILED_ILLEGAL_ARGUMENTS;
    std::shared_ptr<aidl_device::ICameraDeviceCallback> callback;
    std::vector<aidl_device::BufferRequest> aidlRequests;
    {
        std::scoped_lock lock(mutex_);
        if (closed_ || !callback_) return CAMERA3_BUF_REQ_FAILED_UNKNOWN;
        callback = callback_;
        aidlRequests.reserve(count);
        for (uint32_t index = 0; index < count; ++index) {
            int32_t streamId = -1;
            if (!requests[index].stream || requests[index].num_buffers_requested == 0 ||
                !streams_.idFor(requests[index].stream, &streamId))
                return CAMERA3_BUF_REQ_FAILED_ILLEGAL_ARGUMENTS;
            aidlRequests.push_back({.streamId = streamId,
                                    .numBuffersRequested = static_cast<int32_t>(
                                            requests[index].num_buffers_requested)});
        }
    }
    std::vector<aidl_device::StreamBufferRet> aidlReturned;
    aidl_device::BufferRequestStatus status = aidl_device::BufferRequestStatus::FAILED_UNKNOWN;
    if (!callback->requestStreamBuffers(aidlRequests, &aidlReturned, &status).isOk())
        return CAMERA3_BUF_REQ_FAILED_UNKNOWN;
    const auto mapStatus = [](aidl_device::BufferRequestStatus input) {
        switch (input) {
            case aidl_device::BufferRequestStatus::OK: return CAMERA3_BUF_REQ_OK;
            case aidl_device::BufferRequestStatus::FAILED_PARTIAL: return CAMERA3_BUF_REQ_FAILED_PARTIAL;
            case aidl_device::BufferRequestStatus::FAILED_CONFIGURING: return CAMERA3_BUF_REQ_FAILED_CONFIGURING;
            case aidl_device::BufferRequestStatus::FAILED_ILLEGAL_ARGUMENTS:
                return CAMERA3_BUF_REQ_FAILED_ILLEGAL_ARGUMENTS;
            default: return CAMERA3_BUF_REQ_FAILED_UNKNOWN;
        }
    };
    const camera3_buffer_request_status_t nativeStatus = mapStatus(status);
    if (aidlReturned.size() > count) return CAMERA3_BUF_REQ_FAILED_ILLEGAL_ARGUMENTS;
    for (size_t index = 0; index < aidlReturned.size(); ++index) {
        const auto& source = aidlReturned[index];
        int32_t streamId = -1;
        camera3_stream_t* stream = streams_.find(source.streamId);
        returned[index] = {.stream = stream, .status = CAMERA3_PS_BUF_REQ_UNKNOWN_ERROR,
                           .num_output_buffers = 0, .output_buffers = returned[index].output_buffers};
        if (!stream || !streams_.idFor(stream, &streamId) || !returned[index].output_buffers) continue;
        if (source.val.getTag() == aidl_device::StreamBuffersVal::Tag::error) {
            switch (source.val.get<aidl_device::StreamBuffersVal::Tag::error>()) {
                case aidl_device::StreamBufferRequestError::NO_BUFFER_AVAILABLE:
                    returned[index].status = CAMERA3_PS_BUF_REQ_NO_BUFFER_AVAILABLE; break;
                case aidl_device::StreamBufferRequestError::MAX_BUFFER_EXCEEDED:
                    returned[index].status = CAMERA3_PS_BUF_REQ_MAX_BUFFER_EXCEEDED; break;
                case aidl_device::StreamBufferRequestError::STREAM_DISCONNECTED:
                    returned[index].status = CAMERA3_PS_BUF_REQ_STREAM_DISCONNECTED; break;
                default: break;
            }
            continue;
        }
        const auto& buffers = source.val.get<aidl_device::StreamBuffersVal::Tag::buffers>();
        if (buffers.size() > requests[index].num_buffers_requested) continue;
        bool valid = true;
        for (size_t bufferIndex = 0; bufferIndex < buffers.size(); ++bufferIndex) {
            if (buffers[bufferIndex].streamId != streamId ||
                this->buffers_.acquire(buffers[bufferIndex], stream,
                                       &returned[index].output_buffers[bufferIndex]) != 0) {
                valid = false;
                for (size_t clean = 0; clean < bufferIndex; ++clean)
                    this->buffers_.cancel(returned[index].output_buffers[clean]);
                break;
            }
        }
        if (!valid) continue;
        returned[index].status = CAMERA3_PS_BUF_REQ_OK;
        returned[index].num_output_buffers = static_cast<uint32_t>(buffers.size());
    }
    *returnedCount = static_cast<uint32_t>(aidlReturned.size());
    return nativeStatus;
}

void CameraSession::handleReturnStreamBuffers(
        uint32_t count, const camera3_stream_buffer_t* const* buffers) {
    if (!buffers || count == 0) return;
    std::shared_ptr<aidl_device::ICameraDeviceCallback> callback;
    {
        std::scoped_lock lock(mutex_);
        if (closed_ || !callback_) return;
        callback = callback_;
    }
    std::vector<aidl_device::StreamBuffer> returned;
    returned.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        if (!buffers[index]) continue;
        const camera3_stream_buffer_t& source = *buffers[index];
        int32_t streamId = 0;
        int64_t bufferId = 0;
        if (!buffers_.takeReturned(source, &streamId, &bufferId)) {
            if (source.release_fence >= 0) (void)::close(source.release_fence);
            continue;
        }
        aidl_device::StreamBuffer target;
        target.streamId = streamId;
        target.bufferId = bufferId;
        target.status = source.status == CAMERA3_BUFFER_STATUS_OK ? aidl_device::BufferStatus::OK
                                                                    : aidl_device::BufferStatus::ERROR;
        if (source.release_fence >= 0) target.releaseFence.fds.emplace_back(source.release_fence);
        returned.push_back(std::move(target));
    }
    if (!returned.empty()) (void)callback->returnStreamBuffers(returned);
}

}  // namespace exynos990::camera
