#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
FIRMWARE="${1:-$SRC_DIR/out/kernel_tmp-exynos9611/firmware/sensorhub/shub_ramen_m31.fw}"
OUTPUT="${2:-$SRC_DIR/out/target/m21s/m21s-sensorhub-m31-firmware-test.zip}"
OUTPUT="$(readlink -m "$OUTPUT")"
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

[ -s "$FIRMWARE" ] || {
    echo "M31 sensorhub firmware not found: $FIRMWARE" >&2
    exit 1
}

mkdir -p "$TMP_DIR/META-INF/com/google/android" "$TMP_DIR/vendor/firmware/sensorhub" "$(dirname "$OUTPUT")"
cp "$SCRIPT_DIR/update-binary" "$TMP_DIR/META-INF/com/google/android/update-binary"
cp "$FIRMWARE" "$TMP_DIR/vendor/firmware/sensorhub/shub_ramen_m31.fw"
sha256sum "$TMP_DIR/vendor/firmware/sensorhub/shub_ramen_m31.fw" > "$TMP_DIR/firmware.sha256"
printf '# intentionally empty\n' > "$TMP_DIR/META-INF/com/google/android/updater-script"
chmod 0755 "$TMP_DIR/META-INF/com/google/android/update-binary"
(cd "$TMP_DIR" && zip -9qr "$OUTPUT" META-INF vendor firmware.sha256)
printf '%s\n' "$OUTPUT"
