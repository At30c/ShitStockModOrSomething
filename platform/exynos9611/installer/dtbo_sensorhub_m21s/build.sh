#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DTBO_IMAGE="${1:-$SRC_DIR/out/target/m21s/work_dir/kernel/dtbo.img}"
OUTPUT="${2:-$SRC_DIR/out/target/m21s/m21s-dtbo-sensorhub-m21-test.zip}"
OUTPUT="$(readlink -m "$OUTPUT")"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[ -s "$DTBO_IMAGE" ] || {
    echo "DTBO image not found or empty: $DTBO_IMAGE" >&2
    exit 1
}

# Samsung's bootloader does not consume a bare flattened-device-tree overlay
# (magic d00dfeed). It requires the proprietary DT table container used by
# the stock dtbo partition (magic d7b7ab1e). Writing a raw kernel-built .dtbo
# makes Download mode report "DT LOAD Fail".
DTBO_MAGIC="$(xxd -p -l 4 "$DTBO_IMAGE")"
[ "$DTBO_MAGIC" = "d7b7ab1e" ] || {
    echo "Refusing non-Samsung DT table DTBO (magic: $DTBO_MAGIC)" >&2
    echo "Merge an M21 overlay into the stock DT table; do not flash a raw .dtbo." >&2
    exit 1
}

strings "$DTBO_IMAGE" > "$TMP_DIR/dtbo.strings"
grep -q 'sensorhub/shub_ramen_m21.fw' "$TMP_DIR/dtbo.strings" || {
    echo "Refusing DTBO without M21 sensorhub firmware reference" >&2
    exit 1
}
if grep -q 'sensorhub/shub_ramen_m31.fw' "$TMP_DIR/dtbo.strings"; then
    echo "Refusing DTBO that still references M31 sensorhub firmware" >&2
    exit 1
fi

mkdir -p "$TMP_DIR/META-INF/com/google/android" "$(dirname "$OUTPUT")"
cp "$SCRIPT_DIR/update-binary" "$TMP_DIR/META-INF/com/google/android/update-binary"
cp "$DTBO_IMAGE" "$TMP_DIR/dtbo.img"
sha256sum "$TMP_DIR/dtbo.img" > "$TMP_DIR/dtbo.img.sha256"
printf '# intentionally empty\n' > "$TMP_DIR/META-INF/com/google/android/updater-script"
chmod 0755 "$TMP_DIR/META-INF/com/google/android/update-binary"
(cd "$TMP_DIR" && zip -9qr "$OUTPUT" META-INF dtbo.img dtbo.img.sha256)
printf '%s\n' "$OUTPUT"
