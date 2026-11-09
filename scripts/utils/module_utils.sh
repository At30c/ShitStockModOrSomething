# Copyright (c) 2025 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# [
source "$SRC_DIR/scripts/utils/smali_utils.sh"
# ]

# ABORT <message>
# Stops the build process, additionally prints a log message if supplied.
ABORT()
{
    if [ "$1" ]; then
        LOGE "$1"
    fi
    return 1
}

# APPLY_PATCH <partition> <apk/jar> <patch>
# Applies a unified diff patch to the provided APK/JAR decoded directory.
APPLY_PATCH()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "FILE" "$2" || return 1
    _CHECK_NON_EMPTY_PARAM "PATCH" "$3" || return 1

    local PARTITION="$1"
    local FILE="$2"
    local PATCH="$3"

    if ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        return 1
    fi

    if [ ! -f "$PATCH" ]; then
        LOGE "File not found: ${PATCH//$SRC_DIR\//}"
        return 1
    fi

    while [[ "${FILE:0:1}" == "/" ]]; do
        FILE="${FILE:1}"
    done

    DECODE_APK "$PARTITION" "$FILE" || return 1

    LOG "- Applying \"$(grep "^Subject:" "$PATCH" | sed "s/.*PATCH] //")\" to /$PARTITION/$FILE"

    # A decoded APK/JAR cache may already contain this patch from a previous
    # build. Only treat it as applied when the complete patch can be cleanly
    # reversed; incompatible or partially applied patches must still fail.
    if LC_ALL=C git apply \
        --directory="$APKTOOL_DIR/$PARTITION/${FILE//system\//}" \
        --reverse --check --unsafe-paths "$PATCH" > /dev/null 2>&1; then
        LOG "  - Patch is already applied; skipping"
        return 0
    fi

    EVAL "LC_ALL=C git apply --directory=\"$APKTOOL_DIR/$PARTITION/${FILE//system\//}\" --verbose --unsafe-paths \"$PATCH\"" || return 1
}

# DECODE_APK <partition> <apk/jar>
# Same usage as `run_cmd apktool d <partition> <apk/jar>`.
DECODE_APK()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "FILE" "$2" || return 1

    if [ ! -d "$APKTOOL_DIR/$1/${2//system\/}" ]; then
        "$SRC_DIR/scripts/apktool.sh" d "$1" "$2"
        return $?
    fi

    return 0
}

