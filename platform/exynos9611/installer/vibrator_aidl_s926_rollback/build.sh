#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OUTPUT="${1:-$SRC_DIR/out/target/m21s/m21s-vibrator-aidl-s926-remove-v2.zip}"
OUTPUT="$(readlink -m "$OUTPUT")"
TMP_DIR="$(mktemp -d)"

cleanup() {
    find "$TMP_DIR" -depth -type f -delete 2>/dev/null || true
    find "$TMP_DIR" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT INT

mkdir -p "$TMP_DIR/META-INF/com/google/android"
cp "$SCRIPT_DIR/update-binary" "$TMP_DIR/META-INF/com/google/android/update-binary"
printf '# intentionally empty\n' > "$TMP_DIR/META-INF/com/google/android/updater-script"
chmod 0755 "$TMP_DIR/META-INF/com/google/android/update-binary"
cat > "$TMP_DIR/README.txt" <<'EOF'
M21s vibrator AIDL S926 experimental rollback v2

Move os cinco arquivos AIDL adicionados para:
/vendor/.m21s-vibrator-aidl-s926-disabled/

O movimento e reversivel pelo TWRP e preserva o serviço HIDL original do M21s.
EOF

mkdir -p "$(dirname "$OUTPUT")"
(cd "$TMP_DIR" && zip -9qr "$OUTPUT" META-INF README.txt)
printf '%s\n' "$OUTPUT"
