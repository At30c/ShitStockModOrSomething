#pragma once

// Wrapper do módulo Camera3 físico. Esta camada nunca usa o provider HIDL:
// ela fala diretamente com camera.exynos990.so via camera_module_t.

#include <hardware/camera3.h>
#include <sys/system_properties.h>

#include <charconv>
#include <cstring>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace exynos990::camera {

// SehCameraDevice (HIDL) converte o ID público com atoi() e o usa tanto em
// get_camera_info() quanto em open(); IDs lógicos como 20 recebem do próprio
// HAL a metadata multi-câmera. Este modo reproduz esse contrato em vez de
// remapear o ID para um backend físico e sintetizar a metadata lógica.
inline bool nativeLogicalCameraIds() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get("vendor.camera.aidl.native_logical_ids", value);
    return length > 0 && std::strcmp(value, "1") == 0;
}

inline bool parseNumericCameraId(const std::string& id, int* output) {
    if (id.empty() || !output) return false;
    int parsed = -1;
    const auto [end, error] = std::from_chars(id.data(), id.data() + id.size(), parsed);
    if (error != std::errc{} || end != id.data() + id.size() || parsed < 0) return false;
    *output = parsed;
    return true;
}

// Lanterna do y2s: o slot Samsung camera_module_t::reserved[0] (+0x148) é o
// set_torch_mode_strength usado pelo sehSetTorchModeStrength do HIDL. O HAL
// grava 1001/1002/1004/1006/1009 em /sys/class/camera/flash/rear_flash
// (60/100/120/160/200 mA pela torch_table do DT); set_torch_mode() comum
// grava "1", que o driver s2mpb02 acende com os mesmos 60 mA do nível 1.
constexpr int32_t kTorchStrengthMaximumLevel = 5;
constexpr int32_t kTorchStrengthDefaultLevel = 1;

class Camera3Module final {
  public:
    using DeviceStatusCallback = std::function<void(int cameraId, int status)>;
    using TorchStatusCallback = std::function<void(const std::string& cameraId, int status)>;

    Camera3Module();
    ~Camera3Module();
    Camera3Module(const Camera3Module&) = delete;
    Camera3Module& operator=(const Camera3Module&) = delete;

    bool valid() const;
    int numberOfCameras() const;
    int getCameraInfo(int cameraId, camera_info* info) const;
    int setDeviceState(uint64_t state) const;
    int setTorchMode(const std::string& cameraId, bool enabled) const;
    int setTorchModeStrength(const std::string& cameraId, int32_t level) const;
    int32_t torchStrengthLevel(const std::string& cameraId) const;
    bool getVendorTagOps(vendor_tag_ops_t* ops) const;
    // The Samsung module has public role aliases (for example 50 for the
    // high-resolution rear path) in addition to its compact physical index.
    // Keep the open name textual so an AIDL provider does not erase that
    // selection before the proprietary backend sees it.
    int open(const std::string& cameraId, camera3_device_t** device) const;
    int close(camera3_device_t* device) const;

    void setCallbacks(DeviceStatusCallback device, TorchStatusCallback torch);

  private:
    static void onDeviceStatus(const camera_module_callbacks_t*, int cameraId, int status);
    static void onTorchStatus(const camera_module_callbacks_t*, const char* cameraId, int status);

    const camera_module_t* module_ = nullptr;
    camera_module_callbacks_t callbacks_{};
    // camera_metadata_t precisa conhecer os vendor tags quando o adaptador
    // acrescenta entradas Samsung às características estáticas. A cópia fica
    // no objeto que vive durante todo o provider, nunca em uma variável local.
    vendor_tag_ops_t metadataVendorOps_{};
    mutable std::mutex mutex_;
    mutable std::map<std::string, int32_t> torchLevels_;
    DeviceStatusCallback deviceStatus_;
    TorchStatusCallback torchStatus_;
};

}  // namespace exynos990::camera
