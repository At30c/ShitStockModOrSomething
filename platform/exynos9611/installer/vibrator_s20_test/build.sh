#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DONOR="$SRC_DIR/prebuilts/samsung/y2sxxx"
OUTPUT="${1:-$SRC_DIR/out/target/m21s/m21s-vibrator-s20-test.zip}"
OUTPUT="$(readlink -m "$OUTPUT")"
TMP_DIR="$(mktemp -d)"

cleanup() {
    find "$TMP_DIR" -depth -type f -delete 2>/dev/null || true
    find "$TMP_DIR" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT INT

copy_payload() {
    local source="$1"
    local rel="$2"
    [ -s "$DONOR/$source" ] || {
        echo "S20+ vibrator prebuilt ausente: $DONOR/$source" >&2
        exit 1
    }
    mkdir -p "$TMP_DIR/payload/$(dirname "$rel")"
    cp "$DONOR/$source" "$TMP_DIR/payload/$rel"
}

copy_payload "vendor/bin/hw/vendor.samsung.hardware.vibrator@2.2-service" \
    "vendor/bin/hw/vendor.samsung.hardware.vibrator@2.2-service"
copy_payload "vendor/etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc" \
    "vendor/etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc"

for version in 1.0 1.1 1.2 1.3; do
    # The S20+ stores these HIDL interface libraries in system, while the
    # M21s vendor linker path expects them in /vendor/lib64.
    copy_payload "system/system/lib64/android.hardware.vibrator@${version}.so" \
        "vendor/lib64/android.hardware.vibrator@${version}.so"
done

for version in 2.0 2.1 2.2; do
    copy_payload "vendor/lib64/vendor.samsung.hardware.vibrator@${version}.so" \
        "vendor/lib64/vendor.samsung.hardware.vibrator@${version}.so"
done

mkdir -p "$TMP_DIR/META-INF/com/google/android"
cp "$SCRIPT_DIR/update-binary" "$TMP_DIR/META-INF/com/google/android/update-binary"
printf '# intentionally empty\n' > "$TMP_DIR/META-INF/com/google/android/updater-script"
chmod 0755 "$TMP_DIR/META-INF/com/google/android/update-binary"

(cd "$TMP_DIR" && sha256sum payload/vendor/bin/hw/vendor.samsung.hardware.vibrator@2.2-service \
    payload/vendor/etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc \
    payload/vendor/lib64/android.hardware.vibrator@1.0.so \
    payload/vendor/lib64/android.hardware.vibrator@1.1.so \
    payload/vendor/lib64/android.hardware.vibrator@1.2.so \
    payload/vendor/lib64/android.hardware.vibrator@1.3.so \
    payload/vendor/lib64/vendor.samsung.hardware.vibrator@2.0.so \
    payload/vendor/lib64/vendor.samsung.hardware.vibrator@2.1.so \
    payload/vendor/lib64/vendor.samsung.hardware.vibrator@2.2.so) > "$TMP_DIR/checksums.sha256"

cat > "$TMP_DIR/README.txt" <<'EOF'
M21s vibrator HAL S20+ test

This test replaces only the vendor-side Samsung HIDL vibrator service and its
64-bit dependencies from SM-G986B AUT. It deliberately keeps the Android
framework vibrator libraries unchanged. The installer saves replaced files
under /sdcard/m21s-vibrator-s20-backup-<timestamp>.
EOF

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$TMP_DIR" && zip -9qr "$OUTPUT" META-INF payload checksums.sha256 README.txt)
printf '%s\n' "$OUTPUT"
