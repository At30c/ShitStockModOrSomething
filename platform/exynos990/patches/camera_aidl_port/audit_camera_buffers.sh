#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/src/camera_buffers.cpp"
HEADER="$ROOT/src/camera_buffers.h"
fail() { printf 'camera-buffers: %s\n' "$*" >&2; exit 1; }

[ -f "$SOURCE" ] && [ -f "$HEADER" ] || fail 'registro de buffers ausente'
for token in 'native_handle_create' 'native_handle_close' 'dup(' 'duplicateFence' \
             'takeReturned' 'inFlight' 'BufferCache'; do
    rg -Fq "$token" "$SOURCE" "$HEADER" || fail "contrato de ownership ausente: $token"
done
rg -Fq 'GraphicBufferMapper import failed; trying local compatibility fallback' "$SOURCE" ||
    fail 'importação padrão GraphicBufferMapper ausente'
rg -Fq 'Stable-C fallback' "$SOURCE" ||
    fail 'fallback Stable-C explícito ausente'
rg -Fq 'release_fence' "$ROOT/src/camera_session.cpp" ||
    fail 'callback não transfere release fence'
printf '%s\n' 'camera-buffers: handles, cache e fences auditados'
