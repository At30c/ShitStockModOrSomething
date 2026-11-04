#pragma once

#include "camera3_module.h"

#include <aidl/android/hardware/camera/device/BnCameraDevice.h>

#include <memory>
#include <string>

namespace exynos990::camera {

// Implementação AIDL V4 do device. Ela não anuncia capacidades sintéticas:
// metadata, custo e torch são sempre repassados do módulo Exynos original.
class CameraDevice final : public ::aidl::android::hardware::camera::device::BnCameraDevice {
  public:
    CameraDevice(std::shared_ptr<Camera3Module> module, int cameraId, int publicId,
                 std::string openId);

    ::ndk::ScopedAStatus getCameraCharacteristics(
        ::aidl::android::hardware::camera::device::CameraMetadata* output) override;
    ::ndk::ScopedAStatus getPhysicalCameraCharacteristics(
        const std::string& physicalId,
        ::aidl::android::hardware::camera::device::CameraMetadata* output) override;
    ::ndk::ScopedAStatus getResourceCost(
        ::aidl::android::hardware::camera::common::CameraResourceCost* output) override;
    ::ndk::ScopedAStatus isStreamCombinationSupported(
        const ::aidl::android::hardware::camera::device::StreamConfiguration& configuration,
        bool* supported) override;
    ::ndk::ScopedAStatus open(
        const std::shared_ptr<::aidl::android::hardware::camera::device::ICameraDeviceCallback>& callback,
        std::shared_ptr<::aidl::android::hardware::camera::device::ICameraDeviceSession>* output) override;
    ::ndk::ScopedAStatus openInjectionSession(
        const std::shared_ptr<::aidl::android::hardware::camera::device::ICameraDeviceCallback>& callback,
        std::shared_ptr<::aidl::android::hardware::camera::device::ICameraInjectionSession>* output) override;
    ::ndk::ScopedAStatus setTorchMode(bool enabled) override;
    ::ndk::ScopedAStatus turnOnTorchWithStrengthLevel(int32_t level) override;
    ::ndk::ScopedAStatus getTorchStrengthLevel(int32_t* output) override;
    ::ndk::ScopedAStatus constructDefaultRequestSettings(
        ::aidl::android::hardware::camera::device::RequestTemplate type,
        ::aidl::android::hardware::camera::device::CameraMetadata* output) override;
    ::ndk::ScopedAStatus isStreamCombinationWithSettingsSupported(
        const ::aidl::android::hardware::camera::device::StreamConfiguration& configuration,
        bool* supported) override;
    ::ndk::ScopedAStatus getSessionCharacteristics(
        const ::aidl::android::hardware::camera::device::StreamConfiguration& configuration,
        ::aidl::android::hardware::camera::device::CameraMetadata* output) override;
    ::ndk::ScopedAStatus warmUp() override;

  private:
    int info(camera_info* output) const;
    static ::ndk::ScopedAStatus unsupported(const char* operation);
    std::shared_ptr<Camera3Module> module_;
    int cameraId_;
    int publicId_;
    std::string openId_;
};

}  // namespace exynos990::camera
