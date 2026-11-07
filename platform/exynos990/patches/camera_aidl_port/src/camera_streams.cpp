#include "camera_streams.h"

#include <android/log.h>
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <inttypes.h>
#include <limits>
#include <unordered_set>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>
#include <sys/system_properties.h>
#include <system/camera_metadata.h>

#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, "camera_aidl_port", __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, "camera_aidl_port", __VA_ARGS__)

namespace exynos990::camera {
namespace aidl_device = ::aidl::android::hardware::camera::device;
namespace aidl_graphics = ::aidl::android::hardware::graphics::common;

namespace {

// Camera3's public contract uses a non-null pointer to a zero-length string
// for streams without a physical-camera association. The AIDL contract uses
// an empty String, so retain a stable zero-length C string at the ABI boundary.
constexpr char kEmptyPhysicalCameraId[] = "";
constexpr int64_t kStandardDynamicRangeProfile =
        ANDROID_REQUEST_AVAILABLE_DYNAMIC_RANGE_PROFILES_MAP_STANDARD;
constexpr int64_t kDefaultStreamUseCase =
        ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_DEFAULT;
constexpr int64_t kVendorStreamUseCaseStart =
        ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_VENDOR_START;
constexpr int32_t kColorSpaceUnspecified =
        ANDROID_REQUEST_AVAILABLE_COLOR_SPACE_PROFILES_MAP_UNSPECIFIED;

// These are the only public sensor pixel modes in Android 17's frozen Camera
// metadata contract.  Values outside this set cannot be represented by the
// legacy Camera3 ABI used by the Samsung backend.
bool validSensorPixelMode(int32_t mode) {
    return mode == ANDROID_SENSOR_PIXEL_MODE_DEFAULT ||
            mode == ANDROID_SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION;
}

bool validStreamUseCase(int64_t useCase) {
    // The frozen AIDL enum contains the standard values 0..6 and reserves
    // 0x10000 and above for vendor-defined values.  Do not silently truncate
    // an arbitrary long into the vendor's 32-bit private stream option.
    return (useCase >= ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_DEFAULT &&
            useCase <= ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_CROPPED_RAW) ||
            useCase >= kVendorStreamUseCaseStart;
}

// Samsung's HIDL adapter stores a 32-bit stream option in SehStream and
// converts it to the public use-case value with (option << 16).  The Android
// framework exposes the resulting value through AIDL Stream.useCase.  Reverse
// that exact transformation only for values representable by the vendor ABI;
// never truncate an arbitrary AIDL long.
bool mapSamsungStreamOption(int64_t useCase, uint32_t* option) {
    if (!option || useCase < 0) return false;
    if (useCase == kDefaultStreamUseCase) {
        *option = 0;
        return true;
    }
    if (useCase <= ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_CROPPED_RAW) {
        *option = static_cast<uint32_t>(useCase);
        return true;
    }
    if (useCase < kVendorStreamUseCaseStart || (useCase & 0xffff) != 0) return false;
    const uint64_t shifted = static_cast<uint64_t>(useCase) >> 16;
    if (shifted > std::numeric_limits<uint32_t>::max()) return false;
    *option = static_cast<uint32_t>(shifted);
    return true;
}

bool copyPrivateUseCaseForHidlCompat() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get("vendor.camera.aidl.private_usecase", value);
    // The stock Samsung HIDL adapter always copies SehStream.useCase into
    // the vendor Camera3Stream option word. Keep an explicit opt-out for
    // diagnostics, but make that compatibility path the default for AIDL.
    return length == 0 || std::strcmp(value, "0") != 0;
}

bool truncateNativeStreamSetForTest() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get("vendor.camera.aidl.native_preview_jpeg_only", value);
    return length > 0 && std::strcmp(value, "1") == 0;
}

// The Exynos 990 vendor manager has six physical YUV ports (0..5).  Samsung's
// HIDL wrapper does not pass the high-resolution YUV/thumbnail companion
// streams through the native configure call; it keeps them as framework-side
// streams and creates them only when a still request needs them.  A direct
// AIDL call otherwise makes the blob allocate ports 6/7, whose state is absent
// in this vendor and later becomes an uninitialised MCSC size.  Keep this
// diagnostic switch opt-in until the complete reprocessing bridge is ready.
int highResolutionYuvDropMode() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get("vendor.camera.aidl.drop_highres_yuv", value);
    if (length <= 0) return 0;
    char* end = nullptr;
    const long mode = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || mode < 0 || mode > 3) return 0;
    return static_cast<int>(mode);
}

