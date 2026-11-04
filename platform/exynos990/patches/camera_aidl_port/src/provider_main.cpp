// SPDX-License-Identifier: Apache-2.0
// Provider AIDL V4 para o backend Camera3 Exynos 990.

#include "camera3_module.h"
#include "camera_device.h"
#include "sigpipe_guard.h"

#include <aidl/android/hardware/camera/common/CameraDeviceStatus.h>
#include <aidl/android/hardware/camera/common/CameraMetadataType.h>
#include <aidl/android/hardware/camera/common/TorchModeStatus.h>
#include <aidl/android/hardware/camera/provider/BnCameraProvider.h>
#include <aidl/vendor/samsung/hardware/camera/provider/BnSehCameraProvider.h>
#include <android/log.h>

#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, "camera_aidl_port", __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, "camera_aidl_port", __VA_ARGS__)

#include <charconv>
#include <cstdint>
#include <array>
#include <memory>
#include <map>
#include <mutex>
#include <signal.h>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace camera_provider = ::aidl::android::hardware::camera::provider;
namespace camera_common = ::aidl::android::hardware::camera::common;
namespace camera_device = ::aidl::android::hardware::camera::device;

extern "C" binder_status_t AServiceManager_addService(AIBinder* binder, const char* instance);
extern "C" void ABinderProcess_setThreadPoolMaxThreadCount(uint32_t num_threads);
extern "C" void ABinderProcess_startThreadPool();
extern "C" void ABinderProcess_joinThreadPool();

