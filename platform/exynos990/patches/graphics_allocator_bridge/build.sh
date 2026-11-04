#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
AIDL="${ANDROID_AIDL:-/home/ats0c/.android-sdk/build-tools/36.1.0/aidl}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CXX="$TOOLCHAIN/bin/aarch64-linux-android30-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
SYSROOT="$TOOLCHAIN/sysroot"
SDK_BINDER_CPP="${ANDROID_SDK_ROOT:-/home/ats0c/.android-sdk}/platforms/android-36/optional/libbinder_ndk_cpp"
# The S26+ dump is the interface reference, not the runtime donor.  Link
# against the y2s system image when it has already been unpacked so the
# bridge is checked against the libraries that will actually load it.  Keep
# the S26+ system image as a build-only fallback for standalone experiments.
TARGET_PLATFORM_LIBS="${TARGET_SYSTEM_LIBS:-$REPO/out/target/y2s/work_dir/system/system/lib64}"
REFERENCE_PLATFORM_LIBS="$REPO/out/fw/SM-S947B_EUX/system/system/lib64"
if [ -d "$TARGET_PLATFORM_LIBS" ]; then
    PLATFORM_LIBS="$TARGET_PLATFORM_LIBS"
    PLATFORM_LIBS_SOURCE="y2s runtime"
else
    PLATFORM_LIBS="$REFERENCE_PLATFORM_LIBS"
    PLATFORM_LIBS_SOURCE="S26+ reference fallback"
fi
BUILD="$ROOT/.build"
GEN="$BUILD/generated"
OUTPUT="$REPO/prebuilts/exynos990/graphics_allocator_bridge/vendor"
TEST_OUTPUT="$REPO/prebuilts/exynos990/graphics_allocator_bridge/test"

for tool in "$AIDL" "$CXX"; do
    [ -x "$tool" ] || { echo "Missing tool: $tool" >&2; exit 1; }
done
for lib in libhardware.so libcutils.so; do
    [ -f "$PLATFORM_LIBS/$lib" ] || {
        echo "Missing Android arm64 link library: $PLATFORM_LIBS/$lib" >&2
        exit 1
    }
done

for lib in libbinder_ndk.so libgralloctypes.so; do
    [ -f "$PLATFORM_LIBS/$lib" ] || {
        echo "Missing graphics runtime library: $PLATFORM_LIBS/$lib" >&2
        exit 1
    }
done

rm -rf "$BUILD"
mkdir -p "$GEN/include" "$GEN/src" "$OUTPUT/bin/hw" "$OUTPUT/lib64/hw" "$TEST_OUTPUT"
mapfile -t AIDL_FILES < <(find "$ROOT/aidl" -name '*.aidl' -type f | LC_ALL=C sort)
"$AIDL" --lang=ndk --structured --stability=vintf --version=2 \
    --hash=9499fec09c544e9de5be3c87125721600f8ade66 --min_sdk_version=30 \
    -I "$ROOT/aidl" -h "$GEN/include" -o "$GEN/src" "${AIDL_FILES[@]}"

COMMON_FLAGS=(
    --sysroot="$SYSROOT" -std=c++20 -O2 -fPIC -fvisibility=hidden
    -Wall -Wextra -Werror -Wno-error=deprecated-declarations
    -I"$ROOT/include" -I"$ROOT/src" -I"$GEN/include" -I"$SDK_BINDER_CPP"
)
COMMON_LINK=(
    -L"$PLATFORM_LIBS" -L"$SYSROOT/usr/lib/aarch64-linux-android/30"
    -Wl,--no-undefined -Wl,--build-id=sha1
    -lhardware -lcutils -llog -ldl
)

COMPAT_LIB="$OUTPUT/lib64/libexynos990_graphics_compat.so"