bool shouldDropHighResolutionYuv(const aidl_device::Stream& source) {
    const int mode = highResolutionYuvDropMode();
    if (mode == 0 || static_cast<int32_t>(source.format) != 35) return false;
    const int64_t useCase = static_cast<int64_t>(source.useCase);
    // 0x20000 is the large still YUV companion. Newer Samsung Camera builds
    // encode the same companion as 0x2020000 (option 0x202 after the HIDL
    // <<16 conversion). 0x40000 is the small JPEG thumbnail companion.
    const bool largeCompanion = useCase == 0x20000 || useCase == 0x2020000;
    const bool thumbnail = useCase == 0x40000;
    if (mode == 2) return largeCompanion;
    if (mode == 3) return thumbnail;
    return largeCompanion || thumbnail;
}

bool dropHighResolutionYuvForTest() {
    return highResolutionYuvDropMode() != 0;
}

bool nativeThumbnailCaptureForTest() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get("vendor.camera.aidl.native_thumbnail", value);
    // The direct native stream-5 experiment is intentionally opt-in with a
    // distinct value.  Values used by earlier tests ("1") must fall back to
    // the framework-only thumbnail path because the Exynos 990 blob still
    // rejects stream ID 5 in m_captureFrameHandler().
    return length > 0 && std::strcmp(value, "2") == 0;
}

// CameraService derives the number of concurrently queued capture requests
// from HalStream.maxBuffers.  The Exynos 990 front pipeline exposes nine
// framework buffers, while its FLITE Bayer pool has only eight entries.  The
// Samsung HIDL wrapper kept one slot outside the framework queue.  Preserve
// that headroom in the AIDL adapter for normal-resolution YUV preview
// streams; otherwise the ninth request starves FLITE and produces repeated
// preview frames.
int previewQueueDepthCap() {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get("vendor.camera.aidl.preview_max_buffers", value);
    if (length <= 0) return 0;
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 1 || parsed > 64) return 0;
    return static_cast<int>(parsed);
}

bool isNormalPreviewYuv(const SamsungCamera3Stream& stream) {
    return stream.format == 35 && stream.width <= 1920 && stream.height <= 1080;
}

bool sameGroupProperties(const aidl_device::Stream& lhs,
                         const aidl_device::Stream& rhs) {
    return lhs.format == rhs.format && lhs.dataSpace == rhs.dataSpace &&
            static_cast<uint64_t>(lhs.usage) == static_cast<uint64_t>(rhs.usage) &&
            lhs.concurrentGroup == rhs.concurrentGroup;
}

