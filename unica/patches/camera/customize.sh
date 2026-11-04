# [
_LOG() { if $DEBUG; then LOGW "$1"; else ABORT "$1"; fi }

LOG_MISSING_PATCHES()
{
    local MESSAGE="Missing SPF patches for condition ($1: [${!1}], $2: [${!2}])"

    if $DEBUG; then
        LOGW "$MESSAGE"
    else
        ABORT "${MESSAGE}. Aborting"
    fi
}
# ]

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"

DELETE_FROM_WORK_DIR "system" "system/cameradata/portrait_data"
ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "system/cameradata/portrait_data" 0 0 755 "u:object_r:system_file:s0"
if [ -f "$SRC_DIR/target/$TARGET_CODENAME/camera/singletake/service-feature.xml" ]; then
    LOG "- Adding /system/system/cameradata/singletake/service-feature.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/camera/singletake/service-feature.xml\" \"$WORK_DIR/system/system/cameradata/singletake/service-feature.xml\""
else
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" \
        "system" "system/cameradata/singletake/service-feature.xml" 0 0 644 "u:object_r:system_file:s0"
fi
if [ -f "$SRC_DIR/target/$TARGET_CODENAME/camera/aremoji-feature.xml" ]; then
    LOG "- Adding /system/system/cameradata/aremoji-feature.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/camera/aremoji-feature.xml\" \"$WORK_DIR/system/system/cameradata/aremoji-feature.xml\""
else
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" \
        "system" "system/cameradata/aremoji-feature.xml" 0 0 644 "u:object_r:system_file:s0"
fi
if [ -f "$SRC_DIR/target/$TARGET_CODENAME/camera/camera-feature.xml" ]; then
    LOG "- Adding /system/system/cameradata/camera-feature.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/camera/camera-feature.xml\" \"$WORK_DIR/system/system/cameradata/camera-feature.xml\""
elif [ -f "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/cameradata/camera-feature.xml" ]; then
    # A legacy target can have a different SDK from the ESSI source without
    # needing a fabricated feature XML. Keep the target firmware's complete
    # camera contract until a target-specific adaptation is authored.
    LOG "- Reusing target firmware camera-feature.xml"
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" \
        "system" "system/cameradata/camera-feature.xml" 0 0 644 "u:object_r:system_file:s0"
elif [[ "$SOURCE_PLATFORM_SDK_VERSION" == "$TARGET_PLATFORM_SDK_VERSION" ]]; then
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" \
        "system" "system/cameradata/camera-feature.xml" 0 0 644 "u:object_r:system_file:s0"
else
    _LOG "File not found: $SRC_DIR/target/$TARGET_CODENAME/camera/camera-feature.xml"
fi

# The authoritative M21s target XML is the stock baseline plus its validated
# 4.0x zoom ceiling. Scrub only a leaked donor-mode attribute from the workdir
# copy; this is a byte-identical no-op for the valid target file.
if [[ "$TARGET_CODENAME" == "m21s" ]]; then
    M21S_CAMERA_FEATURE="$WORK_DIR/system/system/cameradata/camera-feature.xml"
    EVAL "sed -i 's/front=\"LIVE_FOCUS_LITE\" //' \"$M21S_CAMERA_FEATURE\""
    if grep -Eq '6528x4896|5264x3948|4624x3468|4624x2604|4624x2136|4000x2250|3264x1504|LIVE_FOCUS_LITE' "$M21S_CAMERA_FEATURE"; then
        ABORT "M21s camera XML contains untranslated donor values"
        return 1
    fi
    unset M21S_CAMERA_FEATURE