namespace {
// AIDL camera device names use the AIDL interface version (1.0).  The
// wrapped native backend remains Camera3/HIDL 3.6 internally, but exposing
// device@3.x here makes CameraProviderManager reject every device because
// major 3 is reserved for HIDL transport.
constexpr std::string_view kDevicePrefix = "device@1.0/internal/";

std::string deviceName(int id) { return std::string(kDevicePrefix) + std::to_string(id); }

// The Samsung camera framework addresses the physical/logical roles with
// aliases (not with the zero-based indices returned by camera_module_t).  The
// original HIDL provider exposed this table; omitting id 20 makes the Samsung
// Camera ask for BACK_SEAMLESS_ZOOM and abort before opening a session.
struct PublicCameraId {
    int publicId;
    int backendId;
    // The high-resolution rear role is not a mere framework alias. The
    // original Samsung HIDL provider accepts 50 as an extra legacy ID and
    // passes that role into SehCameraDevice. Preserve it until Camera3::open.
    bool preserveOpenAlias;
};

constexpr std::array<PublicCameraId, 9> kPublicCameraIds = {{
        {0, 0, false}, {1, 1, false}, {2, 2, false}, {3, 3, false}, {4, 4, false},
        {20, 0, false}, {23, 0, false}, {50, 2, true}, {52, 4, false},
}};

const PublicCameraId* findPublicCameraId(int publicId) {
    for (const auto& entry : kPublicCameraIds) {
        if (entry.publicId == publicId) return &entry;
    }
    return nullptr;
}

const PublicCameraId* findPublicCameraIdForBackend(int backendId) {
    for (const auto& entry : kPublicCameraIds) {
        if (entry.backendId == backendId) return &entry;
    }
    return nullptr;
}

// SehCameraDevice stores the public numeric string, converts it with atoi(),
// and passes that number to CameraModule::getCameraInfo().  The Samsung high
// resolution role therefore needs its own metadata lookup before falling back
// to the physical index.  The fallback is only for a backend that does not
// implement the proprietary public role; it must never replace a successful
// response for id 50.
int getCameraInfoForPublicId(const exynos990::camera::Camera3Module& module,
                             const PublicCameraId& entry, camera_info* info,
                             int* resolvedId) {
    if (!info || !resolvedId) return -EINVAL;
    const int preferredId = entry.preserveOpenAlias || exynos990::camera::nativeLogicalCameraIds()
            ? entry.publicId : entry.backendId;
    int status = module.getCameraInfo(preferredId, info);
    if (status == 0 && info->static_camera_characteristics) {
        *resolvedId = preferredId;
        return 0;
    }

    if (preferredId == entry.backendId) return status;
    *info = {};
    status = module.getCameraInfo(entry.backendId, info);
    if (status == 0 && info->static_camera_characteristics) {
        *resolvedId = entry.backendId;
        ALOGI("CameraProvider: public id=%d has no dedicated metadata; using backend id=%d",
              entry.publicId, entry.backendId);
    }
    return status;
}

bool parseDeviceName(const std::string& name, int* id) {
    if (!id || !name.starts_with(kDevicePrefix)) return false;
    const std::string_view suffix(name.data() + kDevicePrefix.size(),
                                  name.size() - kDevicePrefix.size());
    if (suffix.empty()) return false;
    int parsed = -1;
    const auto [end, error] = std::from_chars(suffix.data(), suffix.data() + suffix.size(), parsed);
    if (error != std::errc{} || end != suffix.data() + suffix.size() || parsed < 0) return false;
    *id = parsed;
    return true;
}

camera_common::CameraDeviceStatus deviceStatus(int status) {
    if (status == CAMERA_DEVICE_STATUS_PRESENT) return camera_common::CameraDeviceStatus::PRESENT;
    if (status == CAMERA_DEVICE_STATUS_ENUMERATING) return camera_common::CameraDeviceStatus::ENUMERATING;
    return camera_common::CameraDeviceStatus::NOT_PRESENT;
}

camera_common::TorchModeStatus torchStatus(int status) {
    if (status == TORCH_MODE_STATUS_AVAILABLE_OFF) return camera_common::TorchModeStatus::AVAILABLE_OFF;
    if (status == TORCH_MODE_STATUS_AVAILABLE_ON) return camera_common::TorchModeStatus::AVAILABLE_ON;
    return camera_common::TorchModeStatus::NOT_AVAILABLE;
}

// Extension Samsung do ICameraProvider. getCameraIdList já expõe todos os IDs
// públicos que o provider HIDL do S20+ publicava, então getCameraIdListAll
// devolve a mesma lista validada.
class SehCameraProviderExtension final
    : public ::aidl::vendor::samsung::hardware::camera::provider::BnSehCameraProvider {
  public:
    explicit SehCameraProviderExtension(std::weak_ptr<camera_provider::ICameraProvider> provider)
        : provider_(std::move(provider)) {}

    ndk::ScopedAStatus getCameraIdListAll(std::vector<std::string>* cameraIds) override {
        const auto provider = provider_.lock();
        if (!provider) return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        return provider->getCameraIdList(cameraIds);
    }

  private:
    std::weak_ptr<camera_provider::ICameraProvider> provider_;
};

class Exynos990CameraProvider final : public camera_provider::BnCameraProvider {
  public:
    Exynos990CameraProvider() : module_(std::make_shared<exynos990::camera::Camera3Module>()) {
        if (!module_->valid()) return;
        module_->setCallbacks(
                [this](int id, int status) { onDeviceStatus(id, status); },
                [this](const std::string& id, int status) { onTorchStatus(id, status); });
    }

