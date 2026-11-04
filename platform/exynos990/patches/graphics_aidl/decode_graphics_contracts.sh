#!/usr/bin/env bash
#
# Auditoria somente leitura dos contratos gráficos y2s e S26+. O relatório é
# escrito em stdout para poder ser arquivado sem tocar na work_dir ou na vendor.
#
set -u
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
BRIEF=0

if [ "${1:-}" = "--brief" ]; then
    BRIEF=1
    shift
fi

Y2S_VENDOR="${1:-$ROOT/out/target/y2s/vendor-gralloc5-20261025}"
S26_VENDOR="${2:-$ROOT/out/fw/SM-S947B_EUX/vendor}"
if [ ! -d "$Y2S_VENDOR" ]; then
    Y2S_VENDOR="$ROOT/out/target/y2s/work_dir/vendor"
fi

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ferramenta ausente: $1" >&2
        exit 2
    }
}

for tool in file sha256sum readelf c++filt strings rg; do
    require_tool "$tool"
done

show_elf() {
    local title="$1" path="$2"
    echo
    echo "### $title"
    if [ ! -f "$path" ]; then
        echo "AUSENTE: $path"
        return 0
    fi
    echo "arquivo: $path"
    sha256sum "$path"
    file "$path"
    echo "-- SONAME e DT_NEEDED --"
    readelf -d "$path" 2>/dev/null | awk '/SONAME|NEEDED/{print}' || true
    echo "-- símbolos definidos --"
    if [ "$BRIEF" -eq 1 ]; then
        readelf -Ws "$path" 2>/dev/null | awk '$7 != "UND" {print $8}' |
            c++filt | rg -i 'gralloc|mapper|allocator|composer|hwc|display|layer|lock|ion|format' |
            sort -u || true
    else
        readelf -Ws "$path" 2>/dev/null | c++filt || true
    fi
    echo "-- símbolos indefinidos --"
    if [ "$BRIEF" -eq 1 ]; then
        readelf -Ws "$path" 2>/dev/null | awk '$7 == "UND" {print $8}' |
            c++filt | sort -u || true
    else
        readelf -Ws "$path" 2>/dev/null | awk '$7 == "UND" {print}' | c++filt || true
    fi
}

echo "Auditoria de decodificação gráfica (somente leitura)"
echo "root=$ROOT"
echo "y2s_vendor=$Y2S_VENDOR"
echo "s26_vendor=$S26_VENDOR"
echo "modo=$([ "$BRIEF" -eq 1 ] && echo resumido || echo completo)"

show_elf "y2s Gralloc1/Mali" "$Y2S_VENDOR/lib64/hw/gralloc.exynos990.so"
show_elf "y2s ExynosGraphicBufferMeta" "$Y2S_VENDOR/lib64/libexynosgraphicbuffer.so"
show_elf "y2s Mapper HIDL 2.1" "$Y2S_VENDOR/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so"
show_elf "y2s Mapper privado da câmera" "$Y2S_VENDOR/lib64/libGrallocMapperCamera.so"
show_elf "y2s HWC2" "$Y2S_VENDOR/lib64/hw/hwcomposer.exynos990.so"
show_elf "S26+ mapper Stable-C SGR" "$S26_VENDOR/lib64/hw/mapper.stableC-impl-sgr.so"
show_elf "S26+ allocator AIDL SGR" "$S26_VENDOR/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr"
show_elf "S26+ Composer3" "$S26_VENDOR/bin/hw/android.hardware.graphics.composer3-service.exynos"

echo
echo "### VINTF e init do y2s"
for base in "$Y2S_VENDOR/etc/vintf" "$Y2S_VENDOR/etc/init"; do
    [ -e "$base" ] || continue
    rg -n -C 2 'android\.hardware\.graphics\.(allocator|mapper|composer)' "$base" 2>/dev/null || true
done

echo
echo "### SELinux do y2s"
rg -n 'graphics|gralloc|mapper\.exynos990|composer3' \
    "$Y2S_VENDOR/etc/selinux/vendor_file_contexts" \
    "$Y2S_VENDOR/etc/selinux/vendor_service_contexts" 2>/dev/null || true

echo
echo "### Strings de contrato do Gralloc1 y2s"
G="$Y2S_VENDOR/lib64/hw/gralloc.exynos990.so"
if [ -f "$G" ]; then
    strings -a "$G" | rg -i 'AFBC|flex|secure buffer|invalid handle|lock is not supported|YUV compatible' || true
fi

echo
echo "### Trechos estáticos conhecidos (somente a hash auditada)"
C="$Y2S_VENDOR/lib64/libGrallocMapperCamera.so"
if command -v llvm-objdump-21 >/dev/null 2>&1 && [ -f "$C" ] && \
   [ "$(sha256sum "$C" | awk '{print $1}')" = "2d4fd0175db7be753a8802bea85e057fd4bb727f5ed255429d78ff860d6eb482" ]; then
    echo "-- Mapper::lock(YCbCr): 0x7aec --"
    llvm-objdump-21 -d --demangle --start-address=0x7aec --stop-address=0x7d90 "$C"
    echo "-- mali_gralloc_lock_flex_async: 0x6adc --"
    llvm-objdump-21 -d --demangle --start-address=0x6adc --stop-address=0x6c90 "$C"
else
    echo "pulados: llvm-objdump-21 ausente ou hash do mapper de câmera diverge"
fi

echo
echo "### Campos de ExynosGraphicBufferMeta (somente a hash auditada)"
M="$Y2S_VENDOR/lib64/libexynosgraphicbuffer.so"
if [ -f "$M" ] && [ "$(sha256sum "$M" | awk '{print $1}')" = \
     "0da060a9fe7ee620143322f96a4d4837f00fef01d2dd403141dd691d60086caf" ]; then
    OBJDUMP=""
    if command -v llvm-objdump-21 >/dev/null 2>&1; then
        OBJDUMP="llvm-objdump-21"
    elif command -v llvm-objdump >/dev/null 2>&1; then
        OBJDUMP="llvm-objdump"
    fi
    if [ -n "$OBJDUMP" ]; then
        echo "-- is_afbc/get_format/get_internal_format/get_frameworkFormat --"
        "$OBJDUMP" -d --demangle --start-address=0x2988 --stop-address=0x29c0 "$M"
        echo "-- stride/vstride/usage accessors --"
        "$OBJDUMP" -d --demangle --start-address=0x29c0 --stop-address=0x2a80 "$M"
    else
        echo "pulados: llvm-objdump não encontrado"
    fi
else
    echo "pulados: libexynosgraphicbuffer ausente ou hash diverge"
fi

echo
echo "Fim da auditoria. Nenhuma imagem, partição ou arquivo da vendor foi alterado."