fi
# the Autoframe implementation, but the Exynos 990 target is missing the
# source-firmware tracker/plugin stack and its detector model. Import only this isolated
# closure from the source firmware; do not replace the camera HAL or all
# source camera blobs.
if [[ "$TARGET_CODENAME" == "y2s" ]]; then
    AUTOFRAME_FILES=(
        "vendor/lib64/libaivideocentral.arcsoft.so"
        "vendor/lib64/libzoomroi_lite.samsung.so"
        "vendor/lib64/libbodyid.arcsoft.so"
        "vendor/lib64/libzoomroi.samsung.so"
        "vendor/lib64/libauto_framing_arcsoft.uniplugin@1.0.so"
        "vendor/lib64/libauto_framing_lite.uniplugin@1.0.so"
        "vendor/lib64/libautoframing_object_tracker.camera.samsung.so"
        "vendor/lib64/libautotracking_interface.so"
        "vendor/lib64/libAIMFISP.camera.samsung.so"
        "vendor/lib64/libAIMFISP_core.camera.samsung.so"
        "vendor/lib64/libAImode_wrapper.camera.samsung.so"
        "vendor/etc/saiv/image_understanding/db/aic_autoframing_detector_tracker/aic_autoframing_detector_tracker_cnn.info"
        "vendor/etc/saiv/image_understanding/db/aic_autoframing_detector_tracker/aic_autoframing_detector_tracker_cnn.tflite"
    )
    AUTOFRAME_READY=true
    for AUTOFRAME_FILE in "${AUTOFRAME_FILES[@]}"; do
        if [ ! -f "$FW_DIR/$SOURCE_FIRMWARE_PATH/$AUTOFRAME_FILE" ]; then
            AUTOFRAME_READY=false
            LOGW "Autoframe source file is missing: ${AUTOFRAME_FILE}"
        fi
    done
    if $AUTOFRAME_READY; then
        for AUTOFRAME_FILE in "${AUTOFRAME_FILES[@]}"; do
            ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "${AUTOFRAME_FILE%%/*}" "${AUTOFRAME_FILE#*/}"
        done
        LOG "- Imported source Autoframe tracker/plugin stack and detector model"
    else
        LOGW "Skipping Autoframe import because the source closure is incomplete"
    fi
    unset AUTOFRAME_FILES AUTOFRAME_FILE AUTOFRAME_READY
fi

# Restore only HDR10+ profiles advertised by stock Android 13 camera XMLs.
# c2s, r8s and z3s target overlays had disabled every hdr10 attribute even
# though their corresponding stock firmwares advertise these rear profiles.
# Keep higher-frame-rate and front-camera profiles disabled as stock does.
case "$TARGET_CODENAME" in
    c2s|r8s|z3s)
        HDR10_STOCK_PROFILES="
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_2400X1080
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_2320X1080
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1440X1440
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1280X720
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_640X480
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644_24FPS
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X1644
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_3840X2160_24FPS
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X824_24FPS
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X824
BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1080_24FPS
"
        for HDR10_PROFILE in $HDR10_STOCK_PROFILES; do
            EVAL "sed -i '/name=\"$HDR10_PROFILE\"/s/hdr10=\"false\"/hdr10=\"true\"/' \"$WORK_DIR/system/system/cameradata/camera-feature.xml\""
        done
        if [[ "$TARGET_CODENAME" == "r8s" ]]; then
            # r8s has two 1920x1440 entries; only the final, physical-camera
            # entry is effective and maps to the stock HDR10+ capability.
            EVAL "sed -i '/name=\"BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1440\".*physical-zoom-supported=/s/hdr10=\"false\"/hdr10=\"true\"/' \"$WORK_DIR/system/system/cameradata/camera-feature.xml\""
        else
            EVAL "sed -i '/name=\"BACK_CAMCORDER_RESOLUTION_FEATURE_MAP_1920X1440\"/s/hdr10=\"false\"/hdr10=\"true\"/' \"$WORK_DIR/system/system/cameradata/camera-feature.xml\""
        fi
        unset HDR10_STOCK_PROFILES HDR10_PROFILE
        ;;
esac

LOG_STEP_IN
if grep -q "DURING_SMARTVIEW" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
    LOG "- Removing Smart View limitations flags"
    EVAL "sed -i \"/DURING_SMARTVIEW/d\" \"$WORK_DIR/system/system/cameradata/camera-feature.xml\""
fi
if [ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_GRAPHICS_SUPPORT_3D_SURFACE_TRANSITION_FLAG")" ]; then
    if grep -q "SUPPORT_LIVE_BLUR" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
        LOG "- Removing native blur disable flag"
        EVAL "sed -i \"/SUPPORT_LIVE_BLUR/d\" \"$WORK_DIR/system/system/cameradata/camera-feature.xml\""
    fi
fi
LOG_STEP_OUT

# Samsung Camera "hal3_mass-phone-release" app flavor
if ! $SOURCE_CAMERA_SUPPORT_MASS_APP_FLAVOR; then
    if $TARGET_CAMERA_SUPPORT_MASS_APP_FLAVOR; then
        ADD_TO_WORK_DIR "r9qxxx" "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" 0 0 644 "u:object_r:system_file:s0"
        ADD_TO_WORK_DIR "r9qxxx" "system" "system/priv-app/SamsungCamera/SamsungCamera.apk.prof" 0 0 644 "u:object_r:system_file:s0"
    fi
else
    if ! $TARGET_CAMERA_SUPPORT_MASS_APP_FLAVOR; then
        # TODO handle this condition
        LOG_MISSING_PATCHES "SOURCE_CAMERA_SUPPORT_MASS_APP_FLAVOR" "TARGET_CAMERA_SUPPORT_MASS_APP_FLAVOR"
    fi
fi

