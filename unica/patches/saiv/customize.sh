SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
SAIV_SOURCE_ROOT="$FW_DIR/$SOURCE_FIRMWARE_PATH"
SAIV_TARGET_ROOT="$FW_DIR/$TARGET_FIRMWARE_PATH"

# Resolve the path used by ADD_TO_WORK_DIR for a firmware/prebuilt root.  The
# extracted firmware layout stores system files below system/system, while
# older prebuilts store them below system directly.
SAIV_RESOLVE_SOURCE_PATH()
{
    local ROOT="$1"
    local PARTITION="$2"
    local FILE="$3"

    if [[ "$PARTITION" == "system" ]]; then
        if [ -d "$ROOT/system/system" ]; then
            printf '%s\n' "$ROOT/system/$FILE"
        else
            printf '%s\n' "$ROOT/system/${FILE#system/}"
        fi
    elif [[ "$PARTITION" == "system_ext" ]]; then
        if [ -d "$ROOT/system_ext" ]; then
            printf '%s\n' "$ROOT/system_ext/$FILE"
        elif [ -d "$ROOT/system/system/system_ext" ]; then
            printf '%s\n' "$ROOT/system/system/system_ext/$FILE"
        else
            printf '%s\n' "$ROOT/system_ext/$FILE"
        fi
    else
        printf '%s\n' "$ROOT/$PARTITION/$FILE"
    fi
}

# Add an optional SAIV donor only when its source path exists.  SAIV has
# several firmware-generation-specific model bundles; a missing optional
# model must not abort the whole build.
SAIV_ADD_IF_PRESENT()
{
    local ROOT="$1"
    local PARTITION="$2"
    local FILE="$3"
    shift 3

    local SOURCE_FILE
    SOURCE_FILE="$(SAIV_RESOLVE_SOURCE_PATH "$ROOT" "$PARTITION" "$FILE")"
    if [ ! -e "$SOURCE_FILE" ] && [ ! -L "$SOURCE_FILE" ] && [ ! -e "$SOURCE_FILE.00" ]; then
        LOG "- Skipping missing SAIV donor: ${SOURCE_FILE//$SRC_DIR\//}"
        return 1
    fi

    ADD_TO_WORK_DIR "$ROOT" "$PARTITION" "$FILE" "$@"
}

if [ -d "$SAIV_TARGET_ROOT/system/system/saiv" ]; then
    DELETE_FROM_WORK_DIR "system" "system/saiv"
    SAIV_ADD_IF_PRESENT "$SAIV_TARGET_ROOT" "system" "system/saiv" \
        0 0 755 "u:object_r:system_file:s0"
else
    LOG "- Target firmware has no system/saiv bundle; retaining the existing SAIV tree"
fi

