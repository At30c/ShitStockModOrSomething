#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
AIDL="${ANDROID_AIDL:-/home/ats0c/.android-sdk/build-tools/36.1.0/aidl}"
SDK_ROOT="${ANDROID_SDK_ROOT:-/home/ats0c/.android-sdk}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CXX="$TOOLCHAIN/bin/aarch64-linux-android30-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
SYSROOT="$TOOLCHAIN/sysroot"
SDK_BINDER_CPP="$SDK_ROOT/platforms/android-36/optional/libbinder_ndk_cpp"
PLATFORM_LIBS="${TARGET_SYSTEM_LIBS:-$REPO/out/target/y2s/work_dir/system/system/lib64}"
BUILD="$ROOT/.composer-build"
GEN="$BUILD/generated"
OUTPUT="$ROOT/prebuilt/test"

for tool in "$AIDL" "$CXX" "$STRIP"; do
    [ -x "$tool" ] || { echo "Missing tool: $tool" >&2; exit 1; }
done
for lib in libbinder_ndk.so libhardware.so liblog.so libcutils.so libc++.so \
           android.hardware.graphics.composer3-V5-ndk.so; do
    [ -f "$PLATFORM_LIBS/$lib" ] || {
        echo "Missing Android arm64 link library: $PLATFORM_LIBS/$lib" >&2
        exit 1
    }
done
[ -d "$SDK_BINDER_CPP" ] || { echo "Missing binder NDK C++ headers: $SDK_BINDER_CPP" >&2; exit 1; }

rm -rf "$BUILD"
mkdir -p "$OUTPUT"
mapfile -t AIDL_FILES < <(find "$ROOT/composer/aidl" -name '*.aidl' -type f | LC_ALL=C sort)
GEN_COUNT=0
for attempt in 1 2 3; do
    rm -rf "$GEN"
    mkdir -p "$GEN/include" "$GEN/src"
    "$AIDL" --lang=ndk --structured --stability=vintf --version=5 --min_sdk_version=30 \
        -I "$ROOT/composer/aidl" -h "$GEN/include" -o "$GEN/src" "${AIDL_FILES[@]}"
    GEN_COUNT="$(find "$GEN/src" -name '*.cpp' -type f | wc -l)"
    if [ "$GEN_COUNT" -eq 90 ] &&
       [ -f "$GEN/include/aidl/android/hardware/graphics/composer3/LutProperties.h" ]; then
        break
    fi
    echo "AIDL output incomplete on attempt $attempt ($GEN_COUNT/90); retrying" >&2
done
[ "$GEN_COUNT" -eq 90 ] || {
    echo "Composer3 AIDL generation incomplete: $GEN_COUNT/90 files" >&2
    exit 1
}
mapfile -t GENERATED_SOURCES < <(find "$GEN/src" -name '*.cpp' -type f | LC_ALL=C sort)

COMMON_FLAGS=(
    --sysroot="$SYSROOT" -std=c++20 -O2 -fPIC -fvisibility=hidden
    -Wall -Wextra -Werror -Wno-error=deprecated-declarations
    -I"$ROOT/include" -I"$ROOT/src" -I"$GEN/include" -I"$SDK_BINDER_CPP"
)
COMMON_LINK=(
    -L"$PLATFORM_LIBS" -L"$SYSROOT/usr/lib/aarch64-linux-android/30"
    -L"$ROOT/prebuilt/vendor/lib64"
    -Wl,--no-undefined -Wl,--build-id=sha1
    -lbinder_ndk -lhardware -llog -lcutils -ldl -lexynos990_graphics_compat
)

"$CXX" "${COMMON_FLAGS[@]}" -shared "$ROOT/src/composer3_contract.cpp" \
    "$ROOT/src/hwc2_backend.cpp" "$ROOT/src/hwc2_backend_state.cpp" \
    "${GENERATED_SOURCES[@]}" -Wl,-soname,libexynos990_composer3_contract.so \
    "${COMMON_LINK[@]}" "$PLATFORM_LIBS/android.hardware.graphics.composer3-V5-ndk.so" \
    -static-libstdc++ -o "$OUTPUT/libexynos990_composer3_contract.so"

cat > "$BUILD/composer3_contract_probe.cpp" <<'EOF'
#include <cstdint>
#include <cstdio>

extern "C" int exynos990_composer3_contract_probe(int32_t*, int32_t*);

int main() {
    int32_t composerVersion = 0;
    int32_t clientVersion = 0;
    const int status = exynos990_composer3_contract_probe(&composerVersion, &clientVersion);
    if (status != 0) {
        std::fprintf(stderr, "Composer3 contract probe failed: status=%d\n", status);
        return 1;
    }
    std::printf("Composer3 contract probe PASS composer=%d client=%d\n",
                composerVersion, clientVersion);
    return 0;
}
EOF

"$CXX" "${COMMON_FLAGS[@]}" "$BUILD/composer3_contract_probe.cpp" \
    -L"$OUTPUT" -lexynos990_composer3_contract \
    "${COMMON_LINK[@]}" "$PLATFORM_LIBS/android.hardware.graphics.composer3-V5-ndk.so" \
    -static-libstdc++ -Wl,-rpath,'$ORIGIN' -o "$OUTPUT/composer3_contract_probe"

"$STRIP" --strip-unneeded "$OUTPUT/libexynos990_composer3_contract.so" \
    "$OUTPUT/composer3_contract_probe"
file "$OUTPUT/libexynos990_composer3_contract.so" | grep -q 'ARM aarch64'
file "$OUTPUT/composer3_contract_probe" | grep -q 'ARM aarch64'
nm -D "$OUTPUT/libexynos990_composer3_contract.so" > "$BUILD/composer3.nm"
grep -q ' exynos990_composer3_contract_probe$' "$BUILD/composer3.nm"
readelf -d "$OUTPUT/libexynos990_composer3_contract.so" > "$BUILD/composer3.dynamic"
grep -q 'android.hardware.graphics.composer3-V5-ndk.so' "$BUILD/composer3.dynamic"

echo "Built Composer3 AIDL contract against $PLATFORM_LIBS:"
sha256sum "$OUTPUT/libexynos990_composer3_contract.so" "$OUTPUT/composer3_contract_probe"
rm -rf "$BUILD"
