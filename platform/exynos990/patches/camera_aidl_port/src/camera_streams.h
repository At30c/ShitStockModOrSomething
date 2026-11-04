#pragma once

#include <aidl/android/hardware/camera/device/HalStream.h>
#include <aidl/android/hardware/camera/device/StreamConfiguration.h>
#include <hardware/camera3.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace exynos990::camera {

// The Exynos 990 Samsung Camera3 blob was built against its vendor camera3
// header, where usage is uint64_t. Android 17's public camera3.h uses a
// uint32_t usage field, shifting data_space/rotation/physical_camera_id by
// four bytes. Keep this ABI shim local to the adapter; AIDL remains the public
// contract and buffer code only receives opaque stream pointers.
struct SamsungCamera3Stream final {
    int stream_type = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    int format = 0;
    uint64_t usage = 0;
    uint32_t max_buffers = 0;
    void* priv = nullptr;
    android_dataspace_t data_space = HAL_DATASPACE_UNKNOWN;
    int rotation = CAMERA3_STREAM_ROTATION_0;
    const char* physical_camera_id = nullptr;
    void* reserved[6] = {};
    // Android's public camera3_stream_t ends at reserved[6]. Samsung's
    // vendor Camera3Stream wrapper appends mId at +0x68 and the proprietary
    // Exynos HAL reads it during stream enumeration. The Samsung HIDL wrapper
    // allocates a 0x98-byte Camera3Stream object and clears the private tail
    // before passing it to camera.exynos990.so. Keep the same zeroed tail in
    // this adapter; it is not part of the public AIDL contract, but the HAL
    // can access it while configuring buffers and crop state.
    int32_t id = -1;
    std::uint8_t samsung_private_tail[0x98 - 0x6c] = {};
};

static_assert(offsetof(SamsungCamera3Stream, usage) == 0x10);
static_assert(offsetof(SamsungCamera3Stream, data_space) == 0x28);
static_assert(offsetof(SamsungCamera3Stream, rotation) == 0x2c);
static_assert(offsetof(SamsungCamera3Stream, physical_camera_id) == 0x30);
static_assert(offsetof(SamsungCamera3Stream, id) == 0x68);
static_assert(sizeof(SamsungCamera3Stream) == 0x98);

// Mantém camera3_stream_t vivo enquanto o HAL possuir o stream configurado.
class Camera3Streams final {
  public:
    int configure(camera3_device_t* device,
                  const ::aidl::android::hardware::camera::device::StreamConfiguration& input,
                  std::vector<::aidl::android::hardware::camera::device::HalStream>* output);
    // Retorna o stream nativo pertencente ao id AIDL. O endereço permanece
    // estável até a próxima configureStreams()/clear().
    camera3_stream_t* find(int32_t streamId);
    bool idFor(const camera3_stream_t* stream, int32_t* streamId) const;
    // Streams que ficaram somente no lado AIDL quando o teste de compatibilidade
    // remove os YUV de alta resolução não podem ser enviados ao HAL Exynos.
    bool isNativeConfigured(int32_t streamId) const;
    // A Samsung configures the thumbnail as an extra stream while keeping it
    // out of the native configure_streams() array. It is nevertheless valid
    // to submit its framework buffer on a still request once the extra-stream
    // bridge is enabled.
    bool isNativeCaptureAllowed(int32_t streamId) const;
    // AIDL pairs signalStreamFlush() to a configureStreams() generation.  The
    // legacy Camera3 ABI lacks that field, so keep it in the adapter and
    // suppress stale flush calls before they reach the S20+ HAL.
    bool isStaleFlush(int32_t streamConfigCounter) const;
    void clear();

  private:
    std::vector<SamsungCamera3Stream> streams_;
    std::vector<camera3_stream_t*> pointers_;
    std::vector<std::string> physicalIds_;
    std::vector<int32_t> ids_;
    std::vector<int64_t> useCases_;
    std::vector<bool> nativeConfigured_;
    // O wrapper HIDL Samsung mantém a configuração enquanto a sessão está
    // ativa. Alguns caminhos de vídeo do blob consultam session_parameters
    // depois de configure_streams(), embora a API Camera3 pública só exija
    // validade durante a chamada. Reter a cópia alinhada evita que esse
    // backend proprietário mantenha um ponteiro para memória já liberada.
    camera_metadata_t* sessionParameters_ = nullptr;
    int32_t streamConfigCounter_ = -1;
};

}  // namespace exynos990::camera