# Keep the backend loader and callback table in one library.  The two HAL
# entrypoints below link to it, while libc/libhardware remain platform ABI
# dependencies resolved by the vendor linker namespace.
"$CXX" "${COMMON_FLAGS[@]}" -shared "$ROOT/src/graphics_backend.cpp" \
    -Wl,-soname,libexynos990_graphics_compat.so "${COMMON_LINK[@]}" \
    -static-libstdc++ -o "$COMPAT_LIB"

"$CXX" "${COMMON_FLAGS[@]}" -shared "$ROOT/src/mapper.cpp" \
    -Wl,-soname,mapper.exynos990_compat.so -L"$OUTPUT/lib64" \
    -lexynos990_graphics_compat "${COMMON_LINK[@]}" -static-libstdc++ \
    -o "$OUTPUT/lib64/hw/mapper.exynos990_compat.so"

mapfile -t GENERATED_SOURCES < <(find "$GEN/src" -name '*.cpp' -type f | LC_ALL=C sort)
"$CXX" "${COMMON_FLAGS[@]}" -fPIE "$ROOT/src/allocator_service.cpp" \
    "${GENERATED_SOURCES[@]}" -pie -L"$OUTPUT/lib64" \
    -lexynos990_graphics_compat "${COMMON_LINK[@]}" -lbinder_ndk \
    -static-libstdc++ \
    -o "$OUTPUT/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990"

"$CXX" "${COMMON_FLAGS[@]}" -fPIE "$ROOT/src/bridge_test.cpp" \
    "${GENERATED_SOURCES[@]}" -pie "${COMMON_LINK[@]}" -lbinder_ndk \
    "$SYSROOT/usr/lib/aarch64-linux-android/libc++_shared.so" \
    -o "$TEST_OUTPUT/graphics_allocator_bridge_test"

# Camera ABI probe.  Keep this outside the installed vendor prebuilts until the exact camera
# client behavior has been validated on-device.  The SONAME is the original
# one so the artifact can be checked against libexynoscamera3.so without
# replacing the production mapper.
CAMERA_MAPPER_TEST="$TEST_OUTPUT/libGrallocMapperCamera.compat.so"
"$CXX" "${COMMON_FLAGS[@]}" -shared "$ROOT/src/camera_mapper_compat.cpp" \
    -Wl,-soname,libGrallocMapperCamera.so "${COMMON_LINK[@]}" -static-libstdc++ \
    -o "$CAMERA_MAPPER_TEST"

INTERNAL_FORMAT_PROBE="$TEST_OUTPUT/internal_format_probe"
"$CXX" "${COMMON_FLAGS[@]}" "$ROOT/src/internal_format_probe.cpp" \
    -L"$OUTPUT/lib64" -lexynos990_graphics_compat "${COMMON_LINK[@]}" \
    -static-libstdc++ -o "$INTERNAL_FORMAT_PROBE"

# Exercita o mesmo caminho de clientes do framework (AHardwareBuffer_lockPlanes
# -> GraphicBufferMapper::lockYCbCr -> Gralloc5 -> mapper) para YUV.
AHB_YCBCR_PROBE="$TEST_OUTPUT/ahb_ycbcr_probe"
"$CXX" "${COMMON_FLAGS[@]}" -fPIE -pie "$ROOT/src/ahb_ycbcr_probe.cpp" \
    -landroid -lnativewindow -static-libstdc++ -o "$AHB_YCBCR_PROBE"

Y2S_MODIFIER_PROBE="$TEST_OUTPUT/y2s_modifier_probe"
"$CXX" "${COMMON_FLAGS[@]}" "$ROOT/src/y2s_modifier_probe.cpp" \
    -static-libstdc++ -o "$Y2S_MODIFIER_PROBE"

MAPPER_MODIFIER_PROBE="$TEST_OUTPUT/mapper_modifier_probe"
"$CXX" "${COMMON_FLAGS[@]}" "$ROOT/src/mapper_modifier_probe.cpp" \
    -L"$OUTPUT/lib64" -lexynos990_graphics_compat "${COMMON_LINK[@]}" \
    -static-libstdc++ -o "$MAPPER_MODIFIER_PROBE"