bool validateDocumentedStream(const aidl_device::Stream& source, size_t index,
                              const std::vector<aidl_device::Stream>& all) {
    if (source.id < 0) {
        ALOGE("Camera3Streams: stream[%zu] has invalid negative id=%d", index, source.id);
        return false;
    }
    if (source.width <= 0 || source.height <= 0 || source.bufferSize < 0) {
        ALOGE("Camera3Streams: stream[%zu] invalid dimensions/bufferSize=%dx%d/%d", index,
              source.width, source.height, source.bufferSize);
        return false;
    }
    if (source.streamType == aidl_device::StreamType::INPUT &&
        static_cast<uint64_t>(source.usage) != 0) {
        // Stream.aidl requires INPUT usage to be zero.  Passing consumer bits
        // through here changes the HAL's format decision and is a contract
        // violation, even if the proprietary backend happens to ignore them.
        ALOGE("Camera3Streams: input stream[%zu] has non-zero usage=0x%" PRIx64, index,
              static_cast<uint64_t>(source.usage));
        return false;
    }
    if (source.streamType == aidl_device::StreamType::INPUT &&
        !source.physicalCameraId.empty()) {
        ALOGE("Camera3Streams: input stream[%zu] has a physical camera id", index);
        return false;
    }
    if (source.groupId < -1 || (source.concurrentGroup && source.groupId < 0)) {
        ALOGE("Camera3Streams: invalid groupId/concurrentGroup on stream[%zu]: %d/%d", index,
              source.groupId, source.concurrentGroup);
        return false;
    }
    std::unordered_set<int32_t> pixelModes;
    for (const auto mode : source.sensorPixelModesUsed) {
        const int32_t value = static_cast<int32_t>(mode);
        if (!validSensorPixelMode(value) || !pixelModes.insert(value).second) {
            ALOGE("Camera3Streams: invalid or duplicate sensor pixel mode=%d on stream[%zu]",
                  value, index);
            return false;
        }
        // Camera3 in the original Exynos 990 vendor predates the AIDL
        // sensorPixelModesUsed field.  An empty list and DEFAULT have the
        // documented same meaning, and are therefore safe.  MAXIMUM_RESOLUTION
        // has no field in camera3_stream_t and must not be silently sent as a
        // default-mode stream: that would select the wrong sensor path.
        if (value == ANDROID_SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION) {
            ALOGE("Camera3Streams: maximum-resolution stream[%zu] requires an Exynos "
                  "sensor-mode bridge; refusing to downgrade it to DEFAULT", index);
            return false;
        }
    }
    const int64_t dynamicRange = static_cast<int64_t>(source.dynamicRangeProfile);
    if (dynamicRange <= 0) {
        ALOGE("Camera3Streams: invalid dynamic range profile=%" PRId64 " on stream[%zu]",
              dynamicRange, index);
        return false;
    }
    const int64_t useCase = static_cast<int64_t>(source.useCase);
    if (!validStreamUseCase(useCase)) {
        ALOGE("Camera3Streams: invalid stream use case=%" PRId64 " on stream[%zu]", useCase,
              index);
        return false;
    }
    uint32_t samsungOption = 0;
    if (!mapSamsungStreamOption(useCase, &samsungOption)) {
        ALOGE("Camera3Streams: stream use case=%" PRId64
              " cannot be represented by Samsung's 32-bit option ABI", useCase);
        return false;
    }
    // The direct Camera3 ABI has no named field for this AIDL V4 property.  It
    // is carried through the vendor-reserved slot consumed by Samsung's
    // adapter.  The AIDL value remains authoritative; this is only the exact
    // private inverse of the original option << 16 conversion.
    if (dynamicRange != kStandardDynamicRangeProfile) {
        ALOGE("Camera3Streams: backend cannot represent non-standard dynamic range profile=%" PRIx64,
              dynamicRange);
        return false;
    }
    if (source.colorSpace != kColorSpaceUnspecified && source.colorSpace < 0) {
        ALOGE("Camera3Streams: invalid negative colorSpace=%d on stream[%zu]", source.colorSpace,
              index);
        return false;
    }
    if (source.groupId >= 0) {
        for (size_t previous = 0; previous < index; ++previous) {
            const auto& other = all[previous];
            if (other.groupId == source.groupId && !sameGroupProperties(other, source)) {
                ALOGE("Camera3Streams: groupId=%d violates format/dataspace/usage invariant",
                      source.groupId);
                return false;
            }
        }
    }
    // Stream.aidl requires a non-zero BLOB/JFIF size and zero for every other
    // format.  Enforce this before entering the proprietary HAL; otherwise the
    // Samsung backend may derive a different buffer layout from the same
    // stream and crash while enumerating its private extra streams.
    constexpr int32_t kBlobFormat = 0x21;  // HAL_PIXEL_FORMAT_BLOB
    // Dataspace::JFIF is the BLOB case that requires a non-zero size;
    // Dataspace::DEPTH is explicitly allowed to remain zero by Stream.aidl.
    constexpr int32_t kJfifDataspace = 146931712;
    if (static_cast<int32_t>(source.format) == kBlobFormat &&
        static_cast<int32_t>(source.dataSpace) == kJfifDataspace && source.bufferSize == 0) {
        ALOGE("Camera3Streams: BLOB/JFIF stream[%zu] has zero bufferSize", index);
        return false;
    }
    if (static_cast<int32_t>(source.format) != kBlobFormat && source.bufferSize != 0) {
        ALOGE("Camera3Streams: non-BLOB stream[%zu] supplied bufferSize=%d; Android requires 0",
              index, source.bufferSize);
        return false;
    }
    return true;
}

