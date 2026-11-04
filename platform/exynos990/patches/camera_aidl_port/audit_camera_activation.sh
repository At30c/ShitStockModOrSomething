#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
fail() { printf 'camera-activation: %s\n' "$*" >&2; exit 1; }

SERVICE="$ROOT/prebuilt/vendor/bin/hw/android.hardware.camera.provider-V4-service.exynos990"
RC="$ROOT/vendor/etc/init/android.hardware.camera.provider-V4-service.exynos990.rc"
VINTF="$ROOT/vendor/etc/vintf/manifest/android.hardware.camera.provider-exynos990.xml"
CUSTOMIZE="$ROOT/customize.sh"

for path in "$SERVICE" "$RC" "$VINTF" "$CUSTOMIZE"; do
    [ -f "$path" ] || fail "artefato de ativação ausente: ${path#$ROOT/}"
done

file "$SERVICE" | grep -F 'ARM aarch64' >/dev/null || fail 'serviço não é ELF arm64'
readelf -d "$SERVICE" | grep -F 'libcamera_metadata.so' >/dev/null ||
    fail 'serviço não liga camera_metadata'
readelf -d "$SERVICE" | grep -F 'libhardware.so' >/dev/null ||
    fail 'serviço não liga libhardware'
rg -Fq '/vendor/bin/hw/android.hardware.camera.provider-V4-service.exynos990' "$RC" ||
    fail 'rc não inicia o serviço AIDL correto'
rg -Fq 'android.hardware.camera.provider' "$VINTF" || fail 'fragmento VINTF não declara camera provider'
rg -Fq '<version>4</version>' "$VINTF" || fail 'fragmento VINTF não declara AIDL V4'
rg -Fq 'DELETE_FROM_WORK_DIR "vendor" "$OLD_RC"' "$CUSTOMIZE" ||
    fail 'customize não remove o rc HIDL em modo AIDL'
rg -Fq 'EXYNOS990_CAMERA_AIDL:-1' "$CUSTOMIZE" || fail 'modo AIDL padrão ausente'
printf '%s\n' 'camera-activation: ELF, init, VINTF e troca isolada HIDL→AIDL auditados'