# Add/delete Snapchat CameraKit Plugin if SHOOTING_MODE_FUN is (not) available
if [ -f "$WORK_DIR/system/system/app/FunModeSDK/FunModeSDK.apk" ]; then
    if ! grep -q "SHOOTING_MODE_FUN" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
        DELETE_FROM_WORK_DIR "system" "system/app/FunModeSDK"
    fi
else
    if grep -q "SHOOTING_MODE_FUN" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
        ADD_TO_WORK_DIR "a73xqxx" "system" "system/app/FunModeSDK" 0 0 755 "u:object_r:system_file:s0"
    fi
fi

# Single take "stp1-release" app flavor
if grep -q "SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS.*true" "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/cameradata/camera-feature.xml" 2> /dev/null && \
        ! grep -q "SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS.*true" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
    ADD_TO_WORK_DIR "a73xqxx" "system" "system/priv-app/SingleTakeService/SingleTakeService.apk" 0 0 644 "u:object_r:system_file:s0"
elif ! grep -q "SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS.*true" "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/cameradata/camera-feature.xml" 2> /dev/null && \
        grep -q "SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS.*true" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
    # TODO handle this condition
    # shellcheck disable=SC2034
    SOURCE_SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS=false
    # shellcheck disable=SC2034
    TARGET_SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS=true
    LOG_MISSING_PATCHES "SOURCE_SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS" "TARGET_SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS"
    unset SOURCE_SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS TARGET_SUPPORT_SINGLE_TAKE_HIGHLIGHT_VIDEOS
fi

# SEC_PRODUCT_FEATURE_CAMERA_SINGLETAKE_SOLUTIONS
if ! grep -q "ENABLE_SINGLE_TAKE_LITE.*true" "$WORK_DIR/system/system/cameradata/singletake/service-feature.xml" 2>/dev/null && \
        ! grep -q "SUPPORT_SMART_CROP.*false" "$WORK_DIR/system/system/cameradata/singletake/service-feature.xml" 2>/dev/null; then
    SOURCE_SMART_CROP_DIR="$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/etc/singletake/SmartCrop"
    TARGET_SMART_CROP_DIR="$WORK_DIR/vendor/etc/singletake/SmartCrop"
    SOURCE_SALIENCY_DIR="$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/etc/singletake/saliency"
    TARGET_SALIENCY_DIR="$WORK_DIR/vendor/etc/singletake/saliency"
    if [ -d "$SOURCE_SMART_CROP_DIR" ]; then
        if [ ! -d "$WORK_DIR/vendor/etc/singletake/SmartCrop" ] || \
                [ "$TARGET_PLATFORM_SDK_VERSION" -lt "$SOURCE_PLATFORM_SDK_VERSION" ]; then
            ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" \
                "etc/singletake/SmartCrop/SmartCrop.tflite" 0 0 644 "u:object_r:vendor_configs_file:s0"
        fi
    elif [ -d "$SOURCE_SALIENCY_DIR" ] && [ -d "$TARGET_SALIENCY_DIR" ]; then
        # Android 16/17 donors replaced the legacy SmartCrop.tflite directory
        # with the saliency model closure. The target already has that modern
        # closure, so the true feature flag is valid without the old blob.
        if [ -d "$TARGET_SMART_CROP_DIR" ]; then
            DELETE_FROM_WORK_DIR "vendor" "etc/singletake/SmartCrop"
        fi
        LOG "- Keeping the modern SingleTake saliency Smart Crop implementation"
    elif [ -d "$SOURCE_SALIENCY_DIR" ]; then
        if [ -d "$TARGET_SMART_CROP_DIR" ]; then
            DELETE_FROM_WORK_DIR "vendor" "etc/singletake/SmartCrop"
        fi
        ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" \
            "etc/singletake/saliency" 0 0 755 "u:object_r:vendor_configs_file:s0"
    else
        # TODO handle this condition
        # shellcheck disable=SC2034
        SOURCE_SUPPORT_SMART_CROP=false
        # shellcheck disable=SC2034
        TARGET_SUPPORT_SMART_CROP=true
        LOG_MISSING_PATCHES "SOURCE_SUPPORT_SMART_CROP" "TARGET_SUPPORT_SMART_CROP"
        unset SOURCE_SUPPORT_SMART_CROP TARGET_SUPPORT_SMART_CROP
    fi
    unset SOURCE_SMART_CROP_DIR TARGET_SMART_CROP_DIR SOURCE_SALIENCY_DIR TARGET_SALIENCY_DIR
else
    if [ -d "$WORK_DIR/vendor/etc/singletake/SmartCrop" ]; then
        DELETE_FROM_WORK_DIR "vendor" "etc/singletake/SmartCrop"
    fi