bool streamType(aidl_device::StreamType input, int* output) {
    const int value = static_cast<int>(input);
    if (value < CAMERA3_STREAM_OUTPUT || value > CAMERA3_STREAM_BIDIRECTIONAL) return false;
    *output = value;
    return true;
}

bool rotation(aidl_device::StreamRotation input, int* output) {
    const int value = static_cast<int>(input);
    if (value < CAMERA3_STREAM_ROTATION_0 || value > CAMERA3_STREAM_ROTATION_270) return false;
    *output = value;
    return true;
}

}  // namespace

void Camera3Streams::resetConfiguration() {
    if (sessionParameters_) {
        free_camera_metadata(sessionParameters_);
        sessionParameters_ = nullptr;
    }
    pointers_.clear();
    physicalIds_.clear();
    ids_.clear();
    useCases_.clear();
    nativeConfigured_.clear();
    streams_.clear();
}

void Camera3Streams::clear() {
    resetConfiguration();
    persistent_.clear();
}

camera3_stream_t* Camera3Streams::find(int32_t streamId) {
    for (size_t index = 0; index < ids_.size(); ++index) {
        if (ids_[index] == streamId) {
            return reinterpret_cast<camera3_stream_t*>(streams_[index]);
        }
    }
    return nullptr;
}

bool Camera3Streams::idFor(const camera3_stream_t* stream, int32_t* streamId) const {
    if (!stream || !streamId) return false;
    for (size_t index = 0; index < streams_.size(); ++index) {
        if (reinterpret_cast<const camera3_stream_t*>(streams_[index]) == stream) {
            *streamId = ids_[index];
            return true;
        }
    }
    return false;
}

bool Camera3Streams::isNativeConfigured(int32_t streamId) const {
    for (size_t index = 0; index < ids_.size(); ++index) {
        if (ids_[index] == streamId)
            return index < nativeConfigured_.size() && nativeConfigured_[index];
    }
    return false;
}

bool Camera3Streams::isNativeCaptureAllowed(int32_t streamId) const {
    if (!nativeThumbnailCaptureForTest()) return false;
    for (size_t index = 0; index < ids_.size(); ++index) {
        if (ids_[index] != streamId) continue;
        // Only the 512x384 YUV thumbnail companion is bridged this way. The
        // 4032x3024 YUV companion still needs the full high-resolution path.
        return index < nativeConfigured_.size() && !nativeConfigured_[index] &&
                index < useCases_.size() && useCases_[index] == 0x40000;
    }
    return false;
}

bool Camera3Streams::isStaleFlush(int32_t streamConfigCounter) const {
    return streamConfigCounter_ >= 0 && streamConfigCounter < streamConfigCounter_;
}