"$STRIP" --strip-unneeded \
    "$COMPAT_LIB" \
    "$OUTPUT/lib64/hw/mapper.exynos990_compat.so" \
    "$OUTPUT/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990" \
    "$TEST_OUTPUT/graphics_allocator_bridge_test" \
    "$CAMERA_MAPPER_TEST" \
    "$INTERNAL_FORMAT_PROBE" \
    "$AHB_YCBCR_PROBE" \
    "$Y2S_MODIFIER_PROBE" \
    "$MAPPER_MODIFIER_PROBE"

# Do not use grep -q here: with pipefail, file/nm can receive SIGPIPE after
# grep exits early and make a successful build return status 141.
file "$OUTPUT/lib64/hw/mapper.exynos990_compat.so" | grep 'ARM aarch64' >/dev/null
file "$OUTPUT/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990" | grep 'ARM aarch64' >/dev/null
file "$COMPAT_LIB" | grep 'ARM aarch64' >/dev/null
file "$CAMERA_MAPPER_TEST" | grep 'ARM aarch64' >/dev/null
file "$INTERNAL_FORMAT_PROBE" | grep 'ARM aarch64' >/dev/null
file "$Y2S_MODIFIER_PROBE" | grep 'ARM aarch64' >/dev/null
file "$MAPPER_MODIFIER_PROBE" | grep 'ARM aarch64' >/dev/null
nm -D "$OUTPUT/lib64/hw/mapper.exynos990_compat.so" | grep ' AIMapper_loadIMapper$' >/dev/null
nm -D "$OUTPUT/lib64/hw/mapper.exynos990_compat.so" | grep ' ANDROID_HAL_STABLEC_VERSION$' >/dev/null
nm -D "$COMPAT_LIB" | grep ' exynos990_gralloc_backend$' >/dev/null
nm -D "$CAMERA_MAPPER_TEST" | grep '_ZNK7android19GrallocMapperCamera6Mapper4lock' >/dev/null
nm -D "$CAMERA_MAPPER_TEST" | grep '_ZNK7android19GrallocMapperCamera6Mapper6unlock' >/dev/null
readelf -d "$CAMERA_MAPPER_TEST" | grep -q 'libGrallocMapperCamera.so' 
strings "$CAMERA_MAPPER_TEST" | grep -Fqx '/vendor/lib64/hw/mapper.exynos990_compat.so'
nm -D "$OUTPUT/lib64/hw/mapper.exynos990_compat.so" | \
    grep ' exynos990_aidl_camera_lock_ycbcr$' >/dev/null

# The camera client has a small, stable dependency surface. Verify every
# mapper symbol it requests before considering the test artifact usable.
CAMERA_HAL="$REPO/out/target/y2s/work_dir/vendor/lib64/libexynoscamera3.so"
if [ -f "$CAMERA_HAL" ]; then
    while read -r symbol; do
        [ -z "$symbol" ] && continue
        nm -D --defined-only "$CAMERA_MAPPER_TEST" | awk '{print $3}' | \
            grep -Fqx "$symbol" || {
                echo "Camera mapper ABI symbol missing: $symbol" >&2
                exit 1
            }
    done < <(nm -D --undefined-only "$CAMERA_HAL" | awk '/GrallocMapperCamera/{print $2}')
fi

echo "Built and verified against $PLATFORM_LIBS_SOURCE ($PLATFORM_LIBS):"
sha256sum "$COMPAT_LIB" "$OUTPUT/lib64/hw/mapper.exynos990_compat.so" \
    "$OUTPUT/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990" \
    "$CAMERA_MAPPER_TEST" "$Y2S_MODIFIER_PROBE" "$MAPPER_MODIFIER_PROBE"
rm -rf "$BUILD"

