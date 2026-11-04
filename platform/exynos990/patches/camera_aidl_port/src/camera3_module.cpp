#include "camera3_module.h"
#include "sigpipe_guard.h"

#include <hardware/hardware.h>
#include <android/log.h>
#include <system/camera_metadata.h>
#include <camera_metadata_hidden.h>

#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, "camera_aidl_port", __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, "camera_aidl_port", __VA_ARGS__)

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace exynos990::camera {
namespace {

// camera_module_callbacks_t não carrega contexto. Há um único provider por
// processo, logo o wrapper mantém explicitamente esse único destino e limpa a
// referência antes de sua destruição.
std::atomic<Camera3Module*> gModule{nullptr};
std::mutex gCharacteristicsMutex;
std::unordered_map<int, camera_metadata_t*> gAugmentedCharacteristics;

void exposeAndroid17ColorSpaceProfiles(int cameraId, camera_info* info) {
    if (!info || !info->static_camera_characteristics) return;
    std::scoped_lock lock(gCharacteristicsMutex);
    auto cached = gAugmentedCharacteristics.find(cameraId);
    if (cached != gAugmentedCharacteristics.end()) {
        info->static_camera_characteristics = cached->second;
        return;
    }

    constexpr uint32_t kColorSpaceMap = ANDROID_REQUEST_AVAILABLE_COLOR_SPACE_PROFILES_MAP;
    camera_metadata_entry capabilities{};
    camera_metadata_entry colorSpaceMap{};
    const int hasCapabilities = find_camera_metadata_entry(
            const_cast<camera_metadata_t*>(info->static_camera_characteristics),
            ANDROID_REQUEST_AVAILABLE_CAPABILITIES, &capabilities);
    const int hasColorSpaceMap = find_camera_metadata_entry(
            const_cast<camera_metadata_t*>(info->static_camera_characteristics), kColorSpaceMap,
            &colorSpaceMap);
    std::vector<uint8_t> capabilityValues;
    if (hasCapabilities == 0 && capabilities.type == TYPE_BYTE) {
        capabilityValues.assign(capabilities.data.u8,
                                capabilities.data.u8 + capabilities.count);
    }
    if (std::find(capabilityValues.begin(), capabilityValues.end(),
                  static_cast<uint8_t>(ANDROID_REQUEST_AVAILABLE_CAPABILITIES_COLOR_SPACE_PROFILES))
            == capabilityValues.end()) {
        capabilityValues.push_back(
                static_cast<uint8_t>(ANDROID_REQUEST_AVAILABLE_CAPABILITIES_COLOR_SPACE_PROFILES));
    }
    const bool addMap = hasColorSpaceMap != 0;
    if (hasCapabilities == 0 && hasColorSpaceMap == 0 &&
        capabilityValues.size() == capabilities.count) {
        // The metadata already advertises both Android 17 contracts.
        gAugmentedCharacteristics.emplace(cameraId,
                                          const_cast<camera_metadata_t*>(
                                                  info->static_camera_characteristics));
        return;
    }

    const size_t extraEntries = (hasCapabilities == 0 ? 0 : 1) + (addMap ? 1 : 0);
    const size_t extraData = calculate_camera_metadata_entry_data_size(TYPE_BYTE,
                                                                        capabilityValues.size()) +
            (addMap ? calculate_camera_metadata_entry_data_size(TYPE_INT64, 3) : 0);
    camera_metadata_t* augmented = allocate_camera_metadata(
            get_camera_metadata_entry_count(info->static_camera_characteristics) + extraEntries,
            get_camera_metadata_data_count(info->static_camera_characteristics) + extraData);
    if (!augmented || append_camera_metadata(augmented, info->static_camera_characteristics) != 0) {
        if (augmented) free_camera_metadata(augmented);
        return;
    }
    int status = 0;
    if (hasCapabilities == 0) {
        status = add_camera_metadata_entry(augmented, ANDROID_REQUEST_AVAILABLE_CAPABILITIES,
                                           capabilityValues.data(), capabilityValues.size());
    } else {
        status = update_camera_metadata_entry(augmented, capabilities.index,
                                              capabilityValues.data(), capabilityValues.size(),
                                              nullptr);
    }
    if (status == 0 && addMap) {
        const int64_t profile[3] = {ANDROID_REQUEST_AVAILABLE_COLOR_SPACE_PROFILES_MAP_SRGB,
                                    HAL_PIXEL_FORMAT_IMPLEMENTATION_DEFINED, 1};
        status = add_camera_metadata_entry(augmented, kColorSpaceMap, profile, 3);
    }
    if (status != 0) {
        free_camera_metadata(augmented);
        return;
    }
    gAugmentedCharacteristics.emplace(cameraId, augmented);
    info->static_camera_characteristics = augmented;
}

}  // namespace

Camera3Module::Camera3Module() {
    const hw_module_t* raw = nullptr;
    const int loadStatus = hw_get_module(CAMERA_HARDWARE_MODULE_ID, &raw);
    if (loadStatus != 0 || !raw) {
        ALOGE("Camera3Module: hw_get_module(camera) failed status=%d raw=%p", loadStatus, raw);
        return;
    }
    module_ = reinterpret_cast<const camera_module_t*>(raw);
    ALOGI("Camera3Module: loaded module=%p module_api=0x%x hal_api=0x%x", module_,
          module_->common.module_api_version, module_->common.hal_api_version);
    callbacks_.camera_device_status_change = &Camera3Module::onDeviceStatus;
    callbacks_.torch_mode_status_change = &Camera3Module::onTorchStatus;
    if (getVendorTagOps(&metadataVendorOps_)) {
        // add_camera_metadata_entry() rejects vendor tags unless the process
        // installs the same query table used to publish them through AIDL.
        const int vendorOpsStatus = set_camera_metadata_vendor_ops(&metadataVendorOps_);
        ALOGI("Camera3Module: installed metadata vendor ops status=%d", vendorOpsStatus);
    }
    gModule.store(this, std::memory_order_release);
    if (module_->set_callbacks) {
        const int callbackStatus = module_->set_callbacks(&callbacks_);
        ALOGI("Camera3Module: set_callbacks status=%d", callbackStatus);
    }
}

Camera3Module::~Camera3Module() {
    Camera3Module* expected = this;
    (void)gModule.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
}

bool Camera3Module::valid() const {
    return module_ && module_->get_number_of_cameras && module_->get_camera_info &&
            module_->common.methods && module_->common.methods->open;
}

int Camera3Module::numberOfCameras() const {
    if (!valid()) {
        ALOGE("Camera3Module: invalid module while enumerating cameras");
        return -ENODEV;
    }
    const int count = module_->get_number_of_cameras();
    ALOGI("Camera3Module: get_number_of_cameras=%d", count);
    return count;
}

int Camera3Module::getCameraInfo(int cameraId, camera_info* info) const {
    if (!valid() || !info) return -EINVAL;
    const int status = module_->get_camera_info(cameraId, info);
    ALOGI("Camera3Module: get_camera_info id=%d status=%d chars=%p", cameraId, status,
          info->static_camera_characteristics);
    return status;
}

int Camera3Module::setDeviceState(uint64_t state) const {
    if (module_ && module_->notify_device_state_change) {
        module_->notify_device_state_change(state);
    }
    return 0;
}

int Camera3Module::setTorchMode(const std::string& cameraId, bool enabled) const {
    const int result = module_ && module_->set_torch_mode ?
            module_->set_torch_mode(cameraId.c_str(), enabled) : -ENOSYS;
    if (result == 0) {
        std::scoped_lock lock(mutex_);
        torchLevels_[cameraId] = kTorchStrengthDefaultLevel;
    }
    return result;
}

int Camera3Module::setTorchModeStrength(const std::string& cameraId, int32_t level) const {
    static_assert(offsetof(camera_module_t, reserved) == 0x148,
                  "Samsung set_torch_mode_strength slot");
    if (level < 1 || level > kTorchStrengthMaximumLevel) return -EINVAL;
    using SetTorchModeStrength = int (*)(const char*, bool, int);
    const auto setStrength = module_ ?
            reinterpret_cast<SetTorchModeStrength>(module_->reserved[0]) : nullptr;
    if (!setStrength) return -ENOSYS;
    const int result = setStrength(cameraId.c_str(), true, level);
    ALOGI("Camera3Module: set_torch_mode_strength id=%s level=%d result=%d", cameraId.c_str(),
          level, result);
    if (result == 0) {
        std::scoped_lock lock(mutex_);
        torchLevels_[cameraId] = level;
    }
    return result;
}

int32_t Camera3Module::torchStrengthLevel(const std::string& cameraId) const {
    std::scoped_lock lock(mutex_);
    const auto it = torchLevels_.find(cameraId);
    return it == torchLevels_.end() ? kTorchStrengthDefaultLevel : it->second;
}

bool Camera3Module::getVendorTagOps(vendor_tag_ops_t* ops) const {
    if (!ops) return false;
    *ops = {};
    if (!module_ || !module_->get_vendor_tag_ops) return false;
    module_->get_vendor_tag_ops(ops);
    return ops->get_tag_count && ops->get_all_tags && ops->get_section_name &&
            ops->get_tag_name && ops->get_tag_type;
}

int Camera3Module::open(const std::string& cameraId, camera3_device_t** device) const {
    protectNativeIpcFromSigpipe();
    if (device) *device = nullptr;
    if (!valid() || !device || cameraId.empty()) return -EINVAL;
    hw_device_t* raw = nullptr;
    const int status = module_->common.methods->open(&module_->common, cameraId.c_str(), &raw);
    ALOGI("Camera3Module: open id=%s status=%d raw=%p", cameraId.c_str(), status, raw);
    if (status != 0 || !raw) return status != 0 ? status : -ENODEV;
    if (raw->version < CAMERA_DEVICE_API_VERSION_3_2) {
        if (raw->close) (void)raw->close(raw);
        return -ENOSYS;
    }
    ALOGI("Camera3Module: opened id=%s device_version=0x%x", cameraId.c_str(), raw->version);
    *device = reinterpret_cast<camera3_device_t*>(raw);
    return 0;
}

int Camera3Module::close(camera3_device_t* device) const {
    protectNativeIpcFromSigpipe();
    return device && device->common.close ? device->common.close(&device->common) : -EINVAL;
}

void Camera3Module::setCallbacks(DeviceStatusCallback device, TorchStatusCallback torch) {
    std::scoped_lock lock(mutex_);
    deviceStatus_ = std::move(device);
    torchStatus_ = std::move(torch);
}

void Camera3Module::onDeviceStatus(const camera_module_callbacks_t*, int cameraId, int status) {
    Camera3Module* module = gModule.load(std::memory_order_acquire);
    if (!module) return;
    std::scoped_lock lock(module->mutex_);
    if (module->deviceStatus_) module->deviceStatus_(cameraId, status);
}

void Camera3Module::onTorchStatus(const camera_module_callbacks_t*, const char* cameraId,
                                  int status) {
    Camera3Module* module = gModule.load(std::memory_order_acquire);
    if (!module || !cameraId) return;
    std::scoped_lock lock(module->mutex_);
    if (module->torchStatus_) module->torchStatus_(cameraId, status);
}

}  // namespace exynos990::camera
