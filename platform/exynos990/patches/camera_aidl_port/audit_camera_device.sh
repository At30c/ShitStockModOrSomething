#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/src/camera_device.cpp"
HEADER="$ROOT/src/camera_device.h"
fail() { printf 'camera-device: %s\n' "$*" >&2; exit 1; }

[ -f "$SOURCE" ] && [ -f "$HEADER" ] || fail 'classe ICameraDevice ausente'
for method in getCameraCharacteristics getResourceCost setTorchMode constructDefaultRequestSettings \
              isStreamCombinationSupported open warmUp; do
    rg -Fq "CameraDevice::$method" "$SOURCE" || fail "método AIDL V4 ausente: $method"
done
rg -Fq 'get_camera_metadata_size' "$SOURCE" || fail 'metadata não é copiada com tamanho nativo'
for token in 'CameraSession::create' 'EX_ILLEGAL_STATE' 'output->reset'; do
    rg -Fq "$token" "$SOURCE" || fail "open não assume a sessão Camera3: $token"
done
if rg -n 'camera\.provider@|ISehCameraProvider|ICameraProvider@' "$SOURCE" "$HEADER"; then
    fail 'ICameraDevice contém dependência HIDL'
fi
printf '%s\n' 'camera-device: superfície AIDL V4 e abertura de sessão auditadas'