int Camera3Streams::configure(camera3_device_t* device,
        const aidl_device::StreamConfiguration& input, std::vector<aidl_device::HalStream>* output) {
    if (!device || !device->ops || !device->ops->configure_streams || !output ||
        input.streams.empty()) return -EINVAL;
    if (input.streamConfigCounter < 0) {
        ALOGE("Camera3Streams: invalid negative streamConfigCounter=%d", input.streamConfigCounter);
        return -EINVAL;
    }
    if (input.multiResolutionInputImage) {
        // The S26+ converter carries this through its newer Samsung HAL.  The
        // S20+ Camera3 ABI has no equivalent and its original metadata does
        // not advertise multi-resolution input.  Reject explicitly instead
        // of configuring a fixed-size input as variable-resolution.
        ALOGE("Camera3Streams: multiResolutionInputImage is unsupported by Exynos 990 Camera3");
        return -ENOTSUP;
    }
    const int32_t operationMode = static_cast<int32_t>(input.operationMode);
    const bool standardOperationMode = operationMode == 0 || operationMode == 1;
    const bool vendorOperationMode = operationMode >= 0x8000 && operationMode <= 0x8007;
    if (!standardOperationMode && !vendorOperationMode) {
        ALOGE("Camera3Streams: unsupported AIDL operation mode=0x%x", operationMode);
        return -EINVAL;
    }
    // Session parameters are part of the Camera3 configure contract. The
    // Samsung app sends them before the first request; rejecting them makes
    // CameraService report a misleading unsupported stream combination.
    const camera_metadata_t* sessionParameters = nullptr;
    camera_metadata_t* ownedSessionParameters = nullptr;
    if (!input.sessionParams.metadata.empty()) {
        sessionParameters = reinterpret_cast<const camera_metadata_t*>(
                input.sessionParams.metadata.data());
        const size_t allocatedSize = get_camera_metadata_size(sessionParameters);
        const size_t compactSize = get_camera_metadata_compact_size(sessionParameters);
        // The second argument is the available input size, not an output-only
        // value. Passing zero makes a valid 48-byte metadata header fail with
        // "Metadata size ... should be <= expected size (0)".
        size_t expectedSize = input.sessionParams.metadata.size();
        const int validation = validate_camera_metadata_structure(sessionParameters, &expectedSize);
        // CameraService may send the allocated CameraMetadata parcel (with
        // trailing capacity) instead of the compact payload. An empty session
        // object therefore has expectedSize=0 but is still valid when its
        // declared allocation fits in the parcel.
        // AIDL metadata may be shifted in its Binder parcel. Android's own
        // AidlUtils::cloneFromAidl accepts CAMERA_METADATA_VALIDATION_SHIFTED
        // (the metadata remains structurally valid); reject only malformed
        // layouts, not this expected transport representation.
        const bool validStructure = validation == 0 ||
                validation == CAMERA_METADATA_VALIDATION_SHIFTED;
        if (!validStructure || allocatedSize == 0 ||
            allocatedSize > input.sessionParams.metadata.size() ||
            compactSize > input.sessionParams.metadata.size()) {
            ALOGE("Camera3Streams: invalid session metadata size=%zu allocated=%zu compact=%zu "
                  "expected=%zu validation=%d",
                  input.sessionParams.metadata.size(), allocatedSize, compactSize, expectedSize,
                  validation);
            return -EINVAL;
        }
        // Binder's byte vector is only a transport buffer. Samsung's native
        // Camera3 HAL dereferences aligned camera_metadata_buffer_entry/data
        // structures and can crash when handed the AIDL vector directly. The
        // Android AIDL Camera3 path clones this parcel before calling HAL3;
        // mirror that ownership/alignment boundary here.
        ownedSessionParameters = clone_camera_metadata(sessionParameters);
        if (!ownedSessionParameters) {
            ALOGE("Camera3Streams: unable to clone session metadata");
            return -EINVAL;
        }
        sessionParameters = ownedSessionParameters;
        ALOGI("Camera3Streams: accepted session metadata size=%zu allocated=%zu compact=%zu",
              input.sessionParams.metadata.size(), allocatedSize, compactSize);
    }

    resetConfiguration();
    // Streams created by this call. If the configuration is rejected they are
    // dropped again, while objects of the still-active configuration stay.
    std::vector<int32_t> created;
    const auto abortConfigure = [&]() {
        for (int32_t id : created) persistent_.erase(id);
        resetConfiguration();
    };
    streams_.resize(input.streams.size());
    physicalIds_.resize(input.streams.size());
    pointers_.resize(input.streams.size());
    ids_.resize(input.streams.size());
    useCases_.resize(input.streams.size());
    for (size_t index = 0; index < input.streams.size(); ++index) {
        const auto& source = input.streams[index];
        int nativeType = 0;
        int nativeRotation = CAMERA3_STREAM_ROTATION_0;
        if (!validateDocumentedStream(source, index, input.streams) ||
            !streamType(source.streamType, &nativeType) ||
            !rotation(source.rotation, &nativeRotation)) {
            abortConfigure();
            return -EINVAL;
        }
        for (size_t previous = 0; previous < index; ++previous) {
            if (ids_[previous] == source.id) {
                abortConfigure();
                return -EINVAL;
            }
        }
        // Reuse the object of a stream that stays configured; CameraService
        // keeps the AIDL id only for an unchanged stream, so the geometry
        // check is a safety net. New (or changed) streams get a fresh object
        // with priv == NULL, as the HAL expects.
        auto existing = persistent_.find(source.id);
        const bool retained = existing != persistent_.end() &&
                existing->second->stream_type == nativeType &&
                existing->second->width == static_cast<uint32_t>(source.width) &&
                existing->second->height == static_cast<uint32_t>(source.height) &&
                existing->second->format == static_cast<int>(source.format);
        if (!retained) {
            persistent_[source.id] = std::make_unique<SamsungCamera3Stream>();
            created.push_back(source.id);
        }
        SamsungCamera3Stream& native = *persistent_[source.id];
        streams_[index] = &native;
        native.stream_type = nativeType;
        native.rotation = nativeRotation;
        ids_[index] = source.id;
        useCases_[index] = static_cast<int64_t>(source.useCase);
        native.width = static_cast<uint32_t>(source.width);
        native.height = static_cast<uint32_t>(source.height);
        native.format = static_cast<int>(source.format);
        // The Samsung HIDL adapter copies SehStream.id into the vendor
        // Camera3Stream::mId at offset 0x68. Preserve the AIDL stream id at
        // that exact private ABI position while keeping all public fields
        // mapped according to Android's Camera3/AIDL contract.
        native.id = source.id;
        native.usage = static_cast<uint64_t>(source.usage);
        const int64_t useCase = static_cast<int64_t>(source.useCase);
        uint32_t samsungOption = 0;
        if (!mapSamsungStreamOption(useCase, &samsungOption)) {
            abortConfigure();
            return -EINVAL;
        }
        // The original Samsung wrapper writes the private stream selector to
        // the first vendor-reserved Camera3 word. This was verified against
        // the Exynos HAL itself: data_space alone leaves m_setStreamInfo with
        // option(0), while this word yields the requested option.
        const bool privateUseCaseCompat = copyPrivateUseCaseForHidlCompat();
        // This is the exact field written by the donor HIDL adapter's
        // preProcessConfigurationLocked(): Camera3Stream::mOption aliases
        // camera3_stream_t::reserved[0] at +0x38. It is a small integer stored
        // in the pointer-sized slot, not a pointer to another object.
        native.reserved[0] = privateUseCaseCompat ?
                reinterpret_cast<void*>(static_cast<uintptr_t>(samsungOption)) : nullptr;
        native.reserved[1] = nullptr;
        native.reserved[2] = nullptr;
        native.reserved[3] = nullptr;
        native.reserved[4] = nullptr;
        native.reserved[5] = nullptr;
        // Samsung's convertFromHidl() clears priv only for a new stream; the
        // HAL then stores its own ExynosCameraStream owner there. A retained
        // stream keeps that pointer, otherwise the HAL treats every stream of
        // a reconfiguration (aspect-ratio switch) as new, reuses its frame
        // factories with stale buffer managers and the preview stalls.
        if (!retained) native.priv = nullptr;
        // Keep the public Android data-space unchanged. The Samsung option is
        // carried separately in reserved[0] above.
        native.data_space = static_cast<android_dataspace_t>(source.dataSpace);
        ALOGI("Camera3Streams: AIDL stream[%zu] id=%d type=%d %dx%d format=%d usage=0x%" PRIx64
              " dataspace=0x%x rotation=%d group=%d pixels=%zu dynamic=0x%" PRIx64
              " usecase=%" PRId64 " colorspace=%d bufferSize=%d concurrent=%d",
              index, source.id, native.stream_type, native.width, native.height, native.format,
              native.usage, static_cast<uint32_t>(source.dataSpace), native.rotation,
              source.groupId, source.sensorPixelModesUsed.size(),
              static_cast<uint64_t>(source.dynamicRangeProfile),
              static_cast<int64_t>(source.useCase), source.colorSpace, source.bufferSize,
              source.concurrentGroup);
        ALOGI("Camera3Streams: stream[%zu] nativeDataSpace=0x%x mappedFrom=0x%x option=0x%x reserved0=0x%lx priv=%s",
              index, static_cast<uint32_t>(native.data_space),
              static_cast<uint32_t>(source.dataSpace), samsungOption,
              reinterpret_cast<unsigned long>(native.reserved[0]),
              native.priv ? (retained ? "retained" : "self") : "null");
        physicalIds_[index] = source.physicalCameraId;
        // AIDL represents an absent physical-camera association as an empty
        // String. The Samsung Exynos Camera3 blob dereferences this legacy
        // field while matching streams, so convert the empty AIDL value to a
        // stable zero-length C string instead of passing nullptr into HAL3.
        native.physical_camera_id = physicalIds_[index].empty() ?
                kEmptyPhysicalCameraId : physicalIds_[index].c_str();
        pointers_[index] = reinterpret_cast<camera3_stream_t*>(&native);
    }
    std::vector<camera3_stream_t*> nativePointers = pointers_;
    if (truncateNativeStreamSetForTest()) {
        nativePointers.clear();
        for (size_t index = 0; index < streams_.size(); ++index) {
            // This is a diagnostic boundary test only. The native Exynos 990
            // manager can configure preview and JPEG directly; the YUV
            // ImageReader streams need a separate Samsung extra-stream bridge.
            if (streams_[index]->format == 34 || streams_[index]->format == 33) {
                nativePointers.push_back(pointers_[index]);
            }
        }
        ALOGI("Camera3Streams: native preview/JPEG test reduced %zu AIDL streams to %zu",
              pointers_.size(), nativePointers.size());
    }
    if (dropHighResolutionYuvForTest()) {
        nativePointers.clear();
        for (size_t index = 0; index < streams_.size(); ++index) {
            const auto& source = input.streams[index];
            if (!shouldDropHighResolutionYuv(source)) nativePointers.push_back(pointers_[index]);
        }
        ALOGI("Camera3Streams: dropped high-resolution YUV companion streams %zu->%zu",
              pointers_.size(), nativePointers.size());
    }
    nativeConfigured_.assign(streams_.size(), false);
    for (size_t index = 0; index < pointers_.size(); ++index) {
        nativeConfigured_[index] = std::find(nativePointers.begin(), nativePointers.end(),
                                             pointers_[index]) != nativePointers.end();
    }
    camera3_stream_configuration_t configuration{
            .num_streams = static_cast<uint32_t>(nativePointers.size()),
            .streams = nativePointers.data(),
            .operation_mode = static_cast<uint32_t>(input.operationMode),
            .session_parameters = sessionParameters,
    };
    int result = device->ops->configure_streams(device, &configuration);
    ALOGI("Camera3Streams: configure_streams count=%zu operation_mode=%u result=%d",
          nativePointers.size(), configuration.operation_mode, result);
    if (result == -EINVAL) {
        bool hasNonZeroRotation = false;
        for (const auto* stream : streams_) {
            hasNonZeroRotation |= stream->rotation != CAMERA3_STREAM_ROTATION_0;
        }
        if (hasNonZeroRotation) {
            // The Android Camera3 contract permits 90/180/270 degrees, but
            // this Exynos 990 blob rejects any non-zero rotation in
            // m_enumStreamInfo(). Retry the identical stream set at zero and
            // let CameraService/Samsung metadata perform display orientation.
            for (auto* stream : streams_) stream->rotation = CAMERA3_STREAM_ROTATION_0;
            result = device->ops->configure_streams(device, &configuration);
            ALOGI("Camera3Streams: zero-rotation compatibility retry result=%d", result);
        }
    }
    if (result != 0) {
        bool allPhysicalIdsEmpty = true;
        for (const auto& id : physicalIds_) allPhysicalIdsEmpty &= id.empty();
        if (allPhysicalIdsEmpty) {
            for (auto* stream : streams_) stream->physical_camera_id = kEmptyPhysicalCameraId;
            result = device->ops->configure_streams(device, &configuration);
            ALOGI("Camera3Streams: legacy empty physical id retry result=%d", result);
        }
    }
    if (result != 0) {
        if (ownedSessionParameters) {
            free_camera_metadata(ownedSessionParameters);
            ownedSessionParameters = nullptr;
        }
        ALOGE("Camera3Streams: HAL rejected stream configuration result=%d", result);
        abortConfigure();
        return result;
    }
    // The HAL has released its owners for streams absent from this
    // configuration; drop our objects for them as well.
    for (auto it = persistent_.begin(); it != persistent_.end();) {
        if (std::find(ids_.begin(), ids_.end(), it->first) == ids_.end())
            it = persistent_.erase(it);
        else
            ++it;
    }
    // A StreamConfiguration generation becomes visible only after the
    // corresponding Camera3 configuration succeeds.  Otherwise a failed
    // reconfigure could cause a later flush for the still-active generation
    // to be discarded as stale.
    streamConfigCounter_ = input.streamConfigCounter;
    ALOGI("Camera3Streams: accepted AIDL streamConfigCounter=%d", streamConfigCounter_);
    for (size_t index = 0; index < streams_.size(); ++index) {
        const auto& stream = *streams_[index];
        ALOGI("Camera3Streams: HAL stream[%zu] id=%d %ux%u format=%d dataSpace=0x%x max=%u priv=%p",
              index, ids_[index], stream.width, stream.height, stream.format,
              static_cast<uint32_t>(stream.data_space), stream.max_buffers, stream.priv);
    }
    if (ownedSessionParameters) {
        // The original HIDL session owns this converted packet for its whole
        // configured lifetime.  The Exynos video/VDIS worker can begin after
        // configure_streams() returns, so do not leave it with a dangling
        // session-parameter pointer from the AIDL Binder parcel.
        sessionParameters_ = ownedSessionParameters;
        ownedSessionParameters = nullptr;
    }
    output->clear();
    output->reserve(input.streams.size());
    for (size_t index = 0; index < input.streams.size(); ++index) {
        const auto& source = input.streams[index];
        const SamsungCamera3Stream& native = *streams_[index];
        aidl_device::HalStream hal;
        hal.id = source.id;
        hal.overrideFormat = static_cast<aidl_graphics::PixelFormat>(native.format);
        // AIDL HalStream separates the allocator roles.  For an output (or
        // bidirectional) stream, the HAL-producer flags belong in
        // producerUsage and consumerUsage must be zero; for an input stream
        // the roles are reversed.  Returning the requested Stream.usage in
        // consumerUsage for an output makes AidlCamera3Device reject the
        // whole configuration before the first request.
        if (source.streamType == aidl_device::StreamType::INPUT) {
            hal.producerUsage = static_cast<aidl_graphics::BufferUsage>(0);
            hal.consumerUsage = static_cast<aidl_graphics::BufferUsage>(native.usage);
        } else {
            hal.producerUsage = static_cast<aidl_graphics::BufferUsage>(native.usage);
            hal.consumerUsage = static_cast<aidl_graphics::BufferUsage>(0);
        }
        hal.maxBuffers = static_cast<int32_t>(native.max_buffers);
        const int previewCap = previewQueueDepthCap();
        if (previewCap > 0 && nativeConfigured_[index] && isNormalPreviewYuv(native) &&
            hal.maxBuffers > previewCap) {
            ALOGI("Camera3Streams: cap preview maxBuffers %d->%d for stream id=%d",
                  hal.maxBuffers, previewCap, source.id);
            hal.maxBuffers = previewCap;
        }
        // When the high-resolution companion streams are intentionally kept
        // out of the native configure call, the vendor HAL cannot fill their
        // max_buffers field.  AIDL still requires a positive queue depth for
        // every returned HalStream; use the same depths the Exynos wrapper
        // reports for JPEG and YUV streams so CameraService can finish the
        // session and keep those streams available for the later bridge.
        if (hal.maxBuffers == 0 && dropHighResolutionYuvForTest()) {
            hal.maxBuffers = static_cast<int32_t>(
                    static_cast<int32_t>(source.format) == 0x21 ? 7 : 9);
            ALOGI("Camera3Streams: fallback maxBuffers=%d for framework-only stream id=%d",
                  hal.maxBuffers, source.id);
        }
        // data_space above is a Samsung-private HAL option after the HIDL
        // compatibility conversion. AIDL must continue to report the public
        // dataSpace requested by the framework.
        hal.overrideDataSpace = static_cast<aidl_graphics::Dataspace>(source.dataSpace);
        hal.physicalCameraId = source.physicalCameraId;
        hal.supportOffline = false;
        hal.enableHalBufferManager = false;
        output->push_back(std::move(hal));
    }
    return 0;
}

}  // namespace exynos990::camera
