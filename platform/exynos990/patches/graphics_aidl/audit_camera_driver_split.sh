#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
WORK_DIR="${1:-$REPO/out/target/y2s/work_dir}"
CAMERA_HAL="$WORK_DIR/vendor/lib64/libexynoscamera3.so"
STOCK_GRALLOC="$WORK_DIR/vendor/lib64/hw/gralloc.exynos990.so"
S26_MAPPER="$REPO/out/fw/SM-S947B_EUX/vendor/lib64/hw/mapper.stableC-impl-sgr.so"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$ROOT/docs/CAMERA_DRIVER_SPLIT.md" ] || fail 'camadas da câmera não documentadas'
[ -f "$ROOT/src/camera_mapper_compat.cpp" ] || fail 'fachada HIDL ausente'
[ -f "$ROOT/src/mapper.cpp" ] || fail 'mapper AIDL ausente'
[ -f "$ROOT/src/allocator_service.cpp" ] || fail 'allocator AIDL ausente'
[ -f "$ROOT/include/exynos990/graphics_contract.h" ] || fail 'contrato Exynos ausente'
pass 'camadas de código presentes'

grep -q 'kAidlCameraOutput' "$ROOT/include/exynos990/graphics_contract.h" ||
    fail 'CAMERA_OUTPUT não está mapeado'
grep -q 'kAidlCameraInput' "$ROOT/include/exynos990/graphics_contract.h" ||
    fail 'CAMERA_INPUT não está mapeado'
grep -q 'kExynosCameraYuv = 0x11d' "$ROOT/include/exynos990/graphics_contract.h" ||
    fail 'formato privado 0x11d não está protegido'
grep -q 'kExynosCameraMotionYuv = 0x11e' "$ROOT/include/exynos990/graphics_contract.h" ||
    fail 'formato privado Motion Photo 0x11e não está protegido'
grep -q 'isExynosPrivateCameraYuv(format)' "$ROOT/src/mapper.cpp" ||
    fail 'mapper não envia 0x11d/0x11e pelo LOCK_FLEX proprietário'
grep -q 'exynos990_aidl_camera_lock_ycbcr' "$ROOT/src/camera_mapper_compat.cpp" ||
    fail 'fachada HIDL não encaminha o lock para o núcleo AIDL'
grep -q 'exynos990_aidl_camera_unlock' "$ROOT/src/camera_mapper_compat.cpp" ||
    fail 'fachada HIDL não encaminha o unlock para o núcleo AIDL'
grep -q 'cameraLockFlexAsync' "$ROOT/src/mapper.cpp" ||
    fail 'núcleo AIDL não preserva LOCK_FLEX proprietário'
grep -q 'cameraUnlock' "$ROOT/src/mapper.cpp" ||
    fail 'núcleo AIDL não preserva unlock proprietário'
pass 'contrato físico do S20+ preservado'

if grep -R -n -E 'mapper\.stableC-impl-sgr|android\.hardware\.graphics\.allocator-aidl-service-sgr|camera\.s5e|libsamsungcamerahwl' \
        "$ROOT/src" "$ROOT/include" >/dev/null 2>&1; then
    fail 'referência de runtime do S26+ encontrada no código do y2s'
fi
pass 'nenhum blob ou handle SGR do S26+ entra no código'

if [ -f "$CAMERA_HAL" ]; then
    grep -q 'libGrallocMapperCamera.so' <(readelf -d "$CAMERA_HAL") ||
        fail 'HAL da câmera não declara o mapper legado esperado'
    pass 'HAL da câmera ainda usa a fachada ABI esperada'
else
    printf 'WARN: HAL não encontrado em %s; auditoria ELF ignorada\n' "$CAMERA_HAL"
fi

if [ -f "$STOCK_GRALLOC" ]; then
    # Não use grep -q aqui: com pipefail, o grep encerraria antes do nm e
    # transformaria o SIGPIPE normal do nm em falso negativo.
    nm -D "$STOCK_GRALLOC" 2>/dev/null | grep '_Z28mali_gralloc_lock_flex_async' >/dev/null ||
        fail 'gralloc original não exporta LOCK_FLEX'
    pass 'gralloc original exporta LOCK_FLEX'
else
    printf 'WARN: gralloc original não encontrado em %s\n' "$STOCK_GRALLOC"
fi

if [ -f "$S26_MAPPER" ]; then
    printf 'INFO: S26+ usado somente como referência semântica: %s\n' "$S26_MAPPER"
else
    printf 'WARN: mapper S26+ não encontrado; comparação semântica limitada\n'
fi

pass 'auditoria de separação da câmera concluída'
