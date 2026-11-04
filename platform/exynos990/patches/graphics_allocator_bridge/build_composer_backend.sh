#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CXX="$TOOLCHAIN/bin/aarch64-linux-android30-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
SYSROOT="$TOOLCHAIN/sysroot"
PLATFORM_LIBS="${TARGET_SYSTEM_LIBS:-$REPO/out/target/y2s/work_dir/system/system/lib64}"
OUTPUT="$ROOT/prebuilt/test"

[ -x "$CXX" ] || { echo "Missing compiler: $CXX" >&2; exit 1; }
for lib in libhardware.so liblog.so; do
    [ -f "$PLATFORM_LIBS/$lib" ] || {
        echo "Missing Android arm64 link library: $PLATFORM_LIBS/$lib" >&2
        exit 1
    }
done

mkdir -p "$OUTPUT"
COMMON_FLAGS=(
    --sysroot="$SYSROOT" -std=c++20 -O2 -fPIC -fvisibility=hidden
    -Wall -Wextra -Werror -Wno-error=deprecated-declarations
    -I"$ROOT/include" -I"$ROOT/src"
)
COMMON_LINK=(
    -L"$PLATFORM_LIBS" -L"$SYSROOT/usr/lib/aarch64-linux-android/30"
    -Wl,--no-undefined -Wl,--build-id=sha1
    -lhardware -llog -ldl
)

"$CXX" "${COMMON_FLAGS[@]}" -shared "$ROOT/src/hwc2_backend.cpp" \
    "$ROOT/src/hwc2_backend_state.cpp" \
    -Wl,-soname,libexynos990_hwc2_backend.so "${COMMON_LINK[@]}" "$PLATFORM_LIBS/libc++.so" \
    -o "$OUTPUT/libexynos990_hwc2_backend.so"

"$CXX" "${COMMON_FLAGS[@]}" "$ROOT/src/hwc2_backend_probe.cpp" \
    "$ROOT/src/hwc2_backend.cpp" "${COMMON_LINK[@]}" "$PLATFORM_LIBS/libc++.so" \
    -o "$OUTPUT/hwc2_backend_probe"

"$STRIP" --strip-unneeded "$OUTPUT/libexynos990_hwc2_backend.so" "$OUTPUT/hwc2_backend_probe"
file "$OUTPUT/libexynos990_hwc2_backend.so" | grep -q 'ARM aarch64'
file "$OUTPUT/hwc2_backend_probe" | grep -q 'ARM aarch64'
readelf -d "$OUTPUT/libexynos990_hwc2_backend.so" | grep -q 'libhardware.so'
nm -D "$OUTPUT/libexynos990_hwc2_backend.so" | grep -q ' exynos990_hwc2_query_display$'
nm -D "$OUTPUT/libexynos990_hwc2_backend.so" | grep -q ' exynos990_hwc2_session_open$'

echo "Built HWC2 backend query library against $PLATFORM_LIBS:"
sha256sum "$OUTPUT/libexynos990_hwc2_backend.so" "$OUTPUT/hwc2_backend_probe"
