# shellcheck disable=SC2034
SKIPUNZIP=1

if [[ "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_FMRADIO_CONFIG_CHIP_VENDOR")" == "0" ]]; then
    LOG "\033[0;33m! Nothing to do\033[0m"
    return 0
fi

FM_TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
FM_TARGET_DIR="$FW_DIR/$FM_TARGET_FIRMWARE_PATH/system/system"

if [ ! "$(GET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_FMRADIO_SUPPORT_EXTERNAL_RADIO_CHIPSET")" ]; then
    if [ ! -f "$WORK_DIR/system/system/lib64/libfmradio_jni.so" ]; then
        if [ -f "$FM_TARGET_DIR/lib64/libfmradio_jni.so" ]; then
            LOG "- Adding target FM Radio 64-bit JNI library"
            ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
                "system/lib64/libfmradio_jni.so" 0 0 644 "u:object_r:system_lib_file:s0"
        else
            ABORT "SEC_FLOATING_FEATURE_FMRADIO_SUPPORT_EXTERNAL_RADIO_CHIPSET is not set and target firmware has no libfmradio_jni.so"
        fi
    fi
    if [ ! -f "$WORK_DIR/system/system/lib/libfmradio_jni.so" ] && \
            [ -f "$FM_TARGET_DIR/lib/libfmradio_jni.so" ]; then
        LOG "- Adding target FM Radio 32-bit JNI library"
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib/libfmradio_jni.so" 0 0 644 "u:object_r:system_lib_file:s0"
    fi
fi

ADD_TO_WORK_DIR "$MODPATH" "system" "." 0 0 755 "u:object_r:system_file:s0"
FM_APP="$WORK_DIR/system/system/priv-app/HybridRadio/HybridRadio.apk"
FM_TARGET_APP="$FM_TARGET_DIR/priv-app/HybridRadio/HybridRadio.apk"
if [ -f "$FM_APP" ]; then
    LOG "- Keeping FM Radio app from the source firmware"
elif [ -f "$FM_TARGET_APP" ]; then
    LOG "- Adding target FM Radio app (Galaxy Store URI unavailable)"
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
        "system/priv-app/HybridRadio/HybridRadio.apk" 0 0 644 "u:object_r:system_file:s0"
    if [ -f "$FM_TARGET_APP.prof" ]; then
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/priv-app/HybridRadio/HybridRadio.apk.prof" 0 0 644 "u:object_r:system_file:s0"
    fi
else
    FM_DOWNLOAD_URL="$(GET_GALAXY_STORE_DOWNLOAD_URL "com.sec.android.app.fm" || true)"
    if [ "$FM_DOWNLOAD_URL" ]; then
        LOG "- Downloading latest FM Radio app"
        DOWNLOAD_FILE "$FM_DOWNLOAD_URL" "$FM_APP"
    else
        ABORT "FM Radio app is unavailable from Galaxy Store and target firmware"
    fi
fi
SET_METADATA "system" "system/priv-app/HybridRadio" 0 0 755 "u:object_r:system_file:s0"
SET_METADATA "system" "system/priv-app/HybridRadio/HybridRadio.apk" 0 0 644 "u:object_r:system_file:s0"

unset FM_TARGET_FIRMWARE_PATH FM_TARGET_DIR FM_APP FM_TARGET_APP FM_DOWNLOAD_URL
