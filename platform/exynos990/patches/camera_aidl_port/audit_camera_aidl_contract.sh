#!/usr/bin/env bash
set -euo pipefail

# Read-only gate for the eventual AIDL provider. It deliberately checks the
# actual y2s runtime ABI instead of accepting the S26+ interface as a donor.
WORK_DIR="${1:?usage: audit_camera_aidl_contract.sh <work_dir>}"
SYSTEM_LIB="$WORK_DIR/system/system/lib64"
VENDOR="$WORK_DIR/vendor"

fail() { printf 'camera-aidl-port: %s\n' "$*" >&2; exit 1; }
require() { [ -f "$1" ] || fail "missing ${1#$WORK_DIR/}"; }

for lib in \
    android.hardware.camera.common-V1-ndk.so \
    android.hardware.camera.device-V4-ndk.so \
    android.hardware.camera.metadata-V3-ndk.so \
    android.hardware.camera.provider-V4-ndk.so \
    android.hardware.common-V2-ndk.so \
    android.hardware.common.fmq-V1-ndk.so \
    android.hardware.graphics.common-V7-ndk.so \
    libbinder_ndk.so libcamera_metadata.so libhardware.so; do
    require "$SYSTEM_LIB/$lib"
done

require "$VENDOR/lib64/hw/camera.exynos990.so"
require "$VENDOR/lib64/libexynoscamera3.so"
require "$VENDOR/lib64/libGrallocMapperCamera.so"
require "$VENDOR/lib64/hw/gralloc.exynos990.so"

# Native Camera3 must be the backend. An AIDL provider that points back to the
# Samsung HIDL provider has not removed the transport dependency.
if readelf -d "$VENDOR/lib64/hw/camera.exynos990.so" | grep -q \
    'vendor\.samsung\.hardware\.camera\.provider@4\.0'; then
    fail 'camera.exynos990.so depends on the Samsung HIDL provider instead of Camera3 backend'
fi

# Confirm the generated NDK interface classes expected by this Android 17
# system. Descriptors can be held as non-printable/relocated data, so testing
# exported C++ interface symbols is more reliable than a strings-only check.
for symbol in \
    '_ZN4aidl7android8hardware6camera8provider15ICameraProvider10descriptorE' \
    '_ZN4aidl7android8hardware6camera6device13ICameraDevice10descriptorE' \
    '_ZN4aidl7android8hardware6camera6device20ICameraDeviceSession10descriptorE'; do
    if [[ "$symbol" == *provider* ]]; then
        library="$SYSTEM_LIB/android.hardware.camera.provider-V4-ndk.so"
    else
        library="$SYSTEM_LIB/android.hardware.camera.device-V4-ndk.so"
    fi
    nm -D --defined-only "$library" | awk '{print $3}' | grep -Fqx "$symbol" || \
        fail "target AIDL interface symbol absent: $symbol"
done

printf '%s\n' 'camera-aidl-port: Camera AIDL V4 and native Exynos Camera3 backend are present'
