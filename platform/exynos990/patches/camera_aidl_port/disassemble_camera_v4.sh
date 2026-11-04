#!/usr/bin/env bash
set -euo pipefail

# Auditoria estática das bibliotecas AIDL V4 da câmera. Este script não
# executa código da vendor nem tenta converter os blobs proprietários; ele
# registra ABI ELF, dependências, símbolos NDK e referências aos contratos
# úteis para o adaptador do S20+.
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
LIBDIR="${1:-$REPO/out/target/y2s/work_dir/system/system/lib64}"
OUT="${2:-/tmp/camera-v4-disassembly.txt}"
OBJDUMP="${LLVM_OBJDUMP:-}"
if [ -z "$OBJDUMP" ]; then
    OBJDUMP="$(command -v llvm-objdump || true)"
fi
[ -n "$OBJDUMP" ] && [ -x "$OBJDUMP" ] || {
    echo "llvm-objdump não encontrado; defina LLVM_OBJDUMP" >&2
    exit 1
}

DEVICE="$LIBDIR/android.hardware.camera.device-V4-ndk.so"
PROVIDER="$LIBDIR/android.hardware.camera.provider-V4-ndk.so"
[ -r "$DEVICE" ] || { echo "Biblioteca ausente: $DEVICE" >&2; exit 1; }
[ -r "$PROVIDER" ] || { echo "Biblioteca ausente: $PROVIDER" >&2; exit 1; }

{
    printf '%s\n' '# Desmontagem estática Camera AIDL V4'
    printf 'Data UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'LIBDIR: %s\n\n' "$LIBDIR"
    for lib in "$DEVICE" "$PROVIDER"; do
        printf '\n=== %s ===\n' "$(basename "$lib")"
        sha256sum "$lib"
        file "$lib"
        readelf -h "$lib" | rg 'Class|Machine|Type|Entry'
        printf '%s\n' '-- NEEDED/SONAME --'
        readelf -d "$lib" | rg 'NEEDED|SONAME|RUNPATH|RPATH' || true
        printf '%s\n' '-- descritores AIDL --'
        strings -a "$lib" | rg '^android\.hardware\.(camera|common)' | sort -u || true
        printf '%s\n' '-- objetos e métodos AIDL NDK --'
        nm -D --defined-only "$lib" | c++filt | rg 'aidl::android::hardware::camera::(device|provider)::(Bp|Bn|ICamera|.*::(readFromParcel|writeToParcel))' | sed -E 's/^[0-9a-f]+ [A-Z] //' | sort -u || true
        printf '%s\n' '-- referências a transporte --'
        strings -a "$lib" | rg -i 'FMQ|BufferCache|NativeHandle|Fence|physical|offline|configureStreams|processCaptureRequest|processCaptureResult|signalStreamFlush|switchToOffline|requestStreamBuffers|returnStreamBuffers|StreamGroupState' | sort -u || true
        printf '%s\n' '-- instruções dos proxies getInterfaceVersion/Hash --'
        symbols=$(nm -D --defined-only "$lib" | c++filt | rg '::(Bp|Bn).+::getInterface(Version|Hash)' | sed -E 's/^[0-9a-f]+ [A-Z] //' | sort -u || true)
        while IFS= read -r symbol; do
            [ -n "$symbol" ] || continue
            printf '\n[%s]\n' "$symbol"
            "$OBJDUMP" -d --demangle --symbolize-operands "$lib" 2>/dev/null | rg -A28 -F "<$symbol>:" | head -30 || true
        done <<< "$symbols"
    done
} > "$OUT"

printf '%s\n' "$OUT"
