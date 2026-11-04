#!/usr/bin/env bash
set -euo pipefail

# Builds an ABI probe only. The resulting binary is never put into vendor by
# customize.sh. It proves that the source and generated stubs link against the
# exact Camera AIDL V4 libraries carried by the y2s system image.
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
AIDL="${ANDROID_AIDL:-/home/ats0c/.android-sdk/build-tools/36.1.0/aidl}"
CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang++"
SYSROOT="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
PLATFORM_LIBS="${TARGET_SYSTEM_LIBS:-$REPO/out/target/y2s/work_dir/system/system/lib64}"
# Ponto de referência local Android 17. Os checkouts vêm de android17-release
# e ficam no volume de build, não em /tmp, pois a API V4 precisa permanecer
# reproduzível entre limpezas. Eles precisam conter common, common/fmq e
# graphics/common, pois a API Camera V4 importa esses contratos congelados
# para handles, FMQ e formatos.
AOSP_DEPS="${EXYNOS990_CAMERA_AIDL_AOSP_ROOT:-$REPO/out/aosp-camera-aidl-deps}"
API_ROOT="${ANDROID_HARDWARE_INTERFACES_A17:-$AOSP_DEPS/hardware-interfaces}"
SDK_BINDER_CPP="${ANDROID_SDK_ROOT:-/home/ats0c/.android-sdk}/platforms/android-36/optional/libbinder_ndk_cpp"
BUILD_ROOT="${EXYNOS990_CAMERA_AIDL_BUILD_ROOT:-/tmp}"
CAMERA3_HEADERS="${EXYNOS990_CAMERA3_HEADERS:-$AOSP_DEPS/libhardware/include}"
CAMERA_METADATA_HEADERS="${EXYNOS990_CAMERA_METADATA_HEADERS:-$AOSP_DEPS/system-media/camera/include}"
CAMERA_METADATA_PRIVATE_HEADERS="${EXYNOS990_CAMERA_METADATA_PRIVATE_HEADERS:-$(cd "$CAMERA_METADATA_HEADERS/../.." && pwd)/private/camera/include}"
CUTILS_HEADERS="${EXYNOS990_CUTILS_HEADERS:-$AOSP_DEPS/system-core/libcutils/include}"
SYSTEM_HEADERS="${EXYNOS990_SYSTEM_HEADERS:-$AOSP_DEPS/system-core/libsystem/include}"
[ -d "$BUILD_ROOT" ] || { echo "Missing build root: $BUILD_ROOT" >&2; exit 1; }
BUILD="$(mktemp -d "$BUILD_ROOT/exynos990-camera-aidl-build.XXXXXX")"
GENERATED_AIDL_DIR="${EXYNOS990_CAMERA_AIDL_GENERATED:-}"

for tool in "$AIDL" "$CXX"; do
    [ -x "$tool" ] || { echo "Missing tool: $tool" >&2; exit 1; }
done
for include_dir in "$CAMERA3_HEADERS" "$CAMERA_METADATA_HEADERS" "$CUTILS_HEADERS" "$SYSTEM_HEADERS"; do
    [ -d "$include_dir" ] || { echo "Missing Camera3 header root: $include_dir" >&2; exit 1; }
done
[ -d "$CAMERA_METADATA_PRIVATE_HEADERS" ] || {
    echo "Missing camera metadata private headers: $CAMERA_METADATA_PRIVATE_HEADERS" >&2
    exit 1
}
for path in \
    "$API_ROOT/camera/common/aidl/aidl_api/android.hardware.camera.common/1" \
    "$API_ROOT/camera/device/aidl/aidl_api/android.hardware.camera.device/4" \
    "$API_ROOT/camera/metadata/aidl/aidl_api/android.hardware.camera.metadata/3" \
    "$API_ROOT/camera/provider/aidl/aidl_api/android.hardware.camera.provider/4" \
    "$API_ROOT/common/aidl/aidl_api/android.hardware.common/2" \
    "$API_ROOT/common/fmq/aidl/aidl_api/android.hardware.common.fmq/1" \
    "$API_ROOT/graphics/common/aidl/aidl_api/android.hardware.graphics.common/7"; do
    [ -d "$path" ] || { echo "Missing Android 17 frozen AIDL API: $path" >&2; exit 1; }
done

bash "$ROOT/audit_camera_aidl_contract.sh" "$REPO/out/target/y2s/work_dir"
bash "$ROOT/audit_camera_buffers.sh"
bash "$ROOT/audit_camera_streams.sh"
bash "$ROOT/audit_camera_session.sh"
bash "$ROOT/audit_camera_activation.sh"

API_DIRS=(
    "$API_ROOT/camera/common/aidl/aidl_api/android.hardware.camera.common/1"
    "$API_ROOT/camera/device/aidl/aidl_api/android.hardware.camera.device/4"
    "$API_ROOT/camera/metadata/aidl/aidl_api/android.hardware.camera.metadata/3"
    "$API_ROOT/camera/provider/aidl/aidl_api/android.hardware.camera.provider/4"
    "$API_ROOT/common/aidl/aidl_api/android.hardware.common/2"
    "$API_ROOT/common/fmq/aidl/aidl_api/android.hardware.common.fmq/1"
    "$API_ROOT/graphics/common/aidl/aidl_api/android.hardware.graphics.common/7"
)
INCLUDES=()
for api_dir in "${API_DIRS[@]}"; do
    INCLUDES+=( -I "$api_dir" )
