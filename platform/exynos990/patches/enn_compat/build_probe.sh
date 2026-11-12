#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CXX="$TOOLCHAIN/bin/aarch64-linux-android30-clang++"
SYSROOT="$TOOLCHAIN/sysroot"
OUT="$ROOT/.build"

for tool in "$CXX" "$TOOLCHAIN/bin/llvm-strip"; do
    [ -x "$tool" ] || { echo "Missing tool: $tool" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT"
COMMON=(--sysroot="$SYSROOT" -std=c++20 -O2 -fPIC -Wall -Wextra -Werror
        -L"$SYSROOT/usr/lib/aarch64-linux-android/30" -llog -ldl)

"$CXX" "${COMMON[@]}" -shared "$ROOT/src/enn_compat.cpp" \
    -Wl,-soname,libenn_user_lib.so -Wl,--no-undefined \
    -o "$OUT/libenn_user_lib.so"
"$CXX" "${COMMON[@]}" -fPIE -pie "$ROOT/src/enn_probe.cpp" \
    -Wl,--no-undefined -o "$OUT/enn_probe"
"$CXX" "${COMMON[@]}" -fPIE -pie "$ROOT/src/eden_probe.cpp" \
    -Wl,--no-undefined -o "$OUT/eden_probe"
"$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$OUT/libenn_user_lib.so" "$OUT/enn_probe" "$OUT/eden_probe"

file "$OUT/libenn_user_lib.so" | grep -F 'ARM aarch64' >/dev/null
file "$OUT/enn_probe" | grep -F 'ARM aarch64' >/dev/null
file "$OUT/eden_probe" | grep -F 'ARM aarch64' >/dev/null
readelf -d "$OUT/libenn_user_lib.so" | grep -F 'libenn_user_lib.so' >/dev/null
nm -D "$OUT/libenn_user_lib.so" | grep -Fq ' EnnInitialize'
nm -D "$OUT/libenn_user_lib.so" | grep -Fq ' EnnDeinitialize'
echo "Built ENN compatibility probe: $OUT"
sha256sum "$OUT/libenn_user_lib.so" "$OUT/enn_probe" "$OUT/eden_probe"
