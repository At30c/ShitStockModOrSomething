#!/usr/bin/env bash
set -euo pipefail

# Auditoria estática reproduzível do provider AIDL V1 do Galaxy A26 5G.
# Uso:
#   ./disassemble_a26_aidl_v1.sh [caminho/para/vendor]
# Não executa blobs nem grava na vendor estudada.

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
VENDOR="${1:-$REPO/out/a26_vendor_a266b_eux/vendor}"
PROVIDER="$VENDOR/bin/hw/vendor.samsung.hardware.camera.provider-service_64"

[ -f "$PROVIDER" ] || {
    echo "Provider A26 não encontrado: $PROVIDER" >&2
    exit 1
}

for tool in readelf nm strings c++filt; do
    command -v "$tool" >/dev/null || {
        echo "Ferramenta ausente: $tool" >&2
        exit 1
    }
done

echo '# ELF e dependências'
file "$PROVIDER"
readelf -dW "$PROVIDER" | grep -E 'NEEDED|SONAME'

echo
echo '# Cadeia Camera Provider/Device/Session'
readelf -Ws "$PROVIDER" | c++filt | \
    grep -E 'CameraProvider|CameraDevice(Session)?|ConfigureStreams|ProcessCaptureRequest|SignalStreamFlush|RequestStreamBuffers|ReturnStreamBuffers|TriggerDeferredCallbacks|InitializeBufferMapper' || true

echo
echo '# Contratos e conversores publicados como strings'
strings -a "$PROVIDER" | \
    grep -E 'AidlCamera|ConvertToAidl|CreateMetadataQueue|WriteToResultMetadataQueue|RequestStreamBuffers|ReturnStreamBuffers|mapper@[234]\.0' || true

echo
echo '# VINTF e init'
sed -n '1,120p' "$VENDOR/etc/vintf/manifest/vendor.samsung.hardware.camera.provider-service.xml"
sed -n '1,160p' "$VENDOR/etc/init/vendor.samsung.hardware.camera.provider-service_64.rc"