fi

# SEC_PRODUCT_FEATURE_CAMERA_CONFIG_ACTION_CLASSIFIER
SOURCE_CAMERA_CONFIG_ACTION_CLASSIFIER="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_CAMERA_CONFIG_ACTION_CLASSIFIER")"
TARGET_CAMERA_CONFIG_ACTION_CLASSIFIER="$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_CONFIG_ACTION_CLASSIFIER")"
if [ "$SOURCE_CAMERA_CONFIG_ACTION_CLASSIFIER" ]; then
    if [ "$TARGET_CAMERA_CONFIG_ACTION_CLASSIFIER" ]; then
        SOURCE_DYNAMIC_VIEWING_DIR="$FW_DIR/$SOURCE_FIRMWARE_PATH/vendor/etc/singletake/dynamic_viewing"
        TARGET_DYNAMIC_VIEWING_DIR="$WORK_DIR/vendor/etc/singletake/dynamic_viewing"
        if [ -d "$SOURCE_DYNAMIC_VIEWING_DIR" ]; then
            if [ -d "$TARGET_DYNAMIC_VIEWING_DIR" ]; then
                DELETE_FROM_WORK_DIR "vendor" "etc/singletake/dynamic_viewing"
            fi
            ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "vendor" "etc/singletake/dynamic_viewing" \
                0 2000 755 "u:object_r:vendor_configs_file:s0"
        elif [ -d "$TARGET_DYNAMIC_VIEWING_DIR" ]; then
            # S947B advertises the feature but no longer ships the old vendor
            # model directory. Keep the target's complete closure instead of
            # deleting it and aborting on a missing donor path.
            LOG "- Keeping target SingleTake dynamic_viewing closure; donor has no replacement"
        else
            LOGW "Neither donor nor target provides dynamic_viewing; removing its native classifier libraries"
            DELETE_FROM_WORK_DIR "system" "system/lib64/libVideoClassifier.camera.samsung.so"
            DELETE_FROM_WORK_DIR "system" "system/lib64/libtensorflowLite2_11_0_dynamic_camera.so"
        fi
        unset SOURCE_DYNAMIC_VIEWING_DIR TARGET_DYNAMIC_VIEWING_DIR
    else
        DELETE_FROM_WORK_DIR "system" "system/lib64/libVideoClassifier.camera.samsung.so"
        DELETE_FROM_WORK_DIR "system" "system/lib64/libtensorflowLite2_11_0_dynamic_camera.so"
    fi
else
    if [ "$TARGET_CAMERA_CONFIG_ACTION_CLASSIFIER" ]; then
        # TODO handle this condition
        LOG_MISSING_PATCHES "SOURCE_CAMERA_CONFIG_ACTION_CLASSIFIER" "TARGET_CAMERA_CONFIG_ACTION_CLASSIFIER"
    fi
fi