    ndk::ScopedAStatus setCallback(
            const std::shared_ptr<camera_provider::ICameraProviderCallback>& callback) override {
        if (!callback || !module_->valid())
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        {
            std::scoped_lock lock(mutex_);
            callback_ = callback;
        }
        // O provider AIDL V1 do A26 cria o backend, registra o callback e
        // dispara os callbacks que ficaram pendentes antes de o framework se
        // conectar. camera_module_t não tem um equivalente para essa última
        // operação. Reproduzimos somente sua semântica pública: anunciar cada
        // câmera fixa, validada por get_camera_info(), como PRESENT depois que
        // o callback existe. Não sintetizamos IDs, capacidades ou eventos de
        // hotplug.
        publishPresentDevices(callback);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getVendorTags(std::vector<camera_common::VendorTagSection>* tags) override {
        if (!tags) return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        tags->clear();
        vendor_tag_ops_t ops{};
        if (!module_->getVendorTagOps(&ops)) return ndk::ScopedAStatus::ok();
        const int count = ops.get_tag_count(&ops);
        if (count < 0 || count > 65536) return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        std::vector<uint32_t> rawTags(static_cast<size_t>(count));
        if (!rawTags.empty()) ops.get_all_tags(&ops, rawTags.data());
        std::map<std::string, camera_common::VendorTagSection> sections;
        for (const uint32_t tagId : rawTags) {
            const char* section = ops.get_section_name(&ops, tagId);
            const char* name = ops.get_tag_name(&ops, tagId);
            const int type = ops.get_tag_type(&ops, tagId);
            if (!section || !name || type < TYPE_BYTE || type > TYPE_RATIONAL) continue;
            auto& target = sections[section];
            target.sectionName = section;
            camera_common::VendorTag tag;
            tag.tagId = static_cast<int32_t>(tagId);
            tag.tagName = name;
            tag.tagType = static_cast<camera_common::CameraMetadataType>(type);
            target.tags.push_back(std::move(tag));
        }
        tags->reserve(sections.size());
        for (auto& [_, section] : sections) tags->push_back(std::move(section));
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getCameraIdList(std::vector<std::string>* cameraIds) override {
        if (!cameraIds || !module_->valid())
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
        cameraIds->clear();
        for (const auto& entry : availablePublicCameraIds())
            cameraIds->push_back(deviceName(entry.publicId));
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getCameraDeviceInterface(
            const std::string& name, std::shared_ptr<camera_device::ICameraDevice>* device) override {
        ALOGI("CameraProvider: getCameraDeviceInterface name=%s", name.c_str());
        if (!device) return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        device->reset();
        int publicId = -1;
        camera_info info{};
        const PublicCameraId* mapping = nullptr;
        if (parseDeviceName(name, &publicId)) mapping = findPublicCameraId(publicId);
        int metadataId = -1;
        const int infoStatus = mapping
                ? getCameraInfoForPublicId(*module_, *mapping, &info, &metadataId)
                : -EINVAL;
        if (!module_->valid() || infoStatus != 0 || !info.static_camera_characteristics) {
            ALOGE("CameraProvider: rejecting device name=%s id=%d info_status=%d chars=%p", name.c_str(),
                  publicId, infoStatus, info.static_camera_characteristics);
            return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        }
        const bool openPublicId = mapping->preserveOpenAlias || metadataId == mapping->publicId;
        const std::string openId = openPublicId ? std::to_string(mapping->publicId) :
                                                  std::to_string(mapping->backendId);
        *device = ndk::SharedRefBase::make<exynos990::camera::CameraDevice>(
                module_, metadataId, publicId, openId);
        ALOGI("CameraProvider: returned public_id=%d backend_id=%d metadata_id=%d open_id=%s",
              publicId, mapping->backendId, metadataId, openId.c_str());
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus notifyDeviceStateChange(int64_t state) override {
        return module_->setDeviceState(static_cast<uint64_t>(state)) == 0
                ? ndk::ScopedAStatus::ok()
                : ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
    }

    ndk::ScopedAStatus getConcurrentCameraIds(
            std::vector<camera_provider::ConcurrentCameraIdCombination>* combinations) override {
        if (!combinations) return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        combinations->clear();
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus isConcurrentStreamCombinationSupported(
            const std::vector<camera_provider::CameraIdAndStreamCombination>&, bool* supported) override {
        if (!supported) return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
        *supported = false;
        return ndk::ScopedAStatus::ok();
    }

  private:
    std::vector<PublicCameraId> availablePublicCameraIds() const {
        std::vector<PublicCameraId> available;
        if (!module_ || !module_->valid()) return available;
        const int count = module_->numberOfCameras();
        ALOGI("CameraProvider: backend_count=%d public_count=%zu", count,
              kPublicCameraIds.size());
        if (count < 0) return available;
        for (const auto& entry : kPublicCameraIds) {
            if (entry.backendId < 0 || entry.backendId >= count) continue;
            camera_info info{};
            int metadataId = -1;
            if (getCameraInfoForPublicId(*module_, entry, &info, &metadataId) == 0 &&
                info.static_camera_characteristics) {
                available.push_back(entry);
            } else {
                ALOGE("CameraProvider: public camera id=%d backend=%d rejected by getCameraInfo",
                      entry.publicId, entry.backendId);
            }
        }
        return available;
    }

    void publishPresentDevices(
            const std::shared_ptr<camera_provider::ICameraProviderCallback>& callback) const {
        if (!callback) return;
        for (const auto& entry : availablePublicCameraIds()) {
            const auto status = callback->cameraDeviceStatusChange(
                    deviceName(entry.publicId), camera_common::CameraDeviceStatus::PRESENT);
            if (!status.isOk()) {
                ALOGE("CameraProvider: failed to publish PRESENT public_id=%d backend_id=%d",
                      entry.publicId, entry.backendId);
            }
        }
    }

    void onDeviceStatus(int id, int status) {
        // Os sensores do Exynos 990 são integrados ao aparelho e não são
        // hot-pluggable. O módulo Camera3 legado emite NOT_PRESENT durante
        // a transição de ownership (principalmente quando uma sessão abre),
        // mas isso não significa que a câmera deixou de existir. Repassar
        // esse evento para CameraProviderManager faz o framework remover
        // todas as câmeras e deixa o provider sem dispositivos publicados.
        // O wrapper HIDL original filtrava essa transição implicitamente;
        // manter o mesmo contrato no provider AIDL evita a remoção espúria.
        if (status == CAMERA_DEVICE_STATUS_NOT_PRESENT) {
            ALOGI("CameraProvider: ignoring transient NOT_PRESENT for fixed camera id=%d", id);
            return;
        }
        std::shared_ptr<camera_provider::ICameraProviderCallback> callback;
        { std::scoped_lock lock(mutex_); callback = callback_; }
        if (!callback) return;
        for (const auto& entry : kPublicCameraIds) {
            if (entry.backendId == id) {
                (void)callback->cameraDeviceStatusChange(deviceName(entry.publicId),
                                                         deviceStatus(status));
            }
        }
    }

    void onTorchStatus(const std::string& id, int status) {
        int numericId = -1;
        const auto [end, error] = std::from_chars(id.data(), id.data() + id.size(), numericId);
        if (error != std::errc{} || end != id.data() + id.size() || numericId < 0) return;
        std::shared_ptr<camera_provider::ICameraProviderCallback> callback;
        { std::scoped_lock lock(mutex_); callback = callback_; }
        if (!callback) return;
        for (const auto& entry : kPublicCameraIds) {
            if (entry.backendId == numericId) {
                (void)callback->torchModeStatusChange(deviceName(entry.publicId), torchStatus(status));
            }
        }
    }

    std::shared_ptr<exynos990::camera::Camera3Module> module_;
    std::mutex mutex_;
    std::shared_ptr<camera_provider::ICameraProviderCallback> callback_;
    std::shared_ptr<SehCameraProviderExtension> sehExtension_;

  protected:
    // asBinder() mantém o AIBinder apenas por referência fraca; anexe a
    // extension a cada binder criado, antes de ele chegar ao servicemanager.
    ndk::SpAIBinder createBinder() override {
        ndk::SpAIBinder binder = camera_provider::BnCameraProvider::createBinder();
        if (!sehExtension_) {
            sehExtension_ = ndk::SharedRefBase::make<SehCameraProviderExtension>(
                    ref<camera_provider::ICameraProvider>());
        }
        const binder_status_t status =
                AIBinder_setExtension(binder.get(), sehExtension_->asBinder().get());
        ALOGI("CameraProvider: ISehCameraProvider extension status=%d", status);
        return binder;
    }
};
}  // namespace

int main() {
    // O backend Camera3 Exynos usa IPC auxiliar (incluindo SecCameraIPCtoRIL)
    // durante camera3_module_t::open(). Se o endpoint remoto fechar o pipe,
    // o comportamento padrão de SIGPIPE mata o provider AIDL inteiro antes
    // que o HAL possa devolver o erro ao framework. Serviços binder devem
    // ignorar SIGPIPE e tratar EPIPE no caminho de retorno.
    exynos990::camera::protectNativeIpcFromSigpipe();
    ALOGI("CameraProvider: SIGPIPE ignored and blocked for native Camera3 IPC");
    ABinderProcess_setThreadPoolMaxThreadCount(4);
    // Only setting the maximum does not start the NDK pool.  Start it before
    // publishing the service so cameraserver never blocks in fromBinder()
    // behind the provider's sole thread.
    ABinderProcess_startThreadPool();
    auto service = ndk::SharedRefBase::make<Exynos990CameraProvider>();
    const std::string instance = std::string(camera_provider::ICameraProvider::descriptor) + "/internal/0";
    if (AServiceManager_addService(service->asBinder().get(), instance.c_str()) != STATUS_OK) return 1;
    ABinderProcess_joinThreadPool();
    return 1;
}