# EXTRACT_EXT4_IMAGE <image> <output dir> <fs_config> <file_contexts>
# Extracts an ext4 image (e.g. an APEX payload) without mounting it, so no
# root is required. The tree is written to <output dir> without lost+found;
# the metadata files describe every inode of the image (lost+found included)
# in the format build_fs_image.sh consumes: fs_config paths are relative with
# the root as an empty path, file_contexts paths are absolute and escaped.
EXTRACT_EXT4_IMAGE()
{
    _CHECK_NON_EMPTY_PARAM "IMAGE" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "OUTPUT" "$2" || return 1
    _CHECK_NON_EMPTY_PARAM "FS_CONFIG" "$3" || return 1
    _CHECK_NON_EMPTY_PARAM "FILE_CONTEXTS" "$4" || return 1

    local IMAGE="$1"
    local OUTPUT="$2"
    local FS_CONFIG="$3"
    local FILE_CONTEXTS="$4"
    local CMD_FILE="$OUTPUT.debugfs"
    local METADATA="$OUTPUT.metadata"
    local PATHS

    if [ ! -f "$IMAGE" ]; then
        LOGE "File not found: ${IMAGE//$SRC_DIR\//}"
        return 1
    fi

    # debugfs only reads ext2/3/4; erofs payloads would need fsck.erofs.
    if ! dumpe2fs -h "$IMAGE" &> /dev/null; then
        LOGE "Not an ext4 image: ${IMAGE//$SRC_DIR\//}"
        return 1
    fi

    rm -rf "${OUTPUT:?}"
    mkdir -p "$OUTPUT"
    # rdump keeps modes and symlinks; restoring ownership needs root and
    # fails per file, which is harmless as ownership comes from fs_config.
    debugfs -R "rdump / \"$OUTPUT\"" "$IMAGE" &> /dev/null
    if [ -z "$(ls -A "$OUTPUT")" ]; then
        LOGE "Failed to extract ${IMAGE//$SRC_DIR\//}"
        return 1
    fi

    {
        echo 'stat "/"'
        find "$OUTPUT" -mindepth 1 | sed "s|^$OUTPUT/||" | LC_ALL=C sort | \
            sed 's|^\(.*\)$|stat "/\1"|'
    } > "$CMD_FILE"
    PATHS="$(wc -l < "$CMD_FILE")"

    debugfs -f "$CMD_FILE" "$IMAGE" 2> /dev/null | awk '
        function flush() {
            if (path != "")
                printf "%s\t%s\t%s\t%s\t%s\n", path, uid, gid, mode, label
        }
        /^debugfs: stat "/ {
            flush()
            path = $0
            sub(/^debugfs: stat "/, "", path)
            sub(/"$/, "", path)
            uid = gid = mode = label = ""
            next
        }
        / Mode: / {
            mode = $0
            sub(/.* Mode: +/, "", mode)
            sub(/ .*/, "", mode)
            sub(/^0+/, "", mode)
            if (mode == "") mode = "0"
        }
        /^User: / { uid = $2; gid = $4 }
        /^  security\.selinux / {
            label = $0
            sub(/^[^"]*"/, "", label)
            sub(/"$/, "", label)
            sub(/\\000$/, "", label)
        }
        END { flush() }
    ' > "$METADATA"
    rm -f "$CMD_FILE"

    if [ "$(wc -l < "$METADATA")" != "$PATHS" ] || \
            awk -F '\t' '$2 == "" || $3 == "" || $4 == "" || $5 == "" { bad = 1 } END { exit !bad }' "$METADATA"; then
        LOGE "Failed to read metadata from ${IMAGE//$SRC_DIR\//}"
        rm -f "$METADATA"
        return 1
    fi

    awk -F '\t' '{
        rel = substr($1, 2)
        printf "%s %s %s %s capabilities=0x0\n", rel, $2, $3, $4
    }' "$METADATA" | sort > "$FS_CONFIG"
    awk -F '\t' '{ printf "%s %s\n", $1, $5 }' "$METADATA" | \
        sed -e 's|\.|\\.|g' -e 's|+|\\+|g' -e 's|\[|\\[|g' \
            -e 's|\]|\\]|g' -e 's|\*|\\*|g' | sort > "$FILE_CONTEXTS"
    rm -f "$METADATA"

    rm -rf "$OUTPUT/lost+found"
    return 0
}

# GET_GALAXY_STORE_DOWNLOAD_URL "<package name/id>"
# Returns a URL to download the desired app from Samsung servers.
GET_GALAXY_STORE_DOWNLOAD_URL()
{
    _CHECK_NON_EMPTY_PARAM "PACKAGE" "$1" || return 1

    local PACKAGE="$1"
    local DEVICES
    local OS
    local ONEUI
    local PROTOCOL

    # Galaxy S25 Ultra EUR_OPENX
    # Galaxy S22 Ultra GBL_OPENX
    # Galaxy S25 Ultra KOR_SINGLEX
    DEVICES=("SM-S938B" "SM-S901E" "SM-S938N")

    OS="$(GET_PROP "system" "ro.build.version.sdk")"
    ONEUI="$(GET_PROP "system" "ro.build.version.oneui")"

    if [ ! "$OS" ]; then
        # Fallback to Android 16
        OS="36"
    fi
    if [ ! "$ONEUI" ]; then
        # Fallback to One UI 8.0
        ONEUI="80000"
    fi

    PROTOCOL+="<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\" ?>"
    PROTOCOL+="<SamsungProtocol networkType=\"0\" openApiVersion=\"$OS\" deviceModel=\"DEVICE\""
    PROTOCOL+=" mcc=\"262\" mnc=\"01\" csc=\"EUX\" version=\"7.7\""
    PROTOCOL+=" deviceFeature=\"locale=en_GB||abi32=armeabi-v7a:armeabi||abi64=arm64-v8a||oneUiVersion=$ONEUI\">"
    PROTOCOL+="<request id=\"2303\" numParam=\"2\">"
    PROTOCOL+="<param name=\"stduk\">0</param>"
    PROTOCOL+="<param name=\"productID\">PRODUCTID</param>"
    PROTOCOL+="</request>"
    PROTOCOL+="</SamsungProtocol>"

    local OUT
    local REQUEST
    for i in "${DEVICES[@]}"; do
        if [[ "$PACKAGE" =~ ^[+-]?[0-9]+$ ]]; then
            OUT="$PACKAGE"
        else
            OUT="$(curl -L -s "https://vas.samsungapps.com/stub/stubUpdateCheck.as?appId=$PACKAGE&versionCode=0&deviceId=$i&mcc=262&mnc=01&csc=EUX&sdkVer=$OS&oneUiVersion=$ONEUI&systemId=0")"
            OUT="$(grep -o -P "(?<=<productId>)[^<]+" <<< "$OUT")"
            if [ ! "$OUT" ]; then
                continue
            fi
        fi

        REQUEST="$PROTOCOL"
        REQUEST="${REQUEST//DEVICE/$i}"
        REQUEST="${REQUEST//PRODUCTID/$OUT}"

        OUT="$(curl -L -s "https://uk-odc.samsungapps.com/ods.as" -H "Content-Type: text/plain" -d "$REQUEST")"
        OUT="$(grep -o -P "(?<=<value name=\"downLoadURI\">)[^<]+" <<< "$OUT")"
        if [ "$OUT" ]; then
            echo "${OUT//amp;/}"
            return 0
        fi
    done

    LOGE "No download URI found for app \"$PACKAGE\""
    return 1
}

# GET_FLOATING_FEATURE_CONFIG "<file>" "<config>"
# Returns the supplied config value, file can be omitted.
GET_FLOATING_FEATURE_CONFIG()
{
    local FILE
    if [ "$2" ]; then
        FILE="$1"
        shift
    else
        FILE="$WORK_DIR/system/system/etc/floating_feature.xml"
    fi

    _CHECK_NON_EMPTY_PARAM "CONFIG" "$1" || return 1

    local CONFIG="$1"

    if [ ! -f "$FILE" ]; then
        LOGE "File not found: ${FILE//$WORK_DIR/}"
        return 1
    fi

    grep -o -P "(?<=<$CONFIG>)[^<]+" "$FILE" 2> /dev/null || true
}

# HEX_PATCH "<file>" "<old pattern>" "<new pattern>"
# Applies the supplied hex patch to the desired file.
HEX_PATCH()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "FROM" "$2" || return 1
    _CHECK_NON_EMPTY_PARAM "TO" "$3" || return 1

    local FILE="$1"
    local FROM="$2"
    local TO="$3"

    if [ ! -f "$FILE" ]; then
        LOGE "File not found: ${FILE//$WORK_DIR/}"
        return 1
    fi

    FROM="${FROM// /}"
    TO="${TO// /}"

    FROM="$(tr "[:upper:]" "[:lower:]" <<< "$FROM")"
    TO="$(tr "[:upper:]" "[:lower:]" <<< "$TO")"

    if ! xxd -p -c 0 "$FILE" | grep -q "$FROM"; then
        LOGE "No \"$FROM\" match in ${FILE//$WORK_DIR/}"
        return 1
    fi

    if [[ "$(echo -n "$FROM" | wc -c)" != "$(echo -n "$TO" | wc -c)" ]]; then
        LOGE "Byte strings length must be equal"
        return 1
    fi

    LOG "- Patching \"$FROM\" to \"$TO\" in ${FILE//$WORK_DIR/}"
    xxd -p -c 0 "$FILE" | sed "s/$FROM/$TO/" | xxd -r -p > "$FILE.tmp"
    mv "$FILE.tmp" "$FILE"

    return 0
}

# SET_FLOATING_FEATURE_CONFIG "<config>" "<value>"
# Sets the supplied config to the desired value.
# "-d" or "--delete" can be passed as value to delete the config.
SET_FLOATING_FEATURE_CONFIG()
{
    _CHECK_NON_EMPTY_PARAM "CONFIG" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "VALUE" "$2" || return 1

    local CONFIG="$1"
    local VALUE="$2"
    local FILE="$WORK_DIR/system/system/etc/floating_feature.xml"

    if [ ! -f "$FILE" ]; then
        LOGE "File not found: ${FILE//$WORK_DIR/}"
        return 1
    fi

    # Match the complete XML tag. A substring match confuses entries such as
    # CAMERA_SUPPORT_AI_HIGH_RESOLUTION with
    # CAMERA_SUPPORT_AI_HIGH_RESOLUTION_DRAFT_DOWNSCALE.
    if grep -q "<${CONFIG}>" "$FILE"; then
        if [[ "$VALUE" == "-d" ]] || [[ "$VALUE" == "--delete" ]]; then
            LOG "- Deleting \"$CONFIG\" config in /system/system/etc/floating_feature.xml"
            sed -i "/<$CONFIG>/d" "$FILE"
        else
            LOG "- Replacing \"$CONFIG\" config with \"$VALUE\" in /system/system/etc/floating_feature.xml"
            # Delete every existing copy first. The old line-number based sed
            # expression became invalid as soon as a dirty/repeated build had
            # duplicated an entry, multiplying it until floating_feature.xml
            # was almost entirely replaced by a single feature.
            sed -i "/<${CONFIG}>/d" "$FILE"
            sed -i "/<\/SecFloatingFeatureSet>/i\ \ \ \ <${CONFIG}>${VALUE}</${CONFIG}>" "$FILE"
        fi
    elif [[ "$VALUE" != "-d" ]] && [[ "$VALUE" != "--delete" ]]; then
        LOG "- Adding \"$CONFIG\" config with \"$VALUE\" in /system/system/etc/floating_feature.xml"
        sed -i "/<\/SecFloatingFeatureSet>/d" "$FILE"
        if ! grep -q "Added by scripts" "$FILE"; then
            echo "    <!-- Added by scripts/utils/module_utils.sh -->" >> "$FILE"
        fi
        echo "    <${CONFIG}>${VALUE}</${CONFIG}>" >> "$FILE"
        echo "</SecFloatingFeatureSet>" >> "$FILE"
    fi

    return 0
}

# SET_PROP_IF_DIFF "<partition>" "<prop>" "<value>"
# Calls SET_PROP if the current prop value does not match, partition name CANNOT be omitted.
SET_PROP_IF_DIFF()
{
    _CHECK_NON_EMPTY_PARAM "PARTITION" "$1" || return 1
    _CHECK_NON_EMPTY_PARAM "PROP" "$2" || return 1
    _CHECK_NON_EMPTY_PARAM "EXPECTED" "$3" || return 1

    local PARTITION="$1"
    local PROP="$2"
    local EXPECTED="$3"

    if ! IS_VALID_PARTITION_NAME "$PARTITION"; then
        LOGE "\"$PARTITION\" is not a valid partition name"
        return 1
    fi

    local CURRENT
    CURRENT="$(GET_PROP "$PARTITION" "$PROP")"
    [ -z "$CURRENT" ] || [ "$CURRENT" = "$EXPECTED" ] || SET_PROP "$PARTITION" "$PROP" "$EXPECTED"
}