# SEC_PRODUCT_FEATURE_CAMERA_CONFIG_GPPM_SOLUTIONS
SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_CAMERA_CONFIG_GPPM_SOLUTIONS")"
TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS="$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_CONFIG_GPPM_SOLUTIONS")"
if [[ "$SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" != "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" ]]; then
    if [ "$SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" ]; then
        if [ ! "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" ] && \
                [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/priv-app/GlobalPostProcMgr/GlobalPostProcMgr.apk" ]; then
            DELETE_FROM_WORK_DIR "system" "system/etc/default-permissions/default-permissions-com.samsung.android.globalpostprocmgr.xml"
            DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.globalpostprocmgr.xml"
            DELETE_FROM_WORK_DIR "system" "system/priv-app/GlobalPostProcMgr"
        fi
        if [[ "$SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" == *"startrail"* ]] && \
                [[ "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" != *"startrail"* ]]; then
            DELETE_FROM_WORK_DIR "system" "system/lib64/libstartrail.camera.samsung.so"
        elif [[ "$SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" != *"startrail"* ]] && \
                [[ "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" == *"startrail"* ]]; then
            # TODO handle this condition
            LOG_MISSING_PATCHES "SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" "TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS"
        fi
        if [[ "$SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" == *"motionclipper"* ]] && \
                [[ "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" != *"motionclipper"* ]]; then
            DELETE_FROM_WORK_DIR "system" "system/lib64/libdvs.camera.samsung.so"
        elif [[ "$SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" != *"motionclipper"* ]] && \
                [[ "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" == *"motionclipper"* ]]; then
            # TODO handle this condition
            LOG_MISSING_PATCHES "SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" "TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS"
        fi
    else
        if [ "$TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS" ]; then
            # TODO handle this condition
            LOG_MISSING_PATCHES "SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS" "TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS"
        fi
    fi
fi

# SEC_PRODUCT_FEATURE_CAMERA_SUPPORT_SDK_SERVICE
if $SOURCE_CAMERA_SUPPORT_SDK_SERVICE; then
    if ! $TARGET_CAMERA_SUPPORT_SDK_SERVICE; then
        DELETE_FROM_WORK_DIR "system" "system/etc/permissions/cameraservice.xml"
        DELETE_FROM_WORK_DIR "system" "system/framework/scamera_sep.jar"
        DELETE_FROM_WORK_DIR "system" "system/priv-app/SCameraSDKService"
    fi
else
    if $TARGET_CAMERA_SUPPORT_SDK_SERVICE; then
        # TODO handle this condition
        LOG_MISSING_PATCHES "SOURCE_CAMERA_SUPPORT_SDK_SERVICE" "TARGET_CAMERA_SUPPORT_SDK_SERVICE"
    fi
fi

# SEC_PRODUCT_FEATURE_CAMERA_SUPPORT_CAMERAX_EXTENSION
if $SOURCE_CAMERA_SUPPORT_CAMERAX_EXTENSION; then
    if ! $TARGET_CAMERA_SUPPORT_CAMERAX_EXTENSION; then
        DELETE_FROM_WORK_DIR "system" "system/etc/permissions/sec_camerax_impl.xml"
        DELETE_FROM_WORK_DIR "system" "system/etc/permissions/sec_camerax_service.xml"
        DELETE_FROM_WORK_DIR "system" "system/framework/sec_camerax_impl.jar"
        DELETE_FROM_WORK_DIR "system" "system/lib/libsec_camerax_util_jni.camera.samsung.so"
        DELETE_FROM_WORK_DIR "system" "system/lib64/libsec_camerax_util_jni.camera.samsung.so"
        DELETE_FROM_WORK_DIR "system" "system/priv-app/sec_camerax_service"
        SET_PROP "system" "ro.camerax.extensions.enabled" --delete
    fi
else
    if $TARGET_CAMERA_SUPPORT_CAMERAX_EXTENSION; then
        # TODO handle this condition
        LOG_MISSING_PATCHES "SOURCE_CAMERA_SUPPORT_CAMERAX_EXTENSION" "TARGET_CAMERA_SUPPORT_CAMERAX_EXTENSION"
    fi
fi

# SEC_PRODUCT_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION
SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION")"
TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION="$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_GALLERY_CONFIG_PET_CLUSTER_VERSION")"
if [[ "$SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION" != "None" ]]; then
    if [[ "$TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION" == "None" ]]; then
        DELETE_FROM_WORK_DIR "system" "system/etc/default-permissions/default-permissions-com.samsung.petservice.xml"
        DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.petservice.xml"
        DELETE_FROM_WORK_DIR "system" "system/lib64/libPetClustering.camera.samsung.so"
        DELETE_FROM_WORK_DIR "system" "system/priv-app/PetService"
    fi
else
    if [[ "$TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION" != "None" ]]; then
        # TODO handle this condition
        LOG_MISSING_PATCHES "SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION" "TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION"
    fi
fi

# SEC_PRODUCT_FEATURE_SAIV_CONFIG_ARDOODLE_LIB
SOURCE_SAIV_CONFIG_ARDOODLE_LIB="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_SAIV_CONFIG_ARDOODLE_LIB")"
TARGET_SAIV_CONFIG_ARDOODLE_LIB="$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_SAIV_CONFIG_ARDOODLE_LIB")"
if [[ "$SOURCE_SAIV_CONFIG_ARDOODLE_LIB" != "$TARGET_SAIV_CONFIG_ARDOODLE_LIB" ]]; then
    if [ "$SOURCE_SAIV_CONFIG_ARDOODLE_LIB" ]; then
        if [[ "$SOURCE_SAIV_CONFIG_ARDOODLE_LIB" == *"IMG_PICKING"* ]] && \
                [[ "$TARGET_SAIV_CONFIG_ARDOODLE_LIB" != *"IMG_PICKING"* ]]; then
            DELETE_FROM_WORK_DIR "system" "system/etc/ardoodle"
        elif [[ "$SOURCE_SAIV_CONFIG_ARDOODLE_LIB" != *"IMG_PICKING"* ]] && \
                [[ "$TARGET_SAIV_CONFIG_ARDOODLE_LIB" == *"IMG_PICKING"* ]]; then
            # TODO handle this condition
            LOG_MISSING_PATCHES "SOURCE_SAIV_CONFIG_ARDOODLE_LIB" "TARGET_SAIV_CONFIG_ARDOODLE_LIB"
        fi
    else
        if [ "$TARGET_SAIV_CONFIG_ARDOODLE_LIB" ]; then
            # TODO handle this condition
            LOG_MISSING_PATCHES "SOURCE_SAIV_CONFIG_ARDOODLE_LIB" "TARGET_SAIV_CONFIG_ARDOODLE_LIB"
        fi
    fi
