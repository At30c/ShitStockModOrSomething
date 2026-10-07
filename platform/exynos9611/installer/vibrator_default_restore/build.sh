#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SOURCE="$SRC_DIR/out/fw/SM-F415F_ZTO/vendor/lib64/hw/vibrator.default.so"
OUTPUT="${1:-$SRC_DIR/out/target/m21s/m21s-vibrator-default-restore.zip}"
OUTPUT="$(readlink -m "$OUTPUT")"
TMP_DIR="$(mktemp -d)"

cleanup() {
    find "$TMP_DIR" -depth -type f -delete 2>/dev/null || true
    find "$TMP_DIR" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT INT

[ -s "$SOURCE" ] || {
    echo "M21s original vibrator.default.so not found: $SOURCE" >&2
    exit 1
}

mkdir -p "$TMP_DIR/META-INF/com/google/android" "$TMP_DIR/payload/vendor/lib64/hw"
cp "$SOURCE" "$TMP_DIR/payload/vendor/lib64/hw/vibrator.default.so"
cp "$SCRIPT_DIR/update-binary" "$TMP_DIR/META-INF/com/google/android/update-binary"
printf '# intentionally empty\n' > "$TMP_DIR/META-INF/com/google/android/updater-script"
chmod 0755 "$TMP_DIR/META-INF/com/google/android/update-binary"
(cd "$TMP_DIR" && sha256sum payload/vendor/lib64/hw/vibrator.default.so > checksums.sha256)

mkdir -p "$(dirname "$OUTPUT")"
(cd "$TMP_DIR" && zip -9qr "$OUTPUT" META-INF payload checksums.sha256)
printf '%s\n' "$OUTPUT"
