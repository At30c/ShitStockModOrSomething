if [[ "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" == "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" ]] && \
    [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" == "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]]; then
    LOG "\033[0;33m! Nothing to do\033[0m"
    return 0
fi

_LOG() { if $DEBUG; then LOGW "$1"; else ABORT "$1"; fi }

# Extract one decoded Smali method without interpolating its signature into a
# sed regular expression.  Constructor signatures contain slashes (for
# example Landroid/content/Context;), which would otherwise be interpreted as
# sed delimiters and make a valid source method look absent.
EXTRACT_METHOD()
{
    local FILE_PATH="$1"
    local METHOD="$2"

    awk -v method="$METHOD" '
        /^\.method[[:space:]]/ {
            in_method = (index($0, method) != 0)
        }
        in_method { print }
        in_method && /^\.end method[[:space:]]*$/ {
            in_method = 0
        }
    ' "$FILE_PATH"
}

# The source feature value is a product string, not an ABI constant.  When
# the donor firmware changes Samsung may rename it together with the SoC
# (for example e2s -> m2s) while keeping the same class and method.  Resolve
# the literal from the decoded method instead of making this patch depend on
# the previous S24+ source name.
RESOLVE_POLICY_LITERAL()
{
    local FILE_PATH="$1"
    local METHOD="$2"
    local EXPECTED="$3"
    local REPLACEMENT="$4"
    local LABEL="$5"
    local POLICY_PREFIX="${EXPECTED%%_*}"
    local METHOD_CONTENT
    local MATCHES

    METHOD_CONTENT="$(EXTRACT_METHOD "$FILE_PATH" "$METHOD")"
    if grep -Fq -- "\"$EXPECTED\"" <<< "$METHOD_CONTENT"; then
        printf '%s\n' "$EXPECTED"
        return 0
    fi
    if grep -Fq -- "\"$REPLACEMENT\"" <<< "$METHOD_CONTENT"; then
        LOG "- $LABEL already uses $REPLACEMENT" >&2
        # Return the configured value so SMALI_PATCH can detect the existing
        # replacement and skip without attempting a no-op edit.
        printf '%s\n' "$EXPECTED"
        return 0
    fi

    MATCHES="$(sed -nE "s/^[[:space:]]*const-string(\\/jumbo)?[[:space:]]+[^,]+,[[:space:]]+\"(${POLICY_PREFIX}_[A-Za-z0-9_]+)\"[[:space:]]*$/\\2/p" <<< "$METHOD_CONTENT" | sort -u)"
    if [ "$(printf '%s\n' "$MATCHES" | sed '/^$/d' | wc -l)" -eq 1 ]; then
        LOG "- Resolved $LABEL source literal: $MATCHES" >&2
        printf '%s\n' "$MATCHES"
        return 0
    fi

    _LOG "Unable to resolve the source policy literal in $LABEL"
    return 1
}

RESOLVE_SMALI_PATH()
{
    local ROOT="$1"
    local CANDIDATE="$2"
    local METHOD="$3"
    local VALUE="$4"
    local MATCHES

    if [ -f "$ROOT/$CANDIDATE" ] && \
            grep -Fq -- "\"$VALUE\"" \
            <(EXTRACT_METHOD "$ROOT/$CANDIDATE" "$METHOD"); then
        printf '%s\n' "$CANDIDATE"
        return 0
    fi
    MATCHES="$(grep -RFl --include='*.smali' -- "$VALUE" "$ROOT" || true)"
    if [ "$(printf '%s\n' "$MATCHES" | sed '/^$/d' | wc -l)" -eq 1 ]; then
        printf '%s\n' "${MATCHES#"$ROOT/"}"
        return 0
    fi
    printf '%s\n' "$CANDIDATE"
}

# Samsung renames the obfuscated SDHMS classes between platform releases.
# Keep the known One UI 8.0 paths as the default and select the newer paths
# for Android 16+ sources; the literal resolver below handles later renames.
DVFS_FEATURE_SMALI="smali/r1/c.smali"
DVFS_PROPERTIES_SMALI="smali/z1/e.smali"
SSRM_FEATURE_SMALI="smali/U1/w.smali"
if [ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]; then
    DVFS_FEATURE_SMALI="smali/c4/c.smali"
    DVFS_PROPERTIES_SMALI="smali/k4/e.smali"
    SSRM_FEATURE_SMALI="smali/o5/w.smali"
