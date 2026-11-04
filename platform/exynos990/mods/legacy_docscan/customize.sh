# shellcheck disable=SC2034
SKIPUNZIP=1

# The S24+ source advertises enhanced document-scan operations backed by its
# S5E9945 SNAP/NPU runtime. On Exynos 990 they initialize with "Snap wrapper
# openSnap error" and can prevent the ordinary document/text scanner from
# reaching its legacy path. Keep the S20+ Smart Scan stack coherent: code,
# OCR models and the segmentation model originate from the target firmware.
if [[ "$TARGET_CODENAME" == "y2s" || "$TARGET_CODENAME" == "y2slte" ]]; then
    PATCHED=true

    # Do not expose S24+ AI dewarping, shadow removal, deblur, object removal
    # or color enhancement. This leaves legacy Smart Scan detection, manual
    # crop and text extraction enabled.
    # A feature não pode ser apagada: a Samsung Camera deriva
    # SUPPORT_MULTI_SCAN de "SCANNER_FILTER" nesta lista e, sem ele, desabilita
    # MultiScan/MultiScanActivity enquanto o atalho DocumentScanner continua
    # ativo (ActivityNotFoundException em MULTI_SCAN_MODE ao abrir o scanner).
    SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS" \
        "SCANNER_FILTER,DEFAULT_COLOR_FILTER"

    for ABI in lib lib64; do
        for LIBRARY in \
            libSmartScan.camera.samsung.so \
            libDeepDocRectify.camera.samsung.so \
            libDocRectifyWrapper.camera.samsung.so \
            libSimpleDocRectify.camera.samsung.so \
            libStride.camera.samsung.so \
            libStrideTensorflowLite.camera.samsung.so; do
            ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/$ABI/$LIBRARY" \
                0 0 644 "u:object_r:system_lib_file:s0"
        done
    done

    if [ -d "$WORK_DIR/system/system/saiv/textrecognition" ]; then
        DELETE_FROM_WORK_DIR "system" "system/saiv/textrecognition"
    fi
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/saiv/textrecognition" \
        0 0 755 "u:object_r:system_file:s0"

    if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/SS_segmenter" ]; then
        DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/SS_segmenter"
    fi
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "vendor" "etc/saiv/image_understanding/db/SS_segmenter" \
        0 0 755 "u:object_r:vendor_configs_file:s0"

    # These nodes are from the S24+ enhanced-document pipeline. They require
    # its SNAP adapter/model ABI and are not part of the S20+ OCR path.
    for LIBRARY in \
        libDocColorEnhance.camera.samsung.so \
        libDocColorEnhance_Auto.camera.samsung.so \
        libDocDeblur.camera.samsung.so \
        libDocObjectRemoval.camera.samsung.so \
        libDocObjectRemoval.enhanceX.samsung.so \
        libDocShadowRemoval.camera.samsung.so; do
        if [ -f "$WORK_DIR/system/system/lib64/$LIBRARY" ]; then
            DELETE_FROM_WORK_DIR "system" "system/lib64/$LIBRARY"
        fi
    done
fi
