#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/src/camera_streams.cpp"
HEADER="$ROOT/src/camera_streams.h"
fail() { printf 'camera-streams: %s\n' "$*" >&2; exit 1; }
[ -f "$SOURCE" ] && [ -f "$HEADER" ] || fail 'adaptador de streams ausente'
for token in 'camera3_stream_t' 'configure_streams' 'physical_camera_id' 'max_buffers' \
             'sessionParams.metadata.empty' 'streams_.clear'; do
    rg -Fq "$token" "$SOURCE" "$HEADER" || fail "contrato de stream ausente: $token"
done
rg -Fq 'std::map<int32_t, std::unique_ptr<SamsungCamera3Stream>> persistent_' "$HEADER" || fail 'lifetime do stream não é persistente'
# Streams mantidos entre configure_streams() precisam conservar o priv do HAL.
rg -Fq 'if (!retained) native.priv = nullptr;' "$SOURCE" || fail 'priv de stream retido não é preservado'
rg -Fq 'std::vector<camera3_stream_t*>' "$HEADER" || fail 'ponteiro Camera3 persistente ausente'
rg -Fq 'streamConfigCounter_' "$HEADER" || fail 'geração AIDL de stream ausente'
rg -Fq 'maximum-resolution stream' "$SOURCE" || fail 'modo máximo não é protegido'
rg -Fq 'multiResolutionInputImage is unsupported' "$SOURCE" || fail 'entrada multi-resolução não é protegida'
printf '%s\n' 'camera-streams: conversão e lifetime Camera3 auditados'
