#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/src/camera_session.cpp"
HEADER="$ROOT/src/camera_session.h"
fail() { printf 'camera-session: %s\n' "$*" >&2; exit 1; }

[ -f "$SOURCE" ] && [ -f "$HEADER" ] || fail 'classe ICameraDeviceSession ausente'
for method in create initialize close flush configureStreams processCaptureRequest \
              constructDefaultRequestSettings getCaptureRequestMetadataQueue \
              getCaptureResultMetadataQueue switchToOffline configureStreamsV2; do
    rg -Fq "CameraSession::$method" "$SOURCE" || fail "método de sessão ausente: $method"
done
for token in 'ops->initialize' 'ops->flush' 'ops->signal_stream_flush' 'module->close' 'active_'; do
    rg -Fq "$token" "$SOURCE" "$HEADER" || fail "ciclo Camera3 incompleto: $token"
done
for token in 'ops->process_capture_request' 'buffers_.acquire' 'buffers_.remove' \
             'validate_camera_metadata_structure' 'handleResult' 'handleNotify' \
             'CAMERA3_MSG_SHUTTER' 'CAMERA3_MSG_ERROR' \
             'request_stream_buffers' 'return_stream_buffers' \
             'handleRequestStreamBuffers' 'handleReturnStreamBuffers'; do
    rg -Fq "$token" "$SOURCE" || fail "ponte request/result incompleta: $token"
done
for token in 'CAMERA_DEVICE_API_VERSION_3_6' 'callbacks_.ops.request_stream_buffers' \
             'callbacks_.ops.return_stream_buffers'; do
    rg -Fq "$token" "$SOURCE" || fail "buffer manager sem guarda de versão Camera3: $token"
done
if rg -n 'camera\.provider@|ISehCameraProvider|ICameraProvider@' "$SOURCE" "$HEADER"; then
    fail 'ICameraDeviceSession contém dependência HIDL'
fi
printf '%s\n' 'camera-session: ciclo, requests inline e callback de resultado auditados'
