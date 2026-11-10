#!/usr/bin/env bash

# The Android 17 donor uses a different VRR policy: its framework hard-codes
# HFR mode 4 and makes FHD/120 the preferred configuration.  The Exynos 990
# panel advertises QHD only at 48/60 Hz, so SurfaceFlinger applies QHD through
# HWC2 and immediately requests FHD again.  Keep the Android 17 display stack,
# but make its policy match the target vendor/HWC configuration.

if [[ "$TARGET_PLATFORM" != "exynos990" ]]; then
    return 0
fi

SET_VENDOR_FLOATING_FEATURE_CONFIG()
{
    local CONFIG="$1"
    local VALUE="$2"
    local FILE="$WORK_DIR/vendor/etc/floating_feature.xml"

    [ -f "$FILE" ] || {
        ABORT "Missing vendor floating feature table for Exynos 990 display policy"
        return 1
    }

    if grep -q -F "<${CONFIG}>" "$FILE"; then
        sed -i "\\|<${CONFIG}>|d" "$FILE" || return 1
    fi

    if [[ "$VALUE" != "--delete" ]]; then
        grep -q -F '</SecFloatingFeatureSet>' "$FILE" || {
            ABORT "Vendor floating feature table has no closing SecFloatingFeatureSet tag"
            return 1
        }
        sed -i "/<\\/SecFloatingFeatureSet>/i\\    <${CONFIG}>${VALUE}</${CONFIG}>" "$FILE" || return 1
    fi
}

SYNC_DISPLAY_FEATURE()
{
    SET_FLOATING_FEATURE_CONFIG "$1" "$2" || return 1
    SET_VENDOR_FLOATING_FEATURE_CONFIG "$1" "$2" || return 1
}

LOG "- Synchronizing Exynos 990 QHD/FHD and HFR policy"
TARGET_DYNAMIC_RESOLUTION="${TARGET_COMMON_CONFIG_DYN_RESOLUTION_CONTROL:-WQHD,FHD,HD}"
TARGET_DEFAULT_SCREEN_MODE="${TARGET_LCD_CONFIG_DEFAULT_SCREEN_MODE:-4}"
SYNC_DISPLAY_FEATURE "SEC_FLOATING_FEATURE_COMMON_CONFIG_DYN_RESOLUTION_CONTROL" "$TARGET_DYNAMIC_RESOLUTION" || return 1
SYNC_DISPLAY_FEATURE "SEC_FLOATING_FEATURE_LCD_CONFIG_DEFAULT_SCREEN_MODE" "$TARGET_DEFAULT_SCREEN_MODE" || return 1
SYNC_DISPLAY_FEATURE "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE" "$TARGET_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE" || return 1
SYNC_DISPLAY_FEATURE "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_MODE" "$TARGET_LCD_CONFIG_HFR_MODE" || return 1
SYNC_DISPLAY_FEATURE "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" "$TARGET_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" || return 1
SYNC_DISPLAY_FEATURE "SEC_FLOATING_FEATURE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE_NS" "$TARGET_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE_NS" || return 1

# These literals are the Android 17 source policy read by framework and
# Settings.  Restrict every replacement to its owning method so unrelated
# numeric values cannot be changed by accident.  SMALI_PATCH treats an
# already-patched decoded cache as success and fails on a changed source layout.
REFRESH_CONFIG="smali_classes6/com/samsung/android/hardware/display/RefreshRateConfig.smali"

if [[ "$TARGET_LCD_CONFIG_HFR_MODE" != "4" ]]; then
    SMALI_PATCH "system" "system/framework/framework.jar" "$REFRESH_CONFIG" "replace" \
        "getMainInstance()Lcom/samsung/android/hardware/display/RefreshRateConfig;" \
        "4" "$TARGET_LCD_CONFIG_HFR_MODE" || return 1
