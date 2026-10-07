# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

LOG "- Applying M21s display/camera compatibility policy"

# The ESSI donor preserves its native display stack.  Publish the actual
# F415/M21s policy after all common/target merges so the system table cannot
# retain the S24+ 120-Hz and dynamic-resolution values.
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_COMMON_CONFIG_DYN_RESOLUTION_CONTROL" --delete
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_LCD_CONFIG_CONTROL_AUTO_BRIGHTNESS" "3"
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE" "60"
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_MODE" "0"
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" "0"
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE_NS" "60"
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_AUTO_BRIGTNESS" "TRUE"
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_LCD_SUPPORT_EXTRA_BRIGHTNESS" --delete

# SamsungCamera's imported S24+ code rejects the stock F415 sentinel (-1) in
# getResolution().  Zero is the valid "no extra profile" value and prevents
# the CamSettingBackgroundHandlerThread IllegalArgumentException seen in the
# 2026-10-03 boot log.
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE" "0"

# The Android 17 SamsungCamera APK contains the generic node loader, but its
# F415F feature table selects the legacy target processors below. The common
# camera cleanup removes these because the S24+ donor does not advertise them;
# restore only the 64-bit F415F implementations required by the M21s camera.
# They are loaded by libnode-jni at shutter/post-processing time, so the
# preview can work while capture still aborts when the closure is absent.
for CAMERA_PROCESSOR in \
    "system/lib64/libMultiFrameProcessing10.camera.samsung.so" \
    "system/lib64/liblow_light_hdr.arcsoft.so" \
    "system/lib64/libhigh_dynamic_range.arcsoft.so"; do
    ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "$CAMERA_PROCESSOR" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
done

# A late dlopen from SamsungCamera is checked against this camera-specific
# public-library namespace. Publish the target closure explicitly; the target
# firmware lists only MFP10, while LLHDR/HDR are reached by the node loader
# and must also be visible in this mixed source/target image.
CAMERA_PUBLIC_LIBS="$WORK_DIR/system/system/etc/public.libraries-camera.samsung.txt"
if [ ! -f "$CAMERA_PUBLIC_LIBS" ]; then
    ABORT "Samsung camera public-library list is missing"
    return 1
fi
for CAMERA_PUBLIC_LIB in \
    "libMultiFrameProcessing10.camera.samsung.so" \
    "liblow_light_hdr.arcsoft.so" \
    "libhigh_dynamic_range.arcsoft.so"; do
    grep -qxF "$CAMERA_PUBLIC_LIB" "$CAMERA_PUBLIC_LIBS" || \
        printf '%s\n' "$CAMERA_PUBLIC_LIB" >> "$CAMERA_PUBLIC_LIBS"
done
unset CAMERA_PROCESSOR CAMERA_PUBLIC_LIB CAMERA_PUBLIC_LIBS

# A prior M21s camera configuration could persist the S24+ 3264x1592 id (53)
# in SamsungCamera's private preferences.  The current stock M21s XML uses
# 9248x6936 (id 110) for the rear default and 4000x3000 (id 108) for front.
# Migrate only that stale id when the APK reads it; valid user choices and the
# XML-derived defaults remain untouched.
DECODE_APK "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" || return 1
APPLY_PATCH "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" \
    "$MODPATH/SamsungCamera.apk/0001-Migrate-stale-M21s-camera-resolution-preferences.patch" || return 1
APPLY_PATCH "system" "system/priv-app/SamsungCamera/SamsungCamera.apk" \
    "$MODPATH/SamsungCamera.apk/0002-Do-not-crash-when-high-resolution-zoom-is-fixed.patch" || return 1

DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk" || return 1
SETTINGS_APKTOOL="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

# Remove only the preferences; retain the underlying classes/resources so
# Settings remains linkable and the change is reversible.  The XML layout
# differs slightly between source revisions, hence key-based matching.
for SETTINGS_XML in \
    "$SETTINGS_APKTOOL/res/xml/display_settings.xml" \
    "$SETTINGS_APKTOOL/res/xml/sec_display_settings.xml"; do
    if [ ! -f "$SETTINGS_XML" ]; then
        LOGW "M21s display XML is missing: ${SETTINGS_XML//$APKTOOL_DIR\//}"
        continue
    fi
    EVAL "sed -i -E '/key=\"screen_resolution\"/d; /key=\"(extra_brightness|extra_brightness_caption|outdoor_mode|outdoor_mode_caption)\"/d' \"$SETTINGS_XML\""
done

# outdoor may have been applied to a decoded-cache APK by an earlier build;
# force its availability gate off as well as removing the preference rows.
OUTDOOR_CONTROLLER="$(find "$SETTINGS_APKTOOL" -type f \
    -path '*/com/samsung/android/settings/display/controller/SecOutDoorModePreferenceController.smali' \
    -printf '%P\n' -quit)"
if [ "$OUTDOOR_CONTROLLER" ]; then
    SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
        "$OUTDOOR_CONTROLLER" "return" 'isAvailable()Z' 'false'
else
    LOG "- SecOutDoorModePreferenceController is absent; XML-only outdoor removal is sufficient"
fi

# The M21s sensor HAL can drive the framework automatic-brightness path (the
# boot log contains AutomaticBrightnessStrategy events), but the imported
# Settings controller reports unavailable when its legacy light-sensor probe
# returns null. Change only the final unsupported fallback; admin, sensor
# privacy and desktop-display restrictions still return their original status.
AUTO_BRIGHTNESS_CONTROLLER="$(find "$SETTINGS_APKTOOL" -type f \
    -path '*/com/samsung/android/settings/display/controller/SecAutoBrightnessPreferenceController.smali' \
    -printf '%P\n' -quit)"
if [ "$AUTO_BRIGHTNESS_CONTROLLER" ]; then
    SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
        "$AUTO_BRIGHTNESS_CONTROLLER" "replace" 'getAvailabilityStatus()I' \
        'const/4 p0, 0x3' 'const/4 p0, 0x0' || return 1
else
    LOGW "SecAutoBrightnessPreferenceController is absent; retaining XML/feature-only auto brightness"
fi

unset SETTINGS_APKTOOL SETTINGS_XML OUTDOOR_CONTROLLER AUTO_BRIGHTNESS_CONTROLLER
