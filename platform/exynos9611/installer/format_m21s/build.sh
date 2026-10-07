#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$ROOT_DIR/../../../.." && pwd)"
OUT_DIR="$REPO_DIR/out/target/m21s"
mkdir -p "$OUT_DIR"

command -v zip >/dev/null 2>&1 || {
    printf '%s\n' 'zip is required to package the formatter' >&2
    exit 1
}

OUTPUT="$OUT_DIR/m21s-filesystem-formatter-experimental.zip"
(
    cd "$ROOT_DIR"
    zip -q -r "$OUTPUT" META-INF format.sh
)
printf 'Created %s\n' "$OUTPUT"