done
mapfile -t AIDL_INPUTS < <(find "${API_DIRS[@]}" -name '*.aidl' -type f | LC_ALL=C sort)
if [ -n "$GENERATED_AIDL_DIR" ]; then
    [ -d "$GENERATED_AIDL_DIR/include" ] && [ -d "$GENERATED_AIDL_DIR/src" ] || {
        echo "Invalid EXYNOS990_CAMERA_AIDL_GENERATED: $GENERATED_AIDL_DIR" >&2
        exit 1
    }
    GENERATED_INCLUDE="$GENERATED_AIDL_DIR/include"
    GENERATED_SOURCE="$GENERATED_AIDL_DIR/src"
else
    "$AIDL" --lang=ndk --structured --stability=vintf --version=4 \
        --hash=6d711578fd7d8ed6b5ab3a94743c4df77f6cdeaa --min_sdk_version=30 \
        "${INCLUDES[@]}" -h "$BUILD/include" -o "$BUILD/src" "${AIDL_INPUTS[@]}"
    GENERATED_INCLUDE="$BUILD/include"
    GENERATED_SOURCE="$BUILD/src"
fi

# Samsung extensions requested by cameraserver through AIBinder_getExtension().
# Each package carries the version/hash read from the system V1 NDK library.
SEH_AIDL_ROOT="$ROOT/aidl"
"$AIDL" --lang=ndk --structured --stability=vintf --version=1 \
    --hash=c1d37123fc01e3f288f0f11a72330f9a95de01e9 --min_sdk_version=30 \
    -I "$SEH_AIDL_ROOT" -h "$GENERATED_INCLUDE" -o "$GENERATED_SOURCE" \
    "$SEH_AIDL_ROOT/vendor/samsung/hardware/camera/device/ISehCameraDeviceSession.aidl"
"$AIDL" --lang=ndk --structured --stability=vintf --version=1 \
    --hash=1b4ed917ff8b23cc778ada14e0ade631029d8469 --min_sdk_version=30 \
    -I "$SEH_AIDL_ROOT" -h "$GENERATED_INCLUDE" -o "$GENERATED_SOURCE" \
    "$SEH_AIDL_ROOT/vendor/samsung/hardware/camera/provider/ISehCameraProvider.aidl"

# Compile generated parcels one source at a time. A single clang invocation
# over the whole Camera API exceeds the host's memory ceiling and can be
# killed without a diagnostic. Keeping all generated code local also avoids
# crossing the system/vendor libc++ ABI boundary while implementing Bn types.
OBJECTS=()
compile_source() {
    local source="$1"
    local object="$BUILD/obj/${#OBJECTS[@]}.o"
    mkdir -p "$BUILD/obj"
    "$CXX" --sysroot="$SYSROOT" -std=c++20 -O1 -fPIC \
        -I "$GENERATED_INCLUDE" -I "$SDK_BINDER_CPP" \
        -I "$CAMERA3_HEADERS" -I "$CAMERA_METADATA_HEADERS" \
        -I "$CAMERA_METADATA_PRIVATE_HEADERS" \
        -I "$CUTILS_HEADERS" -I "$SYSTEM_HEADERS" \
        -I "$REPO/platform/exynos990/patches/graphics_aidl/include" \
        -c "$source" -o "$object"
    OBJECTS+=( "$object" )
}
compile_source "$ROOT/src/provider_main.cpp"
compile_source "$ROOT/src/camera3_module.cpp"
compile_source "$ROOT/src/camera_device.cpp"
compile_source "$ROOT/src/camera_session.cpp"
compile_source "$ROOT/src/camera_streams.cpp"
compile_source "$ROOT/src/camera_buffers.cpp"
while IFS= read -r source; do
    compile_source "$source"
done < <(find "$GENERATED_SOURCE" -name '*.cpp' -type f | LC_ALL=C sort)

"$CXX" --sysroot="$SYSROOT" -pie "${OBJECTS[@]}" \
    -L "$PLATFORM_LIBS" -L "$SYSROOT/usr/lib/aarch64-linux-android/30" \
    -Wl,--no-undefined -Wl,--gc-sections -Wl,--build-id=sha1 \
    -static-libstdc++ -lbinder_ndk -llog -lcutils -lhardware -lcamera_metadata -ldl \
    -o "$BUILD/android.hardware.camera.provider-V4-service.exynos990.probe"

file "$BUILD/android.hardware.camera.provider-V4-service.exynos990.probe" | grep -F 'ARM aarch64' >/dev/null
nm "$BUILD/android.hardware.camera.provider-V4-service.exynos990.probe" | \
    grep -F 'ICameraProvider' >/dev/null
echo "Camera AIDL V4 provider registration probe built: $BUILD/android.hardware.camera.provider-V4-service.exynos990.probe"
