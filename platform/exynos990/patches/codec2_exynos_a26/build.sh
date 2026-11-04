#!/usr/bin/env bash
# Builds the A26 Exynos Codec2 compatibility shim and the decode probe, and
# stages the A26 Codec2 chain with the import renames the shim requires.
#
#   build.sh [a26-vendor-dir] [y2s-vendor-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
NDK="${ANDROID_NDK_ROOT:-/home/ats0c/.android-sdk/ndk/29.0.14206865}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
CXX="$TOOLCHAIN/bin/aarch64-linux-android30-clang++"
STRIP="$TOOLCHAIN/bin/llvm-strip"
A26_VENDOR="${1:-$REPO/out/a26_vendor_a266b_eux/vendor}"
Y2S_VENDOR="${2:-$REPO/out/fw/SM-G986B_AUT/vendor}"
BUILD="$ROOT/.build"
OUTPUT="$REPO/prebuilts/exynos990/codec2_exynos_a26"

for tool in "$CXX" patchelf; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done

rm -rf "$BUILD" "$OUTPUT"
mkdir -p "$BUILD" "$OUTPUT/vendor/lib64" "$OUTPUT/vendor/bin/hw" "$OUTPUT/test"

# The shim resolves the 990 libexynosgraphicbuffer accessors at runtime.
"$CXX" -std=c++20 -Os -fPIC -fno-rtti -fno-exceptions -fvisibility=hidden -ffunction-sections -fdata-sections -Wall -Wextra -Werror \
    -shared -nostdlib++ -Wl,-soname,libc2compat26.so -Wl,--no-undefined \
    -Wl,--allow-shlib-undefined -Wl,--exclude-libs,ALL -Wl,--gc-sections \
    "$ROOT/src/c2_a26_compat.cpp" "$Y2S_VENDOR/lib64/libexynosgraphicbuffer.so" -llog \
    -o "$OUTPUT/vendor/lib64/libc2compat26.so"
"$STRIP" --strip-unneeded "$OUTPUT/vendor/lib64/libc2compat26.so"

"$CXX" -std=c++20 -O2 -fPIE -pie -Wall -Wextra -Werror -static-libstdc++ \
    "$ROOT/test/c2_decode_probe.cpp" -lmediandk -o "$OUTPUT/test/c2_decode_probe"
"$STRIP" "$OUTPUT/test/c2_decode_probe"

# A26 Codec2 chain.
A26_LIBS=(
    android.hardware.media.c2@1.2.so
    libcodec2_hidl@1.0.so libcodec2_hidl@1.1.so libcodec2_hidl@1.2.so
    libcodec2_hidl_plugin.so libcodec2_vndk.so libsfplugin_ccodec_utils.so
    libExynosC2ComponentStore.so
    libExynosC2H264Dec.so libExynosC2HevcDec.so libExynosC2Vp9Dec.so
    libavservices_minijail.so
)
for lib in "${A26_LIBS[@]}"; do
    cp "$A26_VENDOR/lib64/$lib" "$OUTPUT/vendor/lib64/$lib"
done
cp "$A26_VENDOR/bin/hw/samsung.hardware.media.c2@1.2-service" "$OUTPUT/vendor/bin/hw/"
mkdir -p "$OUTPUT/vendor/etc/seccomp_policy"
cp "$A26_VENDOR/etc/seccomp_policy/codec2.vendor.base.policy" \
    "$A26_VENDOR/etc/seccomp_policy/codec2.vendor.ext.policy" "$OUTPUT/vendor/etc/seccomp_policy/"

# Route the Android 12+ Fence ABI used inline by libcodec2_vndk to the shim
# and load the shim in place of libdmabufheap (absent from VNDK 30).  The
# rewrite is in place and length preserving; see patch_dynstr.py.
python3 "$ROOT/patch_dynstr.py" "$OUTPUT/vendor/lib64/libcodec2_vndk.so" \
    "_ZN7android5FenceC1Ei=_ZN7c2compa5FenceC1Ei" \
    "_ZN7android5Fence4waitEi=_ZN7c2compa5Fence4waitEi" \
    "_ZNK7android5Fence3dupEv=_ZNK7c2compa5Fence3dupEv" \
    "_ZTVN7android5FenceE=_ZTVN7c2compa5FenceE" \
    "libdmabufheap.so=libc2compat26.so" \
    "_ZN7android22GraphicBufferAllocator17allocateRawHandleEjjijmPPK13native_handlePjNSt3__112basic_stringIcNS6_11char_traitsIcEENS6_9allocatorIcEEEE=_ZN7c2compa22GraphicBufferAllocator17allocateRawHandleEjjijmPPK13native_handlePjNSt3__112basic_stringIcNS6_11char_traitsIcEENS6_9allocatorIcEEEE"

# Route the compressed-input S_FMT and the video-metadata fd lookup of every
# Exynos component through the shim.
for lib in libExynosC2H264Dec.so libExynosC2HevcDec.so libExynosC2Vp9Dec.so; do
    python3 "$ROOT/patch_dynstr.py" "$OUTPUT/vendor/lib64/$lib" \
        "exynos_v4l2_s_fmt=exynos_c2a6_s_fmt" \
        "exynos_v4l2_qbuf=exynos_c2a6_qbuf" \
        "exynos_v4l2_dqbuf=exynos_c2a6_dqbuf" \
        "exynos_v4l2_g_fmt=exynos_c2a6_g_fmt" \
        "exynos_v4l2_g_ctrl=exynos_c2a6_g_ctrl" \
        "epoll_ctl=c2a6epctl" "exynos_v4l2_streamon=exynos_c2a6_streamon" \
        "_ZN6vendor8graphics23ExynosGraphicBufferMeta21get_video_metadata_fdEPK13native_handle=_ZN6vendor8graphics23ExynosGraphicBufferMetc21get_video_metadata_fdEPK13native_handle"
done

# The chain is installed directly in /vendor/lib64.  init starts the service
# through an SELinux domain transition (AT_SECURE), so LD_LIBRARY_PATH is
# ignored; the four A26 libraries whose names collide with the 990 copies used
# by samsung.software.media.c2 are renamed (same length, DT_NEEDED + SONAME).
RENAMES=(
    "libcodec2_vndk.so=libcodec2_vn26.so"
    "libcodec2_hidl@1.0.so=libcodec2_h26l@1.0.so"
    "libcodec2_hidl@1.1.so=libcodec2_h26l@1.1.so"
    "libsfplugin_ccodec_utils.so=libsfplugin_ccodec_utl26.so"
)
for elf in "$OUTPUT"/vendor/lib64/*.so "$OUTPUT/vendor/bin/hw/samsung.hardware.media.c2@1.2-service"; do
    python3 "$ROOT/patch_dynstr.py" --optional "$elf" "${RENAMES[@]}"
done
for spec in "${RENAMES[@]}"; do
    mv "$OUTPUT/vendor/lib64/${spec%%=*}" "$OUTPUT/vendor/lib64/${spec#*=}"
done

( cd "$OUTPUT" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$OUTPUT/SHA256SUMS"
echo "Staged A26 Codec2 chain in $OUTPUT"
