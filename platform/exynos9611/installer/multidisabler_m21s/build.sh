#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/m21s-android17-multidisabler.zip}"
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$PWD/$OUTPUT"
fi
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/META-INF/com/google/android"
cp "$SCRIPT_DIR/update-binary" "$TMP_DIR/META-INF/com/google/android/update-binary"
cp "$SCRIPT_DIR/fstab.exynos9611" "$TMP_DIR/fstab.exynos9611"
printf '# intentionally empty\n' > "$TMP_DIR/META-INF/com/google/android/updater-script"
chmod 0755 "$TMP_DIR/META-INF/com/google/android/update-binary"

mkdir -p "$(dirname "$OUTPUT")"
(cd "$TMP_DIR" && zip -9qr "$OUTPUT" META-INF fstab.exynos9611)
echo "$OUTPUT"