fi

# Camera libs debloat
if ! grep -q "\"system\"" "$WORK_DIR/system/system/cameradata/portrait_data/single_bokeh_feature.json" 2> /dev/null; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libRelighting_API.camera.samsung.so"
fi
if ! grep -q "SUPPORT_PET_DETECTION.*true" "$WORK_DIR/system/system/cameradata/singletake/service-feature.xml" 2> /dev/null && \
        [[ "$TARGET_SAIV_CONFIG_ARDOODLE_LIB" != *"PET_DETECTION"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/lib_pet_detection.arcsoft.so"
fi
if ! grep -q "SUPPORT_SINGLE_TAKE_BURST_CAPTURE.*true" "$WORK_DIR/system/system/cameradata/camera-feature.xml" 2> /dev/null; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libBestPhoto.camera.samsung.so"
fi
SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_CAMERA_CONFIG_VENDOR_LIB_INFO")"
TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO="$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_CONFIG_VENDOR_LIB_INFO")"
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"aebhdr.arcsoft.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"aebhdr.arcsoft.v1"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libAEBHDR_wrapper.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libae_bracket_hdr.arcsoft.so"
fi
if [ -f "$WORK_DIR/vendor/lib64/libDualCamBokehCapture.camera.samsung.so" ] || {
    [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"dual_bokeh.samsung"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"dual_bokeh.samsung"* ]]
}; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libDualCamBokehCapture.camera.samsung.so"
    if [ ! -f "$WORK_DIR/system/system/lib64/libRelighting_API.camera.samsung.so" ]; then
        DELETE_FROM_WORK_DIR "system" "system/lib64/libarcsoft_dualcam_portraitlighting.so"
    fi
    if ! grep -q "GlassSegSDK" "$WORK_DIR/system/system/cameradata/portrait_data/single_bokeh_feature.json" 2> /dev/null; then
        DELETE_FROM_WORK_DIR "system" "system/lib64/libarcsoft_single_cam_glasses_seg.so"
    fi
    DELETE_FROM_WORK_DIR "system" "system/lib64/libarcsoft_superresolution_bokeh.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libdualcam_refocus_image.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libhigh_dynamic_range_bokeh.so"