fi

# SEC_PRODUCT_FEATURE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME
if [[ "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" != "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" ]]; then
    DECODE_APK "system" "system/framework/ssrm.jar"
    SSRM_JAR_ROOT="$APKTOOL_DIR/system/framework/ssrm.jar"
    SSRM_JAR_FEATURE_SMALI="smali/com/android/server/ssrm/Feature.smali"
    SSRM_JAR_FEATURE_SMALI="$(RESOLVE_SMALI_PATH \
        "$SSRM_JAR_ROOT" "$SSRM_JAR_FEATURE_SMALI" \
        "<clinit>()V" "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME")" || return 1
    SSRM_JAR_FEATURE_LITERAL="$(RESOLVE_POLICY_LITERAL \
        "$SSRM_JAR_ROOT/$SSRM_JAR_FEATURE_SMALI" "<clinit>()V" \
        "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "ssrm.jar Feature")" || return 1
    SMALI_PATCH "system" "system/framework/ssrm.jar" \
        "$SSRM_JAR_FEATURE_SMALI" "replace" \
        "<clinit>()V" \
        "$SSRM_JAR_FEATURE_LITERAL" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME"

    DECODE_APK "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

    if [ -f "$SRC_DIR/target/$TARGET_CODENAME/dvfs/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml" ]; then
        LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml"
        EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/dvfs/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml\""
    elif [ ! -f "$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/res/raw/$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME.xml" ]; then
        _LOG "\"$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME\" does not exist in SDHMS app"
    fi

    # com/sec/android/sdhms/performance/PerformanceFeature
    SDHMS_ROOT="$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"
    DVFS_FEATURE_SMALI="$(RESOLVE_SMALI_PATH "$SDHMS_ROOT" "$DVFS_FEATURE_SMALI" \
        "<clinit>()V" "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME")" || return 1
    DVFS_FEATURE_LITERAL="$(RESOLVE_POLICY_LITERAL "$SDHMS_ROOT/$DVFS_FEATURE_SMALI" \
        "<clinit>()V" "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "SDHMS DVFS feature")" || return 1
    SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
        "$DVFS_FEATURE_SMALI" "replace" \
        "<clinit>()V" \
        "$DVFS_FEATURE_LITERAL" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME"
    # com/sec/android/sdhms/performance/settings/PerformanceProperties
    DVFS_PROPERTIES_SMALI="$(RESOLVE_SMALI_PATH "$SDHMS_ROOT" "$DVFS_PROPERTIES_SMALI" \
        "<init>(Landroid/content/Context;)V" "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME")" || return 1
    DVFS_PROPERTIES_LITERAL="$(RESOLVE_POLICY_LITERAL "$SDHMS_ROOT/$DVFS_PROPERTIES_SMALI" \
        "<init>(Landroid/content/Context;)V" "$SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME" \
        "SDHMS DVFS properties")" || return 1
    SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
        "$DVFS_PROPERTIES_SMALI" "replace" \
        "<init>(Landroid/content/Context;)V" \
        "$DVFS_PROPERTIES_LITERAL" \
        "$TARGET_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME"
fi

