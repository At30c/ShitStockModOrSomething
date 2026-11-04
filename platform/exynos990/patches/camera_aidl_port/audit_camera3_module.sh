#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$ROOT/src/camera3_module.cpp"
HEADER="$ROOT/src/camera3_module.h"

fail() { printf 'camera3-module: %s\n' "$*" >&2; exit 1; }

[ -f "$SOURCE" ] || fail 'wrapper Camera3 ausente'
[ -f "$HEADER" ] || fail 'contrato do wrapper Camera3 ausente'

if rg -n 'camera\.provider@|ISehCameraProvider|ICameraProvider@' "$SOURCE" "$HEADER"; then
    fail 'wrapper Camera3 contém dependência HIDL'
fi

for token in \
    'hw_get_module(CAMERA_HARDWARE_MODULE_ID' \
    'get_number_of_cameras' \
    'get_camera_info' \
    'methods->open' \
    'CAMERA_DEVICE_API_VERSION_3_2' \
    'notify_device_state_change' \
    'set_torch_mode' \
    'common.close'; do
    rg -Fq "$token" "$SOURCE" || fail "contrato Camera3 ausente: $token"
done

printf '%s\n' 'camera3-module: wrapper nativo auditado; não há dependência pública HIDL'
