#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
GRAPHICS_ROOT="$ROOT/../graphics_allocator_bridge"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
SDK_ROOT="${ANDROID_SDK_ROOT:-/home/ats0c/.android-sdk}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CXX="$TOOLCHAIN/bin/aarch64-linux-android30-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
CC="$TOOLCHAIN/bin/aarch64-linux-android30-clang"
PATCHELF="${PATCHELF:-$(command -v patchelf || true)}"
SYSROOT="$TOOLCHAIN/sysroot"
SDK_BINDER_CPP="$SDK_ROOT/platforms/android-36/optional/libbinder_ndk_cpp"
PLATFORM_LIBS="${TARGET_SYSTEM_LIBS:-$REPO/out/target/y2s/work_dir/system/system/lib64}"
OUTPUT="$REPO/prebuilts/exynos990/composer3_hwc2_bridge/vendor"

[ -x "$CXX" ] || { echo "Missing compiler: $CXX" >&2; exit 1; }
[ -x "$STRIP" ] || { echo "Missing strip tool: $STRIP" >&2; exit 1; }
[ -x "$CC" ] || { echo "Missing C compiler: $CC" >&2; exit 1; }
[ -x "$PATCHELF" ] || { echo "Missing patchelf; required to add the private libc++ shim" >&2; exit 1; }
[ -d "$SDK_BINDER_CPP" ] || { echo "Missing binder headers: $SDK_BINDER_CPP" >&2; exit 1; }
for lib in libbinder_ndk.so libhardware.so liblog.so libcutils.so libc++.so \
           android.hardware.graphics.composer3-V5-ndk.so; do
    [ -f "$PLATFORM_LIBS/$lib" ] || {
        echo "Missing Android arm64 link library: $PLATFORM_LIBS/$lib" >&2
        exit 1
    }
done

"$GRAPHICS_ROOT/build_composer_aidl.sh"
mkdir -p "$OUTPUT/bin/hw" "$OUTPUT/lib64"
cp -f "$REPO/prebuilts/exynos990/graphics_allocator_bridge/test/libexynos990_composer3_contract.so" \
    "$OUTPUT/lib64/libexynos990_composer3_contract.so"

"$CC" --sysroot="$SYSROOT" -fPIC -shared -nostdlib -nodefaultlibs \
    -Wl,--no-undefined -Wl,--build-id=sha1 -Wl,-soname,libcomposer3_cxxshim.so \
    "$ROOT/src/composer3_cxxshim.c" -o "$OUTPUT/lib64/libcomposer3_cxxshim.so"

RUNTIME="$OUTPUT/lib64/android.hardware.graphics.composer3-V5-ndk.so"
[ -f "$RUNTIME" ] || {
    echo "Missing Composer3 AIDL V5 runtime prebuilt: $RUNTIME" >&2
    exit 1
}
if ! readelf -d "$RUNTIME" | grep -q 'libcomposer3_cxxshim.so'; then
    "$PATCHELF" --add-needed libcomposer3_cxxshim.so "$RUNTIME"
fi

COMMON_FLAGS=(
    --sysroot="$SYSROOT" -std=c++20 -O2 -fPIE -fvisibility=hidden
    -Wall -Wextra -Werror -Wno-error=deprecated-declarations
    -I"$SDK_BINDER_CPP"
)
COMMON_LINK=(
    -L"$PLATFORM_LIBS" -L"$OUTPUT/lib64"
    -Wl,--no-undefined -Wl,--build-id=sha1
    -lbinder_ndk -llog -ldl -lexynos990_composer3_contract
    -Wl,-rpath,'$ORIGIN/../../lib64'
)

"$CXX" "${COMMON_FLAGS[@]}" -fPIE -pie \
    "$ROOT/src/composer3_service_main.cpp" "${COMMON_LINK[@]}" \
    -o "$OUTPUT/bin/hw/android.hardware.graphics.composer3-service.exynos990"

"$STRIP" --strip-unneeded \
    "$OUTPUT/bin/hw/android.hardware.graphics.composer3-service.exynos990" \
    "$OUTPUT/lib64/libexynos990_composer3_contract.so"
file "$OUTPUT/bin/hw/android.hardware.graphics.composer3-service.exynos990" | grep -q 'ARM aarch64'
file "$OUTPUT/lib64/libexynos990_composer3_contract.so" | grep -q 'ARM aarch64'
readelf -d "$OUTPUT/bin/hw/android.hardware.graphics.composer3-service.exynos990" \
    | grep -q 'libexynos990_composer3_contract.so'
readelf -d "$OUTPUT/lib64/libexynos990_composer3_contract.so" \
    | grep -q 'android.hardware.graphics.composer3-V5-ndk.so'
readelf -d "$RUNTIME" | grep -q 'libcomposer3_cxxshim.so'

echo "Built installable Composer3 HWC2 module against $PLATFORM_LIBS:"
sha256sum "$OUTPUT/bin/hw/android.hardware.graphics.composer3-service.exynos990" \
    "$OUTPUT/lib64/libexynos990_composer3_contract.so"