fi
if {
    [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"fusion_high_res.arcsoft.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"fusion_high_res.arcsoft.v1"* ]]
} || {
    [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"high_res.arcsoft.v2"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"high_res.arcsoft.v2"* ]]
}; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libHREnhancementAPI.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libhighres_enhancement.arcsoft.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"fr_tracking.arcsoft.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"fr_tracking.arcsoft.v1"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libFaceRecognition.arcsoft.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libfrtracking_engine.arcsoft.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"hybridhdr.arcsoft.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"hybridhdr.arcsoft.v1"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libhybridHDR_wrapper.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libhybrid_high_dynamic_range.arcsoft.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"image_enhance.arcsoft.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"image_enhance.arcsoft.v1"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libimage_enhancement.arcsoft.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"pro_single_rgb.mpi.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"pro_single_rgb.mpi.v1"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libAIQSolution_MPISingleRGB40.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libMPISingleRGB40.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libMPISingleRGB40Tuning.camera.samsung.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"scene_detection.samsung.v1"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"scene_detection.samsung.v1"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libSceneDetector_v1.camera.samsung.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"smart_scan.samsung"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"smart_scan.samsung"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libSmartScan.camera.samsung.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"super_night.mpi.v2"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"super_night.mpi.v2"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libAIQSolution_MPI.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libLocalTM_pcc.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libMultiFrameProcessing30.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libMultiFrameProcessing30.snapwrapper.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libMultiFrameProcessing30Tuning.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libObjectDetector_v1.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libSwIsp_core.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libSwIsp_wrapper_v1.camera.samsung.so"
fi
if [[ "$SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO" == *"super_resolution_raw.arcsoft"* ]] && \
        [[ "$TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO" != *"super_resolution_raw.arcsoft"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libsuperresolutionraw_wrapper_v2.camera.samsung.so"
    DELETE_FROM_WORK_DIR "system" "system/lib64/libsuperresolution_raw.arcsoft.so"
fi
SOURCE_CAMERA_DOCUMENTSCAN_SOLUTIONS="$(GET_FLOATING_FEATURE_CONFIG "$FW_DIR/$SOURCE_FIRMWARE_PATH/system/system/etc/floating_feature.xml" "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS")"
TARGET_CAMERA_DOCUMENTSCAN_SOLUTIONS="$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_DOCUMENTSCAN_SOLUTIONS")"
if [[ "$SOURCE_CAMERA_DOCUMENTSCAN_SOLUTIONS" == *"AI_DEWARPING"* ]] && \
        [[ "$TARGET_CAMERA_DOCUMENTSCAN_SOLUTIONS" != *"AI_DEWARPING"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libDeepDocRectify.camera.samsung.so"
fi
if [[ "$SOURCE_CAMERA_DOCUMENTSCAN_SOLUTIONS" == *"SHADOW_REMOVAL"* ]] && \
        [[ "$TARGET_CAMERA_DOCUMENTSCAN_SOLUTIONS" != *"SHADOW_REMOVAL"* ]]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libDocShadowRemoval.arcsoft.so"
fi
if [ -f "$WORK_DIR/system/system/lib64/libImageSegmenter_v1.camera.samsung.so" ] && \
        [ ! -d "$WORK_DIR/vendor/etc/portrait_data/LF_segmenter" ]; then
    DELETE_FROM_WORK_DIR "system" "system/lib64/libImageSegmenter_v1.camera.samsung.so"
fi

# Fix device model number in photo/video metadata
while IFS= read -r f; do
    HEX_PATCH "$f" "726f2e70726f647563742e6d6f64656c00" "726f2e626f6f742e656d2e6d6f64656c00"
done < <(grep -r -w -l "ro.product.model" "$WORK_DIR/vendor" | grep "camera")
if [ -f "$WORK_DIR/system/system/lib/libstagefright.so" ]; then
    HEX_PATCH "$WORK_DIR/system/system/lib/libstagefright.so" \
        "726f2e70726f647563742e6d6f64656c00" "726f2e626f6f742e656d2e6d6f64656c00"
else
    # Android 16/17 source firmware is arm64-only and does
    # not ship the legacy 32-bit stagefright library.
    LOG "- Skipping 32-bit libstagefright model patch (library is absent)"
fi
if [ -f "$WORK_DIR/system/system/lib64/libstagefright.so" ]; then
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "726f2e70726f647563742e6d6f64656c00" "726f2e626f6f742e656d2e6d6f64656c00"
    # Fix the ARM64 __fread_chk buffer overflow in
    # ACodec::reconfigEncoder4OtherApps.
    # Source platform's ACodec reads 512 bytes into a 255-byte buffer via __fread_chk,
    # causing SIGABRT in mediaserver when third-party apps (WhatsApp/Telegram) use
    # the video encoder. Patch the read size from 0x200 to 0xff to match the buffer.
    HEX_PATCH "$WORK_DIR/system/system/lib64/libstagefright.so" \
        "02408052e30314aae41f8052" "e21f8052e30314aae41f8052"
else
    LOG "- Skipping 64-bit libstagefright model patch (library is absent)"
fi

# Fix object capture
if [[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "essi" ]]; then
    if [[ "$TARGET_PLATFORM" == "exynos990" ]] && \
            cmp -s "$WORK_DIR/system/system/lib64/libobjectcapture_jni.arcsoft.so" \
                "$SRC_DIR/platform/exynos990/patches/camera/system/lib64/libobjectcapture_jni.arcsoft.so"; then
        LOG "- Object capture already uses the Exynos 990 target-compatible blob"
    elif {
        [[ "$(GET_PROP "system" "ro.product.device")" =~ r0|g0|b0 ]] && \
            ! [[ "$(GET_PROP "vendor" "ro.product.vendor.device")" =~ r0|g0|b0 ]]
    } || {
        [[ "$(GET_PROP "system" "ro.product.device")" == "a56"* ]] && \
            [[ "$(GET_PROP "vendor" "ro.product.vendor.device")" != "a56"* ]]
    }; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libobjectcapture_jni.arcsoft.so" \
            "e503162a47020094e022009121008052e203162a" "8500805247020094e02200912100805282008052"
    elif ! [[ "$(GET_PROP "system" "ro.product.device")" =~ r0|g0|b0 ]] && \
            [[ "$(GET_PROP "vendor" "ro.product.vendor.device")" =~ r0|g0|b0 ]]; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libobjectcapture_jni.arcsoft.so" \
            "e503162a47020094e022009121008052e203162a" "4500805247020094e02200912100805242008052"
    elif [[ "$(GET_PROP "system" "ro.product.device")" != "a56"* ]] && \
            [[ "$(GET_PROP "vendor" "ro.product.vendor.device")" == "a56"* ]]; then
        HEX_PATCH "$WORK_DIR/system/system/lib64/libobjectcapture_jni.arcsoft.so" \
            "e503162a47020094e022009121008052e203162a" "c500805247020094e022009121008052c2008052"
    fi
fi

# Fix portrait mode
if [ -f "$WORK_DIR/vendor/lib64/libDualCamBokehCapture.camera.samsung.so" ]; then
    if grep -q "ro.build.flavor" "$WORK_DIR/vendor/lib64/libDualCamBokehCapture.camera.samsung.so" 2> /dev/null; then
        SET_PROP "system" "ro.build.flavor" "$(GET_PROP "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/build.prop" "ro.build.flavor")"
    elif grep -q "ro.product.name" "$WORK_DIR/vendor/lib64/libDualCamBokehCapture.camera.samsung.so" 2> /dev/null; then
        HEX_PATCH "$WORK_DIR/vendor/lib/libDualCamBokehCapture.camera.samsung.so" \
            "726f2e70726f647563742e6e616d6500" "726f2e756e6963612e63616d65726100"
        HEX_PATCH "$WORK_DIR/vendor/lib/liblivefocus_capture_engine.so" \
            "726f2e70726f647563742e6e616d6500" "726f2e756e6963612e63616d65726100"
        HEX_PATCH "$WORK_DIR/vendor/lib/liblivefocus_preview_engine.so" \
            "726f2e70726f647563742e6e616d6500" "726f2e756e6963612e63616d65726100"
        HEX_PATCH "$WORK_DIR/vendor/lib64/libDualCamBokehCapture.camera.samsung.so" \
            "726f2e70726f647563742e6e616d6500" "726f2e756e6963612e63616d65726100"
        HEX_PATCH "$WORK_DIR/vendor/lib64/liblivefocus_capture_engine.so" \
            "726f2e70726f647563742e6e616d6500" "726f2e756e6963612e63616d65726100"
        HEX_PATCH "$WORK_DIR/vendor/lib64/liblivefocus_preview_engine.so" \
            "726f2e70726f647563742e6e616d6500" "726f2e756e6963612e63616d65726100"
        LOG "- Patching /system/system/etc/selinux/plat_property_contexts"
        EVAL "echo \"ro.unica.camera u:object_r:build_prop:s0 exact string\" >> \"$WORK_DIR/system/system/etc/selinux/plat_property_contexts\""
        SET_PROP "system" "ro.unica.camera" "$(GET_PROP "$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/build.prop" "ro.product.system.name")"
    fi
fi

# Enable camera cutout protection
# Skip patch if SystemUI RRO exists
if [ ! "$(find "$WORK_DIR/product/overlay" -maxdepth 1 -type f -name "SystemUI*" 2> /dev/null)" ]; then
    if [[ "$SOURCE_CAMERA_SUPPORT_CUTOUT_PROTECTION" != "$TARGET_CAMERA_SUPPORT_CUTOUT_PROTECTION" ]]; then
        DECODE_APK "system_ext" "priv-app/SystemUI/SystemUI.apk"
        if $TARGET_CAMERA_SUPPORT_CUTOUT_PROTECTION; then
            LOG "- Enabling camera cutout protection"
        else
            LOG "- Disabling camera cutout protection"
        fi
        EVAL "sed -i \"s/config_enableDisplayCutoutProtection\\\">$SOURCE_CAMERA_SUPPORT_CUTOUT_PROTECTION/config_enableDisplayCutoutProtection\\\">$TARGET_CAMERA_SUPPORT_CUTOUT_PROTECTION/\" \"$APKTOOL_DIR/system_ext/priv-app/SystemUI/SystemUI.apk/res/values/bools.xml\""
    fi
fi

unset SOURCE_FIRMWARE_PATH TARGET_FIRMWARE_PATH \
    SOURCE_CAMERA_CONFIG_ACTION_CLASSIFIER TARGET_CAMERA_CONFIG_ACTION_CLASSIFIER \
    SOURCE_CAMERA_CONFIG_GPPM_SOLUTIONS TARGET_CAMERA_CONFIG_GPPM_SOLUTIONS \
    SOURCE_GALLERY_CONFIG_PET_CLUSTER_VERSION TARGET_GALLERY_CONFIG_PET_CLUSTER_VERSION \
    SOURCE_SAIV_CONFIG_ARDOODLE_LIB TARGET_SAIV_CONFIG_ARDOODLE_LIB \
    SOURCE_CAMERA_CONFIG_VENDOR_LIB_INFO TARGET_CAMERA_CONFIG_VENDOR_LIB_INFO \
    SOURCE_CAMERA_DOCUMENTSCAN_SOLUTIONS TARGET_CAMERA_DOCUMENTSCAN_SOLUTIONS
unset -f _LOG LOG_MISSING_PATCHES