# O bundle do alvo substitui o system/saiv inteiro, mas a system da source usa
# modelos que o alvo não tem. No y2s (S947B sobre G986B) isso apagava
# imageCropper/sce_detector_cnn.tflite e o FaceService caía a cada execução
# do FaceDetectionWorker (TfLiteInterpreterGetInputTensor com interpretador
# nulo). Restaura da source todo diretório ausente no alvo.
SOURCE_SAIV_DIR="$(SAIV_RESOLVE_SOURCE_PATH "$SAIV_SOURCE_ROOT" "system" "system/saiv")"
if [ -d "$SOURCE_SAIV_DIR" ]; then
    for SAIV_DIR in "$SOURCE_SAIV_DIR"/*/; do
        SAIV_DIR="$(basename "$SAIV_DIR")"
        [ -e "$WORK_DIR/system/system/saiv/$SAIV_DIR" ] && continue
        LOG "- Restoring source-only SAIV bundle: $SAIV_DIR"
        SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "system" "system/saiv/$SAIV_DIR" \
            0 0 755 "u:object_r:system_file:s0"
    done
fi
unset SOURCE_SAIV_DIR SAIV_DIR

# SEC_PRODUCT_FEATURE_VISION_CONFIG_FACE_RECOGNITION_SOLUTION
SOURCE_VISION_CONFIG_FACE_RECOGNITION_SOLUTION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_FACE_CLUSTER_VERSION")"
TARGET_VISION_CONFIG_FACE_RECOGNITION_SOLUTION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_FACE_CLUSTER_VERSION")"
if [[ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_GALLERY_CONFIG_FACE_CLUSTER_VERSION")" == "$SOURCE_VISION_CONFIG_FACE_RECOGNITION_SOLUTION" ]]; then
    if [[ "$TARGET_VISION_CONFIG_FACE_RECOGNITION_SOLUTION" != "$SOURCE_VISION_CONFIG_FACE_RECOGNITION_SOLUTION" ]] || \
            [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
        SOURCE_FACE_CLUSTER_DIR="$SAIV_SOURCE_ROOT/system/system/saiv/face/cluster_pb"
        if [ -d "$SOURCE_FACE_CLUSTER_DIR" ]; then
            if [ -d "$WORK_DIR/system/system/saiv/face/cluster_pb" ]; then
                DELETE_FROM_WORK_DIR "system" "system/saiv/face/cluster_pb"
            fi
            SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "system" "system/saiv/face/cluster_pb" \
                0 0 755 "u:object_r:system_file:s0"
        else
            LOG "- Source has no face cluster bundle; retaining target model"
        fi
        unset SOURCE_FACE_CLUSTER_DIR
    fi
fi

# SEC_PRODUCT_FEATURE_SAIV_CONFIG_MIDAS
if [ ! -f "$WORK_DIR/vendor/etc/midas/moire_detection/moire_detection.tflite" ]; then
    SOURCE_MOIRE_MODEL="$SAIV_SOURCE_ROOT/vendor/etc/midas/moire_detection/moire_detection.tflite"
    TARGET_MOIRE_MODEL="$SAIV_TARGET_ROOT/vendor/etc/midas/moire_detection/moire_detection.tflite"
    if [ -f "$SOURCE_MOIRE_MODEL" ]; then
        SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "etc/midas/moire_detection/moire_detection.tflite" \
            0 0 644 "u:object_r:vendor_configs_file:s0"
    elif [ -f "$TARGET_MOIRE_MODEL" ]; then
        LOG "- Source has no moire model; restoring target model"
        SAIV_ADD_IF_PRESENT "$SAIV_TARGET_ROOT" "vendor" "etc/midas/moire_detection/moire_detection.tflite" \
            0 0 644 "u:object_r:vendor_configs_file:s0"
    else
        LOG "- Source and target have no moire model; keeping it absent"
    fi
    unset SOURCE_MOIRE_MODEL TARGET_MOIRE_MODEL
fi
if [ ! "$(find "$WORK_DIR/vendor/etc/midas" -maxdepth 1 -type f -name "SRIBMQA_aiFiQA*" 2> /dev/null)" ]; then
    SOURCE_FIQA_MODEL="$SAIV_SOURCE_ROOT/vendor/etc/midas/SRIBMQA_aiFiQA_V100_FP32.tflite"
    TARGET_FIQA_MODEL="$SAIV_TARGET_ROOT/vendor/etc/midas/SRIBMQA_aiFiQA_V100_FP32.tflite"
    if [ -f "$SOURCE_FIQA_MODEL" ]; then
        SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "etc/midas/SRIBMQA_aiFiQA_V100_FP32.tflite" \
            0 0 644 "u:object_r:vendor_configs_file:s0"
    elif [ -f "$TARGET_FIQA_MODEL" ]; then
        LOG "- Source has no aiFiQA model; restoring target model"
        SAIV_ADD_IF_PRESENT "$SAIV_TARGET_ROOT" "vendor" "etc/midas/SRIBMQA_aiFiQA_V100_FP32.tflite" \
            0 0 644 "u:object_r:vendor_configs_file:s0"
    else
        LOG "- Source and target have no aiFiQA model; keeping it absent"
    fi
    unset SOURCE_FIQA_MODEL TARGET_FIQA_MODEL
fi
if [ ! -f "$WORK_DIR/vendor/etc/midas/SRIBMQA_aiIQA_V100_FP32.tflite" ]; then
    SOURCE_IIQA_MODEL="$SAIV_SOURCE_ROOT/vendor/etc/midas/SRIBMQA_aiIQA_V100_FP32.tflite"
    TARGET_IIQA_MODEL="$SAIV_TARGET_ROOT/vendor/etc/midas/SRIBMQA_aiIQA_V100_FP32.tflite"
    if [ -f "$SOURCE_IIQA_MODEL" ]; then
        SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "etc/midas/SRIBMQA_aiIQA_V100_FP32.tflite" \
            0 0 644 "u:object_r:vendor_configs_file:s0"
    elif [ -f "$TARGET_IIQA_MODEL" ]; then
        LOG "- Source has no aiIQA model; restoring target model"
        SAIV_ADD_IF_PRESENT "$SAIV_TARGET_ROOT" "vendor" "etc/midas/SRIBMQA_aiIQA_V100_FP32.tflite" \
            0 0 644 "u:object_r:vendor_configs_file:s0"
    else
        LOG "- Source and target have no aiIQA model; keeping it absent"
    fi
    unset SOURCE_IIQA_MODEL TARGET_IIQA_MODEL
fi
if [ "$(find "$WORK_DIR/vendor/etc/midas" -maxdepth 1 -type f -name "*UPSCALER_*_LITE*" 2> /dev/null)" ]; then
    # Ensure AI_UPSCALE LITE models are loaded if available
    if [ -f "$WORK_DIR/vendor/etc/midas/midas_config.json" ] && \
            ! sed -n "/\"midasSR_devices\"/,/]/p" "$WORK_DIR/vendor/etc/midas/midas_config.json" | grep -q "\"$(GET_PROP "ro.product.device")\""; then
        LOG "- Patching /vendor/etc/midas/midas_config.json"
        EVAL "sed -i \"/\\\"midasSR_devices\\\"[^[]*\\[/a\\\\    \\\"$(GET_PROP "ro.product.device")\\\",\" \"$WORK_DIR/vendor/etc/midas/midas_config.json\""
    fi
fi

# SEC_PRODUCT_FEATURE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION
SOURCE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION")"
TARGET_GALLERY_CONFIG_IMAGE_TAGGER_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION")"
if [[ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION")" == "$SOURCE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION" ]]; then
    if { [[ "$TARGET_GALLERY_CONFIG_IMAGE_TAGGER_VERSION" != "$SOURCE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION" ]] || \
            [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; } && \
            [ -d "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/saiv/image_understanding/db/aig" ]; then
        if [ -d "$WORK_DIR/system/system/saiv/image_understanding/db/aig" ]; then
            DELETE_FROM_WORK_DIR "system" "system/saiv/image_understanding/db/aig"
        fi
        SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "system" "system/saiv/image_understanding/db/aig" \
            0 0 755 "u:object_r:system_file:s0"
        SOURCE_AIG_CLASSIFIER_DIR="$SAIV_SOURCE_ROOT/vendor/saiv/image_understanding/db/aig_classifier"
        if [ -d "$SOURCE_AIG_CLASSIFIER_DIR" ]; then
            if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/aig_classifier" ]; then
                DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/aig_classifier"
            fi
            SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "saiv/image_understanding/db/aig_classifier" \
                0 2000 755 "u:object_r:vendor_snap_file:s0"
        else
            LOG "- Source has no AIG classifier bundle; retaining target model"
        fi
        SOURCE_AIG_DOCUMENT_CLASSIFIER_DIR="$SAIV_SOURCE_ROOT/vendor/saiv/image_understanding/db/aig_document_classifier"
        if [ -d "$SOURCE_AIG_DOCUMENT_CLASSIFIER_DIR" ]; then
            if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/aig_document_classifier" ]; then
                DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/aig_document_classifier"
            fi
            SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "saiv/image_understanding/db/aig_document_classifier" \
                0 2000 755 "u:object_r:vendor_snap_file:s0"
        else
            LOG "- Source has no AIG document-classifier bundle; retaining target model"
        fi
        SOURCE_AIG_DOCUMENT_DETECTOR_DIR="$SAIV_SOURCE_ROOT/vendor/saiv/image_understanding/db/aig_document_detector"
        if [ -d "$SOURCE_AIG_DOCUMENT_DETECTOR_DIR" ]; then
            if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/aig_document_detector" ]; then
                DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/aig_document_detector"
            fi
            SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "saiv/image_understanding/db/aig_document_detector" \
                0 2000 755 "u:object_r:vendor_snap_file:s0"
        else
            LOG "- Source has no AIG document-detector bundle; retaining target model"
        fi
        if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/srr_interaction" ]; then
            DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/srr_interaction"
        fi
        unset SOURCE_AIG_CLASSIFIER_DIR SOURCE_AIG_DOCUMENT_CLASSIFIER_DIR SOURCE_AIG_DOCUMENT_DETECTOR_DIR
    fi
fi

# Photo Editor "oneUI-full-release"/"genAI-full-release" flavor models
if [ -f "$WORK_DIR/system/system/priv-app/PhotoEditor_Full/PhotoEditor_Full.apk" ] || \
        [ -f "$WORK_DIR/system/system/priv-app/PhotoEditor_AIFull/PhotoEditor_AIFull.apk" ]; then
    if [ ! -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/hs_segmenter" ] || \
            [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
        SOURCE_HS_SEGMENTER_DIR="$SAIV_SOURCE_ROOT/vendor/etc/saiv/image_understanding/db/hs_segmenter"
        if [ -d "$SOURCE_HS_SEGMENTER_DIR" ]; then
            if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/hs_segmenter" ]; then
                DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/hs_segmenter"
            fi
            SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "etc/saiv/image_understanding/db/hs_segmenter" \
                0 0 755 "u:object_r:vendor_configs_file:s0"
        else
            LOG "- Source has no Photo Editor human-segmentation bundle; retaining target model"
        fi
        unset SOURCE_HS_SEGMENTER_DIR
    fi
else
    if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/hs_segmenter" ]; then
        DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/hs_segmenter"
    fi
fi

# SEC_PRODUCT_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION
SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION")"
TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION")"
if [[ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION")" == "$SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION" ]]; then
    if [[ "$SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION" != "None" ]]; then
        if { [[ "$TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION" != "$SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION" ]] || \
                [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; } && \
                [ -d "$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/saiv/image_understanding/db/pet_detector" ]; then
            SOURCE_PET_DETECTOR_DIR="$SAIV_SOURCE_ROOT/vendor/saiv/image_understanding/db/pet_detector"
            SOURCE_PET_SEARCH_DIR="$SAIV_SOURCE_ROOT/vendor/saiv/image_understanding/db/pet_mypetsearch"
            if [ -d "$SOURCE_PET_DETECTOR_DIR" ]; then
                if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/pet_detector" ]; then
                    DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/pet_detector"
                fi
                SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "saiv/image_understanding/db/pet_detector" \
                    0 2000 755 "u:object_r:vendor_snap_file:s0"
            else
                LOG "- Source has no pet detector bundle; retaining target model"
            fi
            if [ -d "$SOURCE_PET_SEARCH_DIR" ]; then
                if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/pet_mypetsearch" ]; then
                    DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/pet_mypetsearch"
                fi
                SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "vendor" "saiv/image_understanding/db/pet_mypetsearch" \
                    0 2000 755 "u:object_r:vendor_snap_file:s0"
            else
                LOG "- Source has no pet search bundle; retaining target model"
            fi
            unset SOURCE_PET_DETECTOR_DIR SOURCE_PET_SEARCH_DIR
        fi
    else
        if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/pet_detector" ]; then
            DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/pet_detector"
        fi
        if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/pet_mypetsearch" ]; then
            DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/pet_mypetsearch"
        fi
    fi
fi

# SEC_PRODUCT_FEATURE_VISION_CONFIG_BIXBYVISION_VERSION
GTS11XX_ROOT="$SRC_DIR/prebuilts/samsung/gts11xx"
if [ -f "$WORK_DIR/system/system/priv-app/BixbyVisionFramework3.5/BixbyVisionFramework3.5.apk" ]; then
    if [ ! -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/slens_classifier" ] || \
            [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
        if [ -f "$GTS11XX_ROOT/system/saiv/image_understanding/db/slens_classifier/slens_classifier_cnn.sni" ]; then
            if [ -d "$WORK_DIR/system/system/saiv/image_understanding/db/slens_classifier" ]; then
                DELETE_FROM_WORK_DIR "system" "system/saiv/image_understanding/db/slens_classifier"
            fi
            SAIV_ADD_IF_PRESENT "$GTS11XX_ROOT" "system" "system/saiv/image_understanding/db/slens_classifier/slens_classifier_cnn.sni" \
                0 0 644 "u:object_r:system_file:s0"
        else
            LOG "- gts11xx has no Bixby classifier SNI; retaining target model"
        fi
        if [ -f "$GTS11XX_ROOT/vendor/etc/saiv/image_understanding/db/slens_classifier/slens_classifier_cnn.tflite" ]; then
            if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/slens_classifier" ]; then
                DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/slens_classifier"
            fi
            SAIV_ADD_IF_PRESENT "$GTS11XX_ROOT" "vendor" "etc/saiv/image_understanding/db/slens_classifier/slens_classifier_cnn.tflite" \
                0 0 644 "u:object_r:vendor_configs_file:s0"
        else
            LOG "- gts11xx has no Bixby classifier TFLite; retaining target model"
        fi
    fi
    if [ ! -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/slens_detector" ] || \
            [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
        if [ -f "$GTS11XX_ROOT/system/saiv/image_understanding/db/slens_detector/slens_detector_cnn.sni" ]; then
            if [ -d "$WORK_DIR/system/system/saiv/image_understanding/db/slens_detector" ]; then
                DELETE_FROM_WORK_DIR "system" "system/saiv/image_understanding/db/slens_detector"
            fi
            SAIV_ADD_IF_PRESENT "$GTS11XX_ROOT" "system" "system/saiv/image_understanding/db/slens_detector/slens_detector_cnn.sni" \
                0 0 644 "u:object_r:system_file:s0"
        else
            LOG "- gts11xx has no Bixby detector SNI; retaining target model"
        fi
        if [ -f "$GTS11XX_ROOT/vendor/etc/saiv/image_understanding/db/slens_detector/slens_detector_cnn.tflite" ]; then
            if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/slens_detector" ]; then
                DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/slens_detector"
            fi
            SAIV_ADD_IF_PRESENT "$GTS11XX_ROOT" "vendor" "etc/saiv/image_understanding/db/slens_detector/slens_detector_cnn.tflite" \
                0 0 644 "u:object_r:vendor_configs_file:s0"
        else
            LOG "- gts11xx has no Bixby detector TFLite; retaining target model"
        fi
    fi
else
    if [ -d "$WORK_DIR/system/system/saiv/image_understanding/db/slens_classifier" ]; then
        DELETE_FROM_WORK_DIR "system" "system/saiv/image_understanding/db/slens_classifier"
    fi
    if [ -d "$WORK_DIR/system/system/saiv/image_understanding/db/slens_detector" ]; then
        DELETE_FROM_WORK_DIR "system" "system/saiv/image_understanding/db/slens_detector"
    fi
    if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/slens_classifier" ]; then
        DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/slens_classifier"
    fi
    if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/slens_detector" ]; then
        DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/slens_detector"
    fi
    if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/slens_classifier" ]; then
        DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/slens_classifier"
    fi
    if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/slens_detector" ]; then
        DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/slens_detector"
    fi
fi

# SEC_PRODUCT_FEATURE_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION
SOURCE_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS")"
TARGET_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS")"
if [[ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS")" == "$SOURCE_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION" ]]; then
    if [[ "$SOURCE_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION" == *"AI_DEWARPING"* ]]; then
        if [[ "$TARGET_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION" != *"AI_DEWARPING"* ]] || \
                [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
            SOURCE_DEEP_DEWARP_SNI="$SAIV_SOURCE_ROOT/system/system/saiv/image_understanding/db/smartscan_rectifier/deep_dewarp_cnn.sni"
            if [ -f "$SOURCE_DEEP_DEWARP_SNI" ]; then
                SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" \
                    "system" "system/saiv/image_understanding/db/smartscan_rectifier/deep_dewarp_cnn.sni" \
                    0 0 644 "u:object_r:system_file:s0"
            else
                LOG "- Source has no deep_dewarp_cnn.sni; retaining target model"
            fi
            if [ -f "$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/saiv/image_understanding/db/smartscan_rectifier/deep_dewarp_cnn.onnx" ]; then
                ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" \
                    "vendor" "saiv/image_understanding/db/smartscan_rectifier/deep_dewarp_cnn.onnx" 0 0 644 "u:object_r:vendor_snap_file:s0"
            else
                # Newer source firmware moved the document-rectification model to its newer
                # doc_rectifier TFLite bundle. Its deep_dewarp SNI is still
                # compatible with the y2slte target model, which is retained
                # when the source does not ship the legacy ONNX file.
                LOG "- Source has no deep_dewarp_cnn.onnx; retaining target model"
            fi
            unset SOURCE_DEEP_DEWARP_SNI
        fi
    else
        if [ -d "$WORK_DIR/system/system/saiv/image_understanding/db/smartscan_rectifier" ]; then
            DELETE_FROM_WORK_DIR "system" "system/saiv/image_understanding/db/smartscan_rectifier"
        fi
        if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/smartscan_rectifier" ]; then
            DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/smartscan_rectifier"
        fi
    fi
fi

# SEC_PRODUCT_FEATURE_VISION_CONFIG_SMART_CROPPING_SOLUTION
if [ ! -d "$WORK_DIR/system/system/saiv/smartcropping_2.0" ] || \
        [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
    SOURCE_SMARTCROPPING_DIR="$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/saiv/smartcropping_2.0"
    if [ -f "$SOURCE_SMARTCROPPING_DIR/db/smartcrop_saliency_deploy.prototxt" ] && \
            [ -f "$SOURCE_SMARTCROPPING_DIR/db/smartcrop_saliency_train" ]; then
        if [ -d "$WORK_DIR/system/system/saiv/smartcropping_2.0" ]; then
            DELETE_FROM_WORK_DIR "system" "system/saiv/smartcropping_2.0"
        fi
        ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/saiv/smartcropping_2.0/db/smartcrop_saliency_deploy.prototxt" 0 0 644 "u:object_r:system_file:s0"
        ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/saiv/smartcropping_2.0/db/smartcrop_saliency_train" 0 0 644 "u:object_r:system_file:s0"
    elif [ ! -d "$WORK_DIR/system/system/saiv/smartcropping_2.0" ]; then
        LOG "- Source has no legacy Smart Cropping bundle; restoring target model"
        TARGET_SMARTCROPPING_DIR="$SAIV_TARGET_ROOT/system/system/saiv/smartcropping_2.0"
        if [ -d "$TARGET_SMARTCROPPING_DIR" ]; then
            SAIV_ADD_IF_PRESENT "$SAIV_TARGET_ROOT" "system" "system/saiv/smartcropping_2.0" \
                0 0 755 "u:object_r:system_file:s0"
        else
            LOG "- Source and target have no Smart Cropping bundle; keeping it absent"
        fi
        unset TARGET_SMARTCROPPING_DIR
    else
        LOG "- Source has no legacy Smart Cropping bundle; retaining target model"
    fi
fi
if [ ! -d "$WORK_DIR/vendor/saiv/image_understanding/db/sce_detector" ] || \
        [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
    SOURCE_SCE_MODEL="$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/saiv/image_understanding/db/sce_detector/sce_detector_cnn.tflite"
    if [ -f "$SOURCE_SCE_MODEL" ]; then
        if [ -d "$WORK_DIR/vendor/saiv/image_understanding/db/sce_detector" ]; then
            DELETE_FROM_WORK_DIR "vendor" "saiv/image_understanding/db/sce_detector"
        fi
        ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "saiv/image_understanding/db/sce_detector/sce_detector_cnn.tflite" 0 0 644 "u:object_r:vendor_snap_file:s0"
    elif [ ! -d "$WORK_DIR/vendor/saiv/image_understanding/db/sce_detector" ]; then
        TARGET_SCE_DIR="$FW_DIR/$TARGET_FIRMWARE_PATH/vendor/saiv/image_understanding/db/sce_detector"
        if [ -d "$TARGET_SCE_DIR" ]; then
            LOG "- Source has no legacy SCE detector bundle; restoring target model"
            ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "vendor" "saiv/image_understanding/db/sce_detector" 0 2000 755 "u:object_r:vendor_snap_file:s0"
        else
            LOG "- Source and target have no legacy SCE detector bundle; keeping it absent"
        fi
        unset TARGET_SCE_DIR
    else
        LOG "- Source has no legacy SCE detector bundle; retaining target model"
    fi
fi

# SEC_PRODUCT_FEATURE_CAMERA_CONFIG_STRIDE_OCR_VERSION
SOURCE_TEXTRECOGNITION_DIR="$SAIV_SOURCE_ROOT/system/system/saiv/textrecognition"
if [ -d "$SOURCE_TEXTRECOGNITION_DIR" ]; then
    if [ -d "$WORK_DIR/system/system/saiv/textrecognition" ]; then
        DELETE_FROM_WORK_DIR "system" "system/saiv/textrecognition"
    fi
    SAIV_ADD_IF_PRESENT "$SAIV_SOURCE_ROOT" "system" "system/saiv/textrecognition" \
        0 0 755 "u:object_r:system_file:s0"
else
    LOG "- Source has no text-recognition bundle; retaining target model"
fi
unset SOURCE_TEXTRECOGNITION_DIR

# SEC_PRODUCT_FEATURE_CAMERA_CONFIG_VENDOR_LIB_INFO:=*smart_scan.samsung.v2*
if [ -f "$WORK_DIR/system/system/lib64/libSmartScan.camera.samsung.so" ]; then
    if [ ! -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/SS_segmenter" ] || \
            [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
        A34XXX_ROOT="$SRC_DIR/prebuilts/samsung/a34xxx"
        if [ -f "$A34XXX_ROOT/vendor/etc/saiv/image_understanding/db/SS_segmenter/SS_segmenter_cnn.tflite" ] && \
                [ -f "$A34XXX_ROOT/vendor/etc/saiv/image_understanding/db/SS_segmenter/SS_segmenter_cnn.info" ]; then
            if [ -d "$WORK_DIR/vendor/etc/saiv/image_understanding/db/SS_segmenter" ]; then
                DELETE_FROM_WORK_DIR "vendor" "etc/saiv/image_understanding/db/SS_segmenter"
            fi
            SAIV_ADD_IF_PRESENT "$A34XXX_ROOT" "vendor" "etc/saiv/image_understanding/db/SS_segmenter/SS_segmenter_cnn.tflite" \
                0 0 644 "u:object_r:vendor_configs_file:s0"
            SAIV_ADD_IF_PRESENT "$A34XXX_ROOT" "vendor" "etc/saiv/image_understanding/db/SS_segmenter/SS_segmenter_cnn.info" \
                0 0 644 "u:object_r:vendor_configs_file:s0"
        else
            LOG "- a34xxx has no complete SmartScan segmenter bundle; retaining target model"
        fi
        unset A34XXX_ROOT
    fi
fi

unset SOURCE_FIRMWARE_PATH TARGET_FIRMWARE_PATH \
    SOURCE_VISION_CONFIG_FACE_RECOGNITION_SOLUTION TARGET_VISION_CONFIG_FACE_RECOGNITION_SOLUTION \
    SOURCE_GALLERY_CONFIG_IMAGE_TAGGER_VERSION TARGET_GALLERY_CONFIG_IMAGE_TAGGER_VERSION \
    SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION \
    SOURCE_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION TARGET_CAMERA_CONFIG_DOCUMENT_DEWARP_VERSION \
    SOURCE_SMARTCROPPING_DIR SOURCE_SCE_MODEL SAIV_SOURCE_ROOT SAIV_TARGET_ROOT GTS11XX_ROOT
unset -f SAIV_RESOLVE_SOURCE_PATH SAIV_ADD_IF_PRESENT
