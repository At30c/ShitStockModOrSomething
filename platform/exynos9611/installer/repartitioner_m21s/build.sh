#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../../../.." && pwd)"
OUT_DIR="$REPO_DIR/out/target/m21s"
mkdir -p "$OUT_DIR"

command -v zip >/dev/null 2>&1 || {
    printf '%s\n' 'zip is required to package the repartitioner' >&2
    exit 1
}

OUTPUT="${1:-$OUT_DIR/m21s-repartitioner-experimental.zip}"
SUPERSIZE_MIB="${2:-11305}"
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac
case "$SUPERSIZE_MIB" in
    ''|*[!0-9]*) printf '%s\n' 'super size must be a positive integer in MiB' >&2; exit 1 ;;
esac
[ "$SUPERSIZE_MIB" -gt 0 ] || {
    printf '%s\n' 'super size must be greater than zero' >&2
    exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp -a "$ROOT_DIR/META-INF" "$ROOT_DIR/sgdisk" "$TMP_DIR/"
cp -a "$ROOT_DIR/repartition.sh" "$TMP_DIR/repartition.sh"
sed -i -E "s/^SUPERSIZE_MIB=.*/SUPERSIZE_MIB=$SUPERSIZE_MIB/" \
    "$TMP_DIR/repartition.sh"
(
    cd "$TMP_DIR"
    zip -q -r "$OUTPUT" META-INF repartition.sh sgdisk
)
printf 'Created %s\n' "$OUTPUT"