fi
SMALI_PATCH "system" "system/framework/framework.jar" "$REFRESH_CONFIG" "replace" \
    "getMainInstance()Lcom/samsung/android/hardware/display/RefreshRateConfig;" \
    "1,60,120" "$TARGET_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" || return 1
SMALI_PATCH "system" "system/framework/framework.jar" "$REFRESH_CONFIG" "replace" \
    "dumpProductFeature(Ljava/io/PrintWriter;Ljava/lang/String;Z)V" \
    "HFR_DEFAULT_REFRESH_RATE: 120" "HFR_DEFAULT_REFRESH_RATE: $TARGET_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE" || return 1
if [[ "$TARGET_LCD_CONFIG_HFR_MODE" != "4" ]]; then
    SMALI_PATCH "system" "system/framework/framework.jar" "$REFRESH_CONFIG" "replace" \
        "dumpProductFeature(Ljava/io/PrintWriter;Ljava/lang/String;Z)V" \
        "4" "$TARGET_LCD_CONFIG_HFR_MODE" || return 1
fi
SMALI_PATCH "system" "system/framework/framework.jar" "$REFRESH_CONFIG" "replace" \
    "dumpProductFeature(Ljava/io/PrintWriter;Ljava/lang/String;Z)V" \
    "1,60,120" "$TARGET_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE" || return 1

if [[ "$TARGET_LCD_CONFIG_HFR_MODE" != "4" ]]; then
    SMALI_PATCH "system_ext" "priv-app/SystemUI/SystemUI.apk" \
        "smali/com/android/systemui/BasicRune.smali" "replace" "<clinit>()V" \
        "4" "$TARGET_LCD_CONFIG_HFR_MODE" || return 1
    SMALI_PATCH "system_ext" "priv-app/SystemUI/SystemUI.apk" \
        "smali/com/android/systemui/LsRune.smali" "replace" "<clinit>()V" \
        "4" "$TARGET_LCD_CONFIG_HFR_MODE" || return 1
    SMALI_PATCH "system" "system/framework/services.jar" \
        "smali_classes2/com/android/server/power/PowerManagerUtil.smali" "replace" "<clinit>()V" \
        "4" "$TARGET_LCD_CONFIG_HFR_MODE" || return 1
fi

# The source reads match_content_frame_rate as switching type 1
# (WITHIN_GROUPS).  QHD and FHD are separate HWC groups on Exynos 990, so that
# policy rejects every resolution transition even when the requested mode is
# valid.  Force type 2 only for this target: ACROSS_AND_WITHIN_GROUPS keeps the
# normal refresh-rate constraints while allowing the panel geometry to change.
MODE_DIRECTOR_SETTINGS="smali/com/android/server/display/mode/DisplayModeDirector\$SettingsObserver.smali"
SMALI_PATCH "system" "system/framework/services.jar" "$MODE_DIRECTOR_SETTINGS" "replace" \
    "updateModeSwitchingTypeSettingLocked()V" \
    "if-eq v0, v1, :cond_0" \
    "    const/4 v0, 0x2"$'\n\n    '"if-eq v0, v1, :cond_0" || return 1

# Android 17 re-votes the resolution whenever the logical display changes.
# On the Exynos 990 HWC this observes the old FHD mode while a QHD request is
# pending, then overwrites that request at the same vote priority. Keep the
# normal user-preferred-mode path intact and skip only this feedback vote.
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/display/DisplayManagerService.smali" "replace" \
    "handleLogicalDisplayChangedPreProcessLocked(Lcom/android/server/display/LogicalDisplay;)V" \
    "if-eqz v1, :cond_1" \
    "if-eqz v0, :cond_1" || return 1

unset REFRESH_CONFIG MODE_DIRECTOR_SETTINGS TARGET_DYNAMIC_RESOLUTION TARGET_DEFAULT_SCREEN_MODE
unset -f SET_VENDOR_FLOATING_FEATURE_CONFIG SYNC_DISPLAY_FEATURE