# SEC_PRODUCT_FEATURE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME
if [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]]; then
    SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_SYSTEM_CONFIG_SIOP_POLICY_FILENAME" "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"

    DECODE_APK "system" "system/framework/ssrm.jar"
    SSRM_JAR_ROOT="$APKTOOL_DIR/system/framework/ssrm.jar"
    SSRM_JAR_FEATURE_SMALI="smali/com/android/server/ssrm/Feature.smali"
    SSRM_JAR_FEATURE_SMALI="$(RESOLVE_SMALI_PATH \
        "$SSRM_JAR_ROOT" "$SSRM_JAR_FEATURE_SMALI" \
        "<clinit>()V" "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME")" || return 1
    SSRM_JAR_FEATURE_LITERAL="$(RESOLVE_POLICY_LITERAL \
        "$SSRM_JAR_ROOT/$SSRM_JAR_FEATURE_SMALI" "<clinit>()V" \
        "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" \
        "ssrm.jar Feature")" || return 1

    SMALI_PATCH "system" "system/framework/ssrm.jar" \
        "$SSRM_JAR_FEATURE_SMALI" "replace" \
        "<clinit>()V" \
        "$SSRM_JAR_FEATURE_LITERAL" \
        "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"

    DECODE_APK "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

    # The class is obfuscated and was renamed again in Android 17. Resolve it
    # from the source policy literal instead of tying the patch to a class name.
    SSRM_FEATURE_ROOT="$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"
    if [ ! -f "$SSRM_FEATURE_ROOT/$SSRM_FEATURE_SMALI" ]; then
        SSRM_FEATURE_MATCHES="$(grep -RFl --include='*.smali' \
            "$SSRM_JAR_FEATURE_LITERAL" "$SSRM_FEATURE_ROOT" || true)"
        if [ "$(printf '%s\n' "$SSRM_FEATURE_MATCHES" | sed '/^$/d' | wc -l)" -ne 1 ]; then
            _LOG "Unable to uniquely locate the SDHMS SSRM feature class"
        else
            SSRM_FEATURE_SMALI="${SSRM_FEATURE_MATCHES#"$SSRM_FEATURE_ROOT/"}"
            LOG "- Resolved SDHMS SSRM feature class: $SSRM_FEATURE_SMALI"
        fi
    fi

    if [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "ssrm_default" ]] && \
            [[ "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" == "ssrm_default" ]]; then
        LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default"
        EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default\""
        LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model"
        EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model\""
        LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default"
        EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default\""
        LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml"
        EVAL "cp -a \"$MODPATH/assets/siop_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml\""
        LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml"
        EVAL "cp -a \"$MODPATH/assets/ssrm_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml\""
    fi

    # com/sec/android/sdhms/util/Feature
    SSRM_FEATURE_LITERAL="$(RESOLVE_POLICY_LITERAL "$SSRM_FEATURE_ROOT/$SSRM_FEATURE_SMALI" \
        "<clinit>()V" "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" \
        "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" \
        "SDHMS SSRM feature")" || return 1
    SMALI_PATCH "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk" \
        "$SSRM_FEATURE_SMALI" "replace" \
        "<clinit>()V" \
        "$SSRM_FEATURE_LITERAL" \
        "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME"
fi

if [ -f "$SRC_DIR/target/$TARGET_CODENAME/dvfs/siop_model.xml" ]; then
    DECODE_APK "system" "system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"

    LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default"
    EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default\""
    LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model"
    EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_model\""
    LOG "- Deleting /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default"
    EVAL "rm \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default\""

    LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml"
    EVAL "cp -a \"$MODPATH/assets/siop_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/siop_default.xml\""
    LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME.xml"
    EVAL "cp -a \"$SRC_DIR/target/$TARGET_CODENAME/dvfs/siop_model.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME.xml\""
    LOG "- Adding /system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml"
    EVAL "cp -a \"$MODPATH/assets/ssrm_default.xml\" \"$APKTOOL_DIR/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk/assets/ssrm_default.xml\""
else
    if [[ "$SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" ]] && \
            [[ "$TARGET_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME" != "ssrm_default" ]]; then
        _LOG "File not found: $SRC_DIR/target/$TARGET_CODENAME/dvfs/siop_model.xml"
    fi
fi

unset -f _LOG
unset -f EXTRACT_METHOD RESOLVE_POLICY_LITERAL RESOLVE_SMALI_PATH
unset DVFS_FEATURE_SMALI DVFS_PROPERTIES_SMALI SSRM_FEATURE_SMALI \
    SSRM_FEATURE_ROOT SSRM_FEATURE_MATCHES SSRM_JAR_ROOT \
    SSRM_JAR_FEATURE_SMALI SSRM_JAR_FEATURE_LITERAL SDHMS_ROOT \
    DVFS_FEATURE_LITERAL DVFS_PROPERTIES_LITERAL SSRM_FEATURE_LITERAL
