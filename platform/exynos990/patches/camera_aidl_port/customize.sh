#!/usr/bin/env bash

# O módulo contém artefatos vendor, mas eles só podem entrar na imagem quando
# o provider AIDL estiver explicitamente habilitado.  Sem isto, o carregador
# copia a pasta antes de executar este arquivo e cria regras file_context sem
# rótulo no modo HIDL padrão.
SKIPUNZIP=1

# O modo padrão mantém o provider HIDL. O modo 1 é uma validação isolada do
# provider AIDL e substitui a declaração/serviço HIDL para não anunciar duas
# pilhas para os mesmos sensores.

if [[ "$TARGET_CODENAME" != "y2s" && "$TARGET_CODENAME" != "y2slte" ]]; then
    LOG "- Camera3 AIDL port is limited to y2s/y2slte; skipping target"
    return 0
fi

CAMERA_AIDL_MODE="${EXYNOS990_CAMERA_AIDL:-1}"
case "$CAMERA_AIDL_MODE" in
    0|1) ;;
    *) ABORT "EXYNOS990_CAMERA_AIDL must be 0 or 1"; return 1 ;;
esac

if [ "$CAMERA_AIDL_MODE" = 0 ]; then
    LOG "- Camera3 AIDL provider port is staged only (EXYNOS990_CAMERA_AIDL=0)"
    return 0
fi

# The native Exynos 990 Camera3 HAL expects the same private stream words that
# Samsung's HIDL adapter used to fill.  Keep these properties scoped to the
# explicit AIDL validation mode; the default HIDL build must not inherit them.
SET_PROP vendor vendor.camera.aidl.private_usecase 1 || return 1
# SehCameraDevice abre e consulta get_camera_info() com o ID público; o ID 20
# é a câmera lógica multi-sensor do próprio HAL (0.5x, RAW e 64 MP).
SET_PROP vendor vendor.camera.aidl.native_logical_ids 1 || return 1
# Com o set_parameters do ISehCameraDeviceSession o HAL honra as opções Samsung
# e aceita todos os streams, como o wrapper HIDL. drop_highres_yuv e
# preserve_private_handle ficam desligados (o handle cru quebrava o vídeo).
SET_PROP vendor vendor.camera.aidl.drop_highres_yuv 0 || return 1
SET_PROP vendor vendor.camera.aidl.preserve_private_handle 0 || return 1
# Rede de segurança caso drop_highres_yuv seja religado para diagnóstico: o
# ERROR_BUFFER de um stream que ficou fora do configure_streams() não chega
# ao CameraService.
SET_PROP vendor vendor.camera.aidl.suppress_framework_only_error 1 || return 1
# O pool interno FLITE tem oito Bayer buffers.
SET_PROP vendor vendor.camera.aidl.preview_max_buffers 7 || return 1
# O pool FLITE do Exynos 990 possui oito Bayer buffers. Mantenha somente seis
# requests físicos pendentes: dois slots ficam reservados ao sensor/3AA para
# que o preview não repita o último frame quando o pipeline estiver drenando.
SET_PROP vendor vendor.camera.aidl.max_pending_requests 6 || return 1

SERVICE="bin/hw/android.hardware.camera.provider-V4-service.exynos990"
RC="etc/init/android.hardware.camera.provider-V4-service.exynos990.rc"
VINTF="etc/vintf/manifest/android.hardware.camera.provider-exynos990.xml"
OLD_RC="etc/init/vendor.samsung.hardware.camera.provider@4.0-service_64.rc"
OLD_MANIFEST="$WORK_DIR/vendor/etc/vintf/manifest.xml"

for path in "$SRC_DIR/prebuilts/exynos990/camera_aidl_port/vendor/$SERVICE" "$MODPATH/vendor/$RC" "$MODPATH/vendor/$VINTF"; do
    [ -f "$path" ] || {
        ABORT "Camera AIDL validation artifact is missing: ${path#$MODPATH/}"
        return 1
    }
done

ADD_TO_WORK_DIR "$SRC_DIR/prebuilts/exynos990/camera_aidl_port" "vendor" "$SERVICE" \
    0 1047 755 "u:object_r:hal_camera_default_exec:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" "$RC" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" "$VINTF" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

# ADD_TO_WORK_DIR preserves an already generated entry when a work_dir is
# reused.  Force these metadata records after the copy so a stale empty entry
# can never leave mkfs.erofs with a one-field file_contexts rule.
if [[ -e "$WORK_DIR/vendor/$SERVICE" ]]; then
    SET_METADATA "vendor" "$SERVICE" 0 1047 755 "u:object_r:hal_camera_default_exec:s0" || return 1
fi
SET_METADATA "vendor" "$RC" 0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
SET_METADATA "vendor" "$VINTF" 0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

DELETE_FROM_WORK_DIR "vendor" "$OLD_RC" || return 1

# Só a entrada HIDL da câmera é retirada. Os demais HALs e o manifest composto
# permanecem intactos, e o fragmento AIDL acima passa a ser carregado por VINTF.
python3 - "$OLD_MANIFEST" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
for hal in list(root):
    name = hal.findtext('name')
    if hal.get('format') == 'hidl' and name == 'android.hardware.camera.provider':
        root.remove(hal)
ET.indent(tree, space='    ')
tree.write(path, encoding='UTF-8', xml_declaration=True)
PY

VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
grep -q -F 'camera\.provider-V4-service\.exynos990' "$VENDOR_FILE_CONTEXTS" || \
    echo '/(vendor|system/vendor)/bin/hw/android\.hardware\.camera\.provider-V4-service\.exynos990 u:object_r:hal_camera_default_exec:s0' \
        >> "$VENDOR_FILE_CONTEXTS"

LOG "- Enabled isolated Exynos 990 Camera3 AIDL provider validation"
