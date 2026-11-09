#!/usr/bin/env bash
# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# [
source "$SRC_DIR/scripts/utils/install_utils.sh" || exit 1

TMP_DIR="$OUT_DIR/target/$TARGET_CODENAME/zip"

PRIVATE_KEY_PATH="$SRC_DIR/security/"
PUBLIC_KEY_PATH="$SRC_DIR/security/"
if $ROM_IS_OFFICIAL; then
    PRIVATE_KEY_PATH+="unica_ota"
    PUBLIC_KEY_PATH+="unica_ota"
else
    PRIVATE_KEY_PATH+="aosp_testkey"
    PUBLIC_KEY_PATH+="aosp_testkey"
fi
PRIVATE_KEY_PATH+=".pk8"
PUBLIC_KEY_PATH+=".x509.pem"

# Host-side verification results (target care ranges and hashes) used by the
# updater-script; never packaged.
VERIFY_DIR="$TMP_DIR/.verify"
# Extra free space kept on the build disk; a full disk once truncated files
# silently.
SPACE_MARGIN=$((1024 * 1024 * 1024))

trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

CHECK_HOST_TOOLS()
{
    local TOOLS="7z brotli bspatch img2sdat python3 simg2img unzip"
    if ! $DEBUG || $ROM_IS_OFFICIAL; then
        TOOLS+=" signapk"
    fi

    for t in $TOOLS; do
        if ! command -v "$t" &> /dev/null; then
            LOGE "Required tool not found: $t"
            exit 1
        fi
    done
}

# CHECK_FREE_SPACE <bytes> <purpose>
CHECK_FREE_SPACE()
{
    local NEEDED="$1"
    local PURPOSE="$2"

    local AVAILABLE
    AVAILABLE="$(df --output=avail -B1 "$TMP_DIR" | tail -n 1 | tr -d " ")"

    if [ "$AVAILABLE" -lt "$((NEEDED + SPACE_MARGIN))" ]; then
        LOGE "Not enough free space for $PURPOSE: $((NEEDED / 1048576)) MiB + $((SPACE_MARGIN / 1048576)) MiB margin needed, $((AVAILABLE / 1048576)) MiB available"
        exit 1
    fi
}

# VERIFY_BLOCK_UPDATE <partition> [source image]
# Replays the generated transfer list on the source image and checks the result
# against the target image, before the payload is compressed.
VERIFY_BLOCK_UPDATE()
{
    local PARTITION="$1"
    local SOURCE_IMAGE="$2"
    local TARGET_IMAGE="$TMP_DIR/target/$PARTITION.img"

    # The verifier only stores the blocks the update writes, at most the
    # target size.
    CHECK_FREE_SPACE "$(GET_IMAGE_SIZE "$TARGET_IMAGE")" "verifying $PARTITION"

    local CMD
    CMD="python3 -I \"$SRC_DIR/scripts/internal/verify_block_ota.py\""
    CMD+=" --lib-dir \"$(dirname "$(command -v img2sdat)")\""
    CMD+=" --work-dir \"$VERIFY_DIR\""
    CMD+=" --target \"$TARGET_IMAGE\""
    [ "$SOURCE_IMAGE" ] && CMD+=" --source \"$SOURCE_IMAGE\""
    CMD+=" --prefix \"$TMP_DIR/$PARTITION\""

    LOG "- Verifying $PARTITION.img block update"
    EVAL "$CMD" || exit 1

    local f
    for f in tgt_ranges tgt_sha1 ext_ranges ext_sha1; do
        if [ -f "$TMP_DIR/$PARTITION.$f" ]; then
            mv -f "$TMP_DIR/$PARTITION.$f" "$VERIFY_DIR/$PARTITION.$f"
        fi
    done
}

# CHECK_RAW_IMAGE <file>
# Raw images are flashed with package_extract_file and read back with
# range_sha1, so they must fit their partition and be block aligned.
CHECK_RAW_IMAGE()
{
    local FILE="$1"

    local NAME
    local SIZE
    local PARTITION_SIZE
    NAME="$(basename "$FILE" | sed "s/\.img$//; s/\.bin$//")"
    SIZE="$(stat -c "%s" "$FILE")"
    PARTITION_SIZE="TARGET_$(tr "[:lower:]" "[:upper:]" <<< "$NAME")_PARTITION_SIZE"
    PARTITION_SIZE="${!PARTITION_SIZE//none/}"

    if [ "$SIZE" -eq 0 ]; then
        LOGE "$(basename "$FILE") is empty"
        exit 1
    fi
    if [ "$PARTITION_SIZE" ] && [ "$SIZE" -gt "$PARTITION_SIZE" ]; then
        LOGE "$(basename "$FILE") ($SIZE) is bigger than its partition ($PARTITION_SIZE)"
        exit 1
    fi
}

# PRINT_RAW_IMAGE_INSTALL <file> <mountpoint> <label>
PRINT_RAW_IMAGE_INSTALL()
{
    local IMG="$1"
    local MOUNTPOINT="$2"
    local LABEL="$3"

    local SIZE
    SIZE="$(stat -c "%s" "$TMP_DIR/$IMG")"

    echo -n 'ui_print("'
    echo -n "$LABEL"
    echo    '");'
    echo -n "package_extract_file(\"$IMG\", "
    GET_DEVICE_FROM_MOUNTPOINT "$MOUNTPOINT"
    echo    ") ||"
    echo    "  abort(\"E2001: Failed to flash $IMG.\");"
    if [ "$((SIZE % 4096))" -eq 0 ]; then
        echo -n "range_sha1("
        GET_DEVICE_FROM_MOUNTPOINT "$MOUNTPOINT"
        echo -n ", \"2,0,$((SIZE / 4096))\") == \""
        echo -n "$(sha1sum "$TMP_DIR/$IMG" | cut -d " " -f 1)"
        echo    '" ||'
        echo    "  abort(\"E2002: ${MOUNTPOINT#/} partition has unexpected contents after flashing $IMG.\");"
    fi
}

# PRINT_PARTITION_UPDATE <partition>
PRINT_PARTITION_UPDATE()
{
    local p="$1"

    local CODE=2
    [[ "$p" == "system" ]] && CODE=1

    $TARGET_USE_DYNAMIC_PARTITIONS && echo -e "\n# Patch partition $p\n"
    echo -n 'ui_print("Patching '
    echo -n "$p"
    if [ -s "$TMP_DIR/$p.patch.dat" ]; then
        echo -n " image after verification."
    else
        echo -n " image unconditionally..."
    fi
    echo    '");'
    if [[ "$p" == "system" ]]; then
        echo -n 'show_progress(0.'
        echo -n "$(bc -l <<< "9 - $PARTITION_COUNT")"
        echo    '00000, 0);'
    else
        echo    'show_progress(0.100000, 0);'
    fi
    echo -n "block_image_update("
    GET_DEVICE_FROM_MOUNTPOINT "/$p"
    echo -n ', package_extract_file("'
    echo -n "$p.transfer.list"
    echo -n '"), "'
    echo -n "$p.new.dat"
    [ -f "$TMP_DIR/$p.new.dat.br" ] && echo -n ".br"
    echo -n '", "'
    echo -n "$p.patch.dat"
    echo    '") ||'
    echo    "  abort(\"E${CODE}001: Failed to update $p image.\");"

    # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/common.py#3557
    echo -n "if range_sha1("
    GET_DEVICE_FROM_MOUNTPOINT "/$p"
    echo -n ", \"$(cat "$VERIFY_DIR/$p.tgt_ranges")\") == \""
    echo -n "$(cat "$VERIFY_DIR/$p.tgt_sha1")"
    echo    '" then'
    echo    "ui_print(\"Verified the updated $p image.\");"
    echo    "else"
    echo    "  abort(\"E${CODE}002: $p partition has unexpected contents after OTA update\");"
    echo    "endif;"
    if [ -f "$VERIFY_DIR/$p.ext_ranges" ]; then
        echo -n "if range_sha1("
        GET_DEVICE_FROM_MOUNTPOINT "/$p"
        echo -n ", \"$(cat "$VERIFY_DIR/$p.ext_ranges")\") != \""
        echo -n "$(cat "$VERIFY_DIR/$p.ext_sha1")"
        echo    '" then'
        echo    "  abort(\"E${CODE}003: $p partition has unexpected non-zero contents after OTA update\");"
        echo    "endif;"
    fi
}

# Lists the package files the updater-script extracts.
LIST_PACKAGE_REFERENCES()
{
    local SCRIPT_FILE="$TMP_DIR/META-INF/com/google/android/updater-script"

    {
        grep -oE 'package_extract_file\("[^"]+"' "$SCRIPT_FILE" | cut -d '"' -f 2
        grep -oE '"[^"/ ]+\.(new\.dat(\.br)?|patch\.dat)"' "$SCRIPT_FILE" | tr -d '"'
    } | sort -u
}

CHECK_PACKAGE_REFERENCES()
{
    local LISTING="$1"

    local MISSING=false
    while IFS= read -r f; do
        if [ "$LISTING" ]; then
            grep -qxF "$f" <<< "$LISTING" && continue
        else
            [ -f "$TMP_DIR/$f" ] && continue
        fi
        LOGE "updater-script references a file missing from the package: $f"
        MISSING=true
    done < <(LIST_PACKAGE_REFERENCES)

    ! $MISSING
}

CALCULATE_MIN_CACHE_SIZE()
{
    local PRUNE_CACHE_FILES="$1"

    local MAX="0"
    local VAL="0"

    while IFS= read -r f; do
        VAL="$(cat "$f")"
        if [ "$VAL" -gt "$MAX" ]; then
            MAX="$VAL"
        fi
    done < <(find "$TMP_DIR" -maxdepth 1 -type f -name "*.max_stashed_size")

    if $PRUNE_CACHE_FILES || [[ "$MAX" == "0" ]]; then
        find "$TMP_DIR" -maxdepth 1 -type f -name "*.max_stashed_size" -delete &> /dev/null
    fi

    echo -n "$MAX"
}

# https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/common.py#4067
GENERATE_OP_LIST()
{
    local OP_LIST_FILE="$TMP_DIR/dynamic_partitions_op_list"

    local SOURCE_SUPER_GROUP_NAME
    local SOURCE_SUPER_GROUP_SIZE
    local TARGET_SUPER_GROUP_NAME
    local TARGET_SUPER_GROUP_SIZE

    SOURCE_SUPER_GROUP_NAME="$(grep "^super_partition_group" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    SOURCE_SUPER_GROUP_SIZE="$(grep "^super_${SOURCE_SUPER_GROUP_NAME}_group_size" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_SUPER_GROUP_NAME="$(grep "^super_partition_group" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_SUPER_GROUP_SIZE="$(grep "^super_${TARGET_SUPER_GROUP_NAME}_group_size" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"

    local SOURCE_PARTITION_SIZE=0
    local TARGET_PARTITION_SIZE=0
    local OCCUPIED_SPACE=0

    {
        for p in $PARTITIONS_LIST; do
            if [ -f "$TMP_DIR/source/$p.img" ] && [ ! -f "$TMP_DIR/target/$p.img" ]; then
                echo "remove $p"
            fi
        done
        for p in $PARTITIONS_LIST; do
            if [ -f "$TMP_DIR/source/$p.img" ] && [ -f "$TMP_DIR/target/$p.img" ] && \
                [[ "$SOURCE_SUPER_GROUP_NAME" != "$TARGET_SUPER_GROUP_NAME" ]]; then
                echo "# Move partition $p from $SOURCE_SUPER_GROUP_NAME to default"
                echo "move $p default"
            fi
        done
        for p in $PARTITIONS_LIST; do
            if [ -f "$TMP_DIR/source/$p.img" ] && [ -f "$TMP_DIR/target/$p.img" ]; then
                SOURCE_PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/source/$p.img")"
                TARGET_PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/target/$p.img")"
                if [ "$SOURCE_PARTITION_SIZE" -gt "$TARGET_PARTITION_SIZE" ]; then
                    echo "# Shrink partition $p from $SOURCE_PARTITION_SIZE to $TARGET_PARTITION_SIZE"
                    echo "resize $p $TARGET_PARTITION_SIZE"
                    OCCUPIED_SPACE=$((OCCUPIED_SPACE + TARGET_PARTITION_SIZE))
                fi
            fi
        done
        if [[ "$SOURCE_SUPER_GROUP_NAME" != "$TARGET_SUPER_GROUP_NAME" ]]; then
            echo "remove_group $SOURCE_SUPER_GROUP_NAME"
        fi
        if [[ "$SOURCE_SUPER_GROUP_NAME" == "$TARGET_SUPER_GROUP_NAME" ]] && \
            [ "$SOURCE_SUPER_GROUP_SIZE" -gt "$TARGET_SUPER_GROUP_SIZE" ]; then
            echo "# Shrink group $TARGET_SUPER_GROUP_NAME from $SOURCE_SUPER_GROUP_SIZE to $TARGET_SUPER_GROUP_SIZE"
            echo "resize_group $TARGET_SUPER_GROUP_NAME $TARGET_SUPER_GROUP_SIZE"
        fi
        if [[ "$SOURCE_SUPER_GROUP_NAME" != "$TARGET_SUPER_GROUP_NAME" ]]; then
            echo "# Add group $TARGET_SUPER_GROUP_NAME with maximum size $TARGET_SUPER_GROUP_SIZE"
            echo "add_group $TARGET_SUPER_GROUP_NAME $TARGET_SUPER_GROUP_SIZE"
        fi
        if [[ "$SOURCE_SUPER_GROUP_NAME" == "$TARGET_SUPER_GROUP_NAME" ]] && \
            [ "$SOURCE_SUPER_GROUP_SIZE" -lt "$TARGET_SUPER_GROUP_SIZE" ]; then
            echo "# Grow group $TARGET_SUPER_GROUP_NAME from $SOURCE_SUPER_GROUP_SIZE to $TARGET_SUPER_GROUP_SIZE"
            echo "resize_group $TARGET_SUPER_GROUP_NAME $TARGET_SUPER_GROUP_SIZE"
        fi
        for p in $PARTITIONS_LIST; do
            if [ ! -f "$TMP_DIR/source/$p.img" ] && [ -f "$TMP_DIR/target/$p.img" ]; then
                echo "# Add partition $p to group $TARGET_SUPER_GROUP_NAME"
                echo "add $p $TARGET_SUPER_GROUP_NAME"
            fi
        done
        for p in $PARTITIONS_LIST; do
            if [ ! -f "$TMP_DIR/target/$p.img" ]; then
                continue
            fi
            if [ -f "$TMP_DIR/source/$p.img" ]; then
                SOURCE_PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/source/$p.img")"
            else
                SOURCE_PARTITION_SIZE=0
            fi
            TARGET_PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/target/$p.img")"
            if [ "$SOURCE_PARTITION_SIZE" -lt "$TARGET_PARTITION_SIZE" ]; then
                echo "# Grow partition $p from $SOURCE_PARTITION_SIZE to $TARGET_PARTITION_SIZE"
                echo "resize $p $TARGET_PARTITION_SIZE"
                OCCUPIED_SPACE=$((OCCUPIED_SPACE + TARGET_PARTITION_SIZE))
            fi
        done
        for p in $PARTITIONS_LIST; do
            if [ -f "$TMP_DIR/source/$p.img" ] && [ -f "$TMP_DIR/target/$p.img" ] && \
                [[ "$SOURCE_SUPER_GROUP_NAME" != "$TARGET_SUPER_GROUP_NAME" ]]; then
                echo "# Move partition $p from default to $TARGET_SUPER_GROUP_NAME"
                echo "move $p $TARGET_SUPER_GROUP_NAME"
            fi
        done
    } > "$OP_LIST_FILE"

    for p in $PARTITIONS_LIST; do
        if [ -f "$TMP_DIR/source/$p.img" ] && [ -f "$TMP_DIR/target/$p.img" ]; then
            SOURCE_PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/source/$p.img")"
            TARGET_PARTITION_SIZE="$(GET_IMAGE_SIZE "$TMP_DIR/target/$p.img")"
            if [[ "$SOURCE_PARTITION_SIZE" == "$TARGET_PARTITION_SIZE" ]]; then
                OCCUPIED_SPACE=$((OCCUPIED_SPACE + TARGET_PARTITION_SIZE))
            fi
        fi
    done

    if [ "$OCCUPIED_SPACE" -gt "$TARGET_SUPER_GROUP_SIZE" ]; then
        LOGE "OS size ($OCCUPIED_SPACE) is bigger than the target group size ($TARGET_SUPER_GROUP_SIZE)"
        exit 1
    fi
}

GENERATE_OTA_METADATA()
{
    local PROTO_FILE="$SRC_DIR/external/android-tools/vendor/build/tools/releasetools/ota_metadata.proto"

    local DEVICE
    local RELEASE
    local SOURCE_INCREMENTAL
    local TARGET_INCREMENTAL
    local TIMESTAMP
    local SECURITY_PATCH_LEVEL
    local SOURCE_FINGERPRINT
    local TARGET_FINGERPRINT

    DEVICE="$(grep "^device" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    RELEASE="$(grep "^os_version" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    SOURCE_INCREMENTAL="$(grep "^build_incremental" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_INCREMENTAL="$(grep "^build_incremental" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TIMESTAMP="$(grep "^build_date" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    SECURITY_PATCH_LEVEL="$(grep "^security_patch" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    SOURCE_FINGERPRINT="$(grep "^source_fingerprint" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_FINGERPRINT="$(grep "^source_fingerprint" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"

    mkdir -p "$TMP_DIR/META-INF/com/android"

    # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/ota_utils.py#258
    if [ -f "$PROTO_FILE" ]; then
        local MESSAGE

        MESSAGE+="type: BLOCK"
        MESSAGE+=", precondition: {device: \\\"$DEVICE\\\""
        MESSAGE+=", build: \\\"$SOURCE_FINGERPRINT\\\""
        MESSAGE+=", build_incremental: \\\"$SOURCE_INCREMENTAL\\\"}"
        MESSAGE+=", postcondition: {device: \\\"$DEVICE\\\""
        MESSAGE+=", build: \\\"$TARGET_FINGERPRINT\\\""
        MESSAGE+=", build_incremental: \\\"$TARGET_INCREMENTAL\\\""
        MESSAGE+=", timestamp: $TIMESTAMP"
        MESSAGE+=", sdk_level: \\\"$RELEASE\\\""
        MESSAGE+=", security_patch_level: \\\"$SECURITY_PATCH_LEVEL\\\"}"
        MESSAGE+=", required_cache: $(CALCULATE_MIN_CACHE_SIZE false)"

        EVAL "protoc --encode=build.tools.releasetools.OtaMetadata --proto_path=\"$(dirname "$PROTO_FILE")\" \"$PROTO_FILE\" <<< \"$MESSAGE\" > \"$TMP_DIR/META-INF/com/android/metadata.pb\"" || exit 1
    fi

    # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/ota_utils.py#313
    {
        echo "ota-required-cache=$(CALCULATE_MIN_CACHE_SIZE true)"
        echo "ota-type=BLOCK"
        echo "post-build=$TARGET_FINGERPRINT"
        echo "post-build-incremental=$TARGET_INCREMENTAL"
        echo "post-sdk-level=$RELEASE"
        echo "post-security-patch-level=$SECURITY_PATCH_LEVEL"
        echo "post-timestamp=$TIMESTAMP"
        echo "pre-build=$SOURCE_FINGERPRINT"
        echo "pre-build-incremental=$SOURCE_INCREMENTAL"
        echo "pre-device=$DEVICE"
    } > "$TMP_DIR/META-INF/com/android/metadata"
}

GENERATE_UPDATER_SCRIPT()
{
    local SCRIPT_FILE="$TMP_DIR/META-INF/com/google/android/updater-script"

    local PARTITION_COUNT=0

    [ -f "$TMP_DIR/vendor.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/product.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/system_ext.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/odm.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/vendor_dlkm.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/odm_dlkm.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))
    [ -f "$TMP_DIR/system_dlkm.transfer.list" ] && PARTITION_COUNT=$((PARTITION_COUNT + 1))

    {
        PRINT_ASSERTIONS "$TARGET_BUILD_INFO" || exit 1

        PRINT_HEADER "$TARGET_BUILD_INFO" || exit 1
        PRINT_FOTA_STATUS "FAIL" || exit 1

        # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/non_ab_ota.py#397
        echo    'ui_print("Verify partitions...");'
        # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/common.py#3492
        for p in $PARTITIONS_LIST; do
            if [ ! -f "$TMP_DIR/$p.transfer.list" ]; then
                continue
            fi
            if [ ! -f "$TMP_DIR/$p.touched_src_sha1" ]; then
                echo -n 'ui_print("Image '
                echo -n "$p"
                echo    ' will be patched unconditionally.");'
            else
                echo -n "if (range_sha1("
                GET_DEVICE_FROM_MOUNTPOINT "/$p"
                echo -n ', "'
                cat "$TMP_DIR/$p.touched_src_ranges"
                echo -n '") == "'
                cat "$TMP_DIR/$p.touched_src_sha1" && rm -f "$TMP_DIR/$p.touched_src_sha1"
                echo -n '" || block_image_verify('
                GET_DEVICE_FROM_MOUNTPOINT "/$p"
                echo -n ', package_extract_file("'
                echo -n "$p.transfer.list"
                echo -n '"), "'
                echo -n "$p.new.dat"
                echo -n '", "'
                echo -n "$p.patch.dat"
                echo    '")) then'
                echo -n 'ui_print("Verified '
                echo -n "$p image..."
                echo    '");'
                echo    'else'
                echo -n "ifelse (block_image_recover("
                GET_DEVICE_FROM_MOUNTPOINT "/$p"
                echo -n ', "'
                cat "$TMP_DIR/$p.touched_src_ranges" && rm -f "$TMP_DIR/$p.touched_src_ranges"
                echo -n '") && block_image_verify('
                GET_DEVICE_FROM_MOUNTPOINT "/$p"
                echo -n ', package_extract_file("'
                echo -n "$p.transfer.list"
                echo -n '"), "'
                echo -n "$p.new.dat"
                echo -n '", "'
                echo -n "$p.patch.dat"
                echo -n '"), ui_print("'
                echo -n "$p recovered successfully."
                echo -n '"), abort("'
                [[ "$p" == "system" ]] && echo -n "E1004" || echo -n "E2004"
                echo -n ": $p partition fails to recover"
                echo    '"));'
                echo    "endif;"
            fi
        done

        if [ "$(CALCULATE_MIN_CACHE_SIZE false)" -gt "0" ]; then
            # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/edify_generator.py#212
            echo -n "apply_patch_space("
            CALCULATE_MIN_CACHE_SIZE false
            echo -n ") || abort("
            echo    '"E3006: Not enough free space on /cache to apply patches.");'
        fi

        # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/non_ab_ota.py#453
        echo -e "\n# ---- start making changes here ----\n"

        if $TARGET_USE_DYNAMIC_PARTITIONS; then
            # https://android.googlesource.com/platform/build/+/refs/tags/android-16.0.0_r4/tools/releasetools/common.py#4032
            echo -e "\n# --- Start patching dynamic partitions ---\n"
            for p in $PARTITIONS_LIST; do
                if [ ! -f "$TMP_DIR/$p.transfer.list" ]; then
                    continue
                fi
                if grep -q "Shrink partition $p " "$TMP_DIR/dynamic_partitions_op_list"; then
                    PRINT_PARTITION_UPDATE "$p"
                fi
            done
            if [ -f "$SRC_DIR/target/$TARGET_CODENAME/installer/install-start.edify" ]; then
                cat "$SRC_DIR/target/$TARGET_CODENAME/installer/install-start.edify"
            fi
            echo -e "\n# Update dynamic partition metadata\n"
            echo -n 'assert(update_dynamic_partitions(package_extract_file("dynamic_partitions_op_list")'
            if [ -f "$TMP_DIR/unsparse_super_empty.img" ]; then
                # https://github.com/LineageOS/android_build/commit/98549f6893c3a93057e2d4cdd1015a93e9473b16
                # https://github.com/LineageOS/android_bootable_deprecated-ota/commit/e97be4333bd3824b8561c9637e9e6de28bc29da0
                echo -n ', package_extract_file("unsparse_super_empty.img")'
            fi
            echo    '));'
        fi
        for p in $PARTITIONS_LIST; do
            if [ ! -f "$TMP_DIR/$p.transfer.list" ]; then
                continue
            fi
            if ! $TARGET_USE_DYNAMIC_PARTITIONS || ! grep -q "Shrink partition $p " "$TMP_DIR/dynamic_partitions_op_list"; then
                PRINT_PARTITION_UPDATE "$p"
            fi
        done
        $TARGET_USE_DYNAMIC_PARTITIONS && echo -e "\n# --- End patching dynamic partitions ---\n"

        for b in $KERNEL_BINS; do
            if [ -f "$TMP_DIR/$b.img" ]; then
                PRINT_RAW_IMAGE_INSTALL "$b.img" "/$b" "Full Patching $b.img img..."
            fi
        done
        if [ -f "$TMP_DIR/boot.img" ]; then
            PRINT_RAW_IMAGE_INSTALL "boot.img" "/boot" "Installing boot image..."
        fi

        if [ -f "$SRC_DIR/target/$TARGET_CODENAME/installer/install-end.edify" ]; then
            cat "$SRC_DIR/target/$TARGET_CODENAME/installer/install-end.edify"
        fi

        PRINT_FOTA_STATUS "DONE" || exit 1
        echo    'set_progress(1.000000);'

        PRINT_SEPARATOR
        echo    'ui_print(" ");'
    } > "$SCRIPT_FILE"
}

VERIFY_SOURCE_COMPATIBILITY()
{
    local SOURCE_DEVICE
    local SOURCE_SPL
    local SOURCE_TIMESTAMP
    local TARGET_DEVICE
    local TARGET_SPL
    local TARGET_TIMESTAMP

    SOURCE_DEVICE="$(grep "^device" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    SOURCE_SPL="$(grep "^security_patch" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    SOURCE_TIMESTAMP="$(grep "^timestamp" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_DEVICE="$(grep "^device" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_SPL="$(grep "^security_patch" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
    TARGET_TIMESTAMP="$(grep "^timestamp" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"

    if [[ "$SOURCE_DEVICE" != "$TARGET_DEVICE" ]]; then
        LOGE "Source device ($SOURCE_DEVICE) does not match target device ($TARGET_DEVICE)"
        exit 1
    fi

    # The package is built for one partition layout and one set of models.
    local KEY
    for KEY in model use_dynamic_partitions super_partition_size; do
        if [[ "$(grep "^$KEY=" <<< "$SOURCE_BUILD_INFO")" != "$(grep "^$KEY=" <<< "$TARGET_BUILD_INFO")" ]]; then
            LOGE "Source and target differ in \"$KEY\"; build a full ZIP instead"
            exit 1
        fi
    done

    if ! [[ "$SOURCE_TIMESTAMP" =~ ^[0-9]+$ && "$TARGET_TIMESTAMP" =~ ^[0-9]+$ ]]; then
        LOGE "Source or target build_info.txt has no valid timestamp"
        exit 1
    elif [ "$SOURCE_TIMESTAMP" -ge "$TARGET_TIMESTAMP" ]; then
        LOGE "Target build ($TARGET_TIMESTAMP) is not newer than the source build ($SOURCE_TIMESTAMP)"
        exit 1
    fi

    if [ "$(date --date "$SOURCE_SPL" "+%s")" -gt "$(date --date "$TARGET_SPL" "+%s")" ]; then
        LOGE "Target security patch level ($TARGET_SPL) is older than source SPL ($SOURCE_SPL)"
        exit 1
    fi
}
# ]

if [ "$#" != "3" ]; then
    echo "Usage: build_incremental_ota_zip <source target-files> <target target-files> <output>" >&2
    exit 1
fi

SOURCE_ZIP="$1"
TARGET_ZIP="$2"
OUTPUT_FILE="$3"

CHECK_HOST_TOOLS

# Both inputs are fully verified before anything is staged or built.
LOG "- Checking source and target files"
VALIDATE_TARGET_FILES "$SOURCE_ZIP" "source" || exit 1
VALIDATE_TARGET_FILES "$TARGET_ZIP" "target" || exit 1
if [ "$(realpath "$SOURCE_ZIP")" == "$(realpath "$TARGET_ZIP")" ] || \
        { [ -f "$SOURCE_ZIP" ] && [ -f "$TARGET_ZIP" ] && cmp -s "$SOURCE_ZIP" "$TARGET_ZIP"; }; then
    LOGE "Source and target are the same file"
    exit 1
fi

# Checked before staging anything: a refused pair used to cost the whole
# zip test and extraction first.
SOURCE_BUILD_INFO="$(READ_TARGET_FILES_BUILD_INFO "$SOURCE_ZIP")" || exit 1
TARGET_BUILD_INFO="$(READ_TARGET_FILES_BUILD_INFO "$TARGET_ZIP")" || exit 1
VERIFY_SOURCE_COMPATIBILITY

[ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/META-INF/com/google/android" "$VERIFY_DIR"
cp -a "$SRC_DIR/prebuilts/bootable/deprecated-ota/updater" "$TMP_DIR/META-INF/com/google/android/update-binary"

# Both trees plus the generated payload, which is at most the target size.
# Directory inputs are hard linked and take no space of their own.
TARGET_FILES_SIZE="$(GET_TARGET_FILES_SIZE "$TARGET_ZIP")"
[ -d "$TARGET_ZIP" ] && TARGET_FILES_SIZE="$(du -sb "$TARGET_ZIP" | cut -f 1)"
NEEDED_SPACE=$(($(GET_TARGET_FILES_SIZE "$SOURCE_ZIP") + $(GET_TARGET_FILES_SIZE "$TARGET_ZIP") + TARGET_FILES_SIZE))
CHECK_FREE_SPACE "$NEEDED_SPACE" "staging the source and target files"

LOG "- Staging source files"
STAGE_TARGET_FILES "$SOURCE_ZIP" "$TMP_DIR/source" || exit 1

LOG "- Staging target files"
STAGE_TARGET_FILES "$TARGET_ZIP" "$TMP_DIR/target" || exit 1

for p in $PARTITIONS_LIST; do
    for d in source target; do
        PREPARE_STAGED_IMAGE "$TMP_DIR/$d" "$p" "${TARGET_FILES_FORMAT["$d:$p"]}" || exit 1
    done
done

TARGET_CODENAME="$(grep "^device" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
if [ ! -d "$SRC_DIR/target/$TARGET_CODENAME" ]; then
    LOGE "Folder not found: target/$TARGET_CODENAME"
    exit 1
fi

TARGET_USE_DYNAMIC_PARTITIONS="$(grep "^use_dynamic_partitions" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
if [[ "$TARGET_USE_DYNAMIC_PARTITIONS" != "true" && "$TARGET_USE_DYNAMIC_PARTITIONS" != "false" ]]; then
    LOGE "Target build_info.txt has no valid use_dynamic_partitions value"
    exit 1
fi


if $TARGET_USE_DYNAMIC_PARTITIONS; then
    LOG "- Generating dynamic_partitions_op_list"
    GENERATE_OP_LIST
fi

for p in $PARTITIONS_LIST; do
    if [ ! -f "$TMP_DIR/target/$p.img" ]; then
        continue
    fi

    if [ -f "$TMP_DIR/source/$p.img" ]; then
        if ! cmp -s "$TMP_DIR/source/$p.img" "$TMP_DIR/target/$p.img"; then
            _CHECK_NON_EMPTY_PARAM "TARGET_CACHE_PARTITION_SIZE" "${TARGET_CACHE_PARTITION_SIZE//none/}" || exit 1
            LOG "- Generating $p.img block diff"
            # blockimgdiff writes each bsdiff/imgdiff source, target and patch
            # through tempfile. /tmp is a small tmpfs on the build host, and a
            # full one makes bsdiff fail with "Writing extra_data", so keep
            # these files on the build disk.
            mkdir -p "$TMP_DIR/blockdiff-tmp"
            if [ -f "$TMP_DIR/source/$p.map" ] && [ -f "$TMP_DIR/target/$p.map" ]; then
                SRC_MAP="$TMP_DIR/source/$p.map"
                TGT_MAP="$TMP_DIR/target/$p.map"
            else
                # No per-file map on one side (an image rebuilt from new.dat,
                # or an .img shipped without its .map). blockimgdiff only
                # pairs ranges with the same name, so both sides must be raw
                # images, split as __ZERO/__NONZERO and diffed in fixed
                # chunks. Correct, but the package is much larger than with
                # file maps.
                LOGW "$p has no block map on both sides; using a map-less diff (larger package)"
                for d in source target; do
                    if [ "$(od -An -tx1 -N4 "$TMP_DIR/$d/$p.img" | tr -d " \n")" == "3aff26ed" ]; then
                        # New file, then rename: never write through a hard link.
                        EVAL "simg2img \"$TMP_DIR/$d/$p.img\" \"$TMP_DIR/$d/$p.raw\"" || exit 1
                        mv -f "$TMP_DIR/$d/$p.raw" "$TMP_DIR/$d/$p.img"
                    fi
                done
                # img2sdat insists on map paths with --src-image, but raw
                # images (FileImage) never read them.
                : > "$TMP_DIR/.unused.map"
                SRC_MAP="$TMP_DIR/.unused.map"
                TGT_MAP="$TMP_DIR/.unused.map"
            fi
            EVAL "TMPDIR=\"$TMP_DIR/blockdiff-tmp\" img2sdat -o \"$TMP_DIR\" -c \"$TARGET_CACHE_PARTITION_SIZE\" --src-image \"$TMP_DIR/source/$p.img\" --src-block-map \"$SRC_MAP\" --tgt-block-map \"$TGT_MAP\" \"$TMP_DIR/target/$p.img\"" || exit 1
            VERIFY_BLOCK_UPDATE "$p" "$TMP_DIR/source/$p.img"
        fi
        rm -f "$TMP_DIR/source/$p.img" "$TMP_DIR/source/$p.map" \
            "$TMP_DIR/target/$p.img" "$TMP_DIR/target/$p.map"
    else
        LOG "- Converting $p.img to $p.new.dat"
        TGT_MAP_ARG=""
        [ -f "$TMP_DIR/target/$p.map" ] && TGT_MAP_ARG="--tgt-block-map \"$TMP_DIR/target/$p.map\""
        EVAL "img2sdat -o \"$TMP_DIR\" $TGT_MAP_ARG \"$TMP_DIR/target/$p.img\"" || exit 1
        VERIFY_BLOCK_UPDATE "$p"
        rm -f "$TMP_DIR/target/$p.img" "$TMP_DIR/target/$p.map"

        if ! $DEBUG; then
            LOG "- Compressing $p.new.dat"
            # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#3585
            EVAL "brotli --quality=6 --output=\"$TMP_DIR/$p.new.dat.br\" \"$TMP_DIR/$p.new.dat\"" || exit 1
            EVAL "brotli -t \"$TMP_DIR/$p.new.dat.br\"" || exit 1
            rm -f "$TMP_DIR/$p.new.dat"
        fi
    fi
done

# Images the target installer flashes itself (install-start/end.edify) must
# always be in the package, changed or not: dtbo_lte.img on y2s, prism.img and
# optics.img on m21s.  Without it package_extract_file fails and, for
# dtbo_lte.img, an SM-G985F keeps the 5G dtbo just written by this package.
INSTALLER_IMAGES="$(cat "$SRC_DIR/target/$TARGET_CODENAME/installer/install-start.edify" \
    "$SRC_DIR/target/$TARGET_CODENAME/installer/install-end.edify" 2> /dev/null | \
    grep -oE 'package_extract_file\("[^"/]+"' | cut -d '"' -f 2 | sort -u)"

INSTALLED_IMAGES="boot.img unsparse_super_empty.img"
for b in $KERNEL_BINS; do
    INSTALLED_IMAGES+=" $b.img"
done

while IFS= read -r f; do
    IMG="$(basename "$f")"
    if ! grep -qxF "$IMG" <<< "$INSTALLER_IMAGES" && [[ " $INSTALLED_IMAGES " != *" $IMG "* ]]; then
        LOG "- Skipping $IMG, not installed by this package"
        rm -f "$f"
    elif grep -qxF "$IMG" <<< "$INSTALLER_IMAGES"; then
        LOG "- Keeping $IMG for the target installer"
        mv -f "$f" "$TMP_DIR/$IMG"
    elif [ -f "$TMP_DIR/source/$IMG" ] && cmp -s "$TMP_DIR/source/$IMG" "$f"; then
        LOG "- Skipping unchanged $IMG"
        rm -f "$f"
    else
        LOG "- Copying changed $IMG from target files"
        mv -f "$f" "$TMP_DIR/$IMG"
    fi
    if [ -f "$TMP_DIR/$IMG" ] && [[ "$IMG" != "unsparse_super_empty.img" ]]; then
        CHECK_RAW_IMAGE "$TMP_DIR/$IMG"
    fi
done < <(find "$TMP_DIR/target" -maxdepth 1 -type f -name "*.img")

rm -rf "$TMP_DIR/source" "$TMP_DIR/target"

if ! find "$TMP_DIR" -maxdepth 1 -type f \( -name "*.transfer.list" -o -name "*.img" ! -name "unsparse_super_empty.img" \) | grep -q .; then
    LOGE "Source and target have no differences; nothing to update"
    exit 1
fi

LOG "- Generating updater-script"
GENERATE_UPDATER_SCRIPT

LOG "- Generating build_info.txt"
PRINT_BUILD_INFO "$SOURCE_BUILD_INFO" "$TARGET_BUILD_INFO" > "$TMP_DIR/build_info.txt" || exit 1

LOG "- Generating OTA metadata"
GENERATE_OTA_METADATA

if [ -d "$SRC_DIR/target/$TARGET_CODENAME/installer/root" ]; then
    LOG "- Copying target custom install files"
    EVAL "cp -a --remove-destination \"$SRC_DIR/target/$TARGET_CODENAME/installer/root/\"* \"$TMP_DIR\"" || exit 1
fi

if [ -f "$SRC_DIR/target/$TARGET_CODENAME/installer/customize.sh" ]; then
    LOG_STEP_IN "- Running target custom install script"
    (
    . "$SRC_DIR/target/$TARGET_CODENAME/installer/customize.sh"
    ) || exit 1
    LOG_STEP_OUT
fi

LOG "- Checking package contents"
rm -rf "$VERIFY_DIR"
find "$TMP_DIR" -maxdepth 1 -type f \( -name "*.touched_src_*" -o -name "*.max_stashed_size" \) -delete
CHECK_PACKAGE_REFERENCES "" || exit 1

LOG "- Creating zip"
EVAL "rm -f \"$TMP_DIR/rom.zip\"" || exit 1
# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#3601
# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/common.py#3609
# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/ota_utils.py#184
# https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/ota_utils.py#186
EVAL "cd \"$TMP_DIR\" && 7z a -tzip -mx=0 -mmt=$(nproc) $TMP_DIR/rom.zip -r *.patch.dat -ir!META-INF/com/android/* -i!*.new.dat.br" || exit 1
EVAL "cd \"$TMP_DIR\" && 7z a -tzip -mx=3 -mmt=$(nproc) $TMP_DIR/rom.zip -r * -xr!META-INF/com/android/* -x!*.new.dat.br -x!*.patch.dat -x!rom.zip" || exit 1

# Write next to the output and move into place only once the package is
# complete, so a failed run never leaves a truncated ZIP behind.
PACKAGE="$OUTPUT_FILE.partial"
rm -f "$PACKAGE"
if ! $DEBUG || $ROM_IS_OFFICIAL; then
    LOG "- Signing zip"
    EVAL "signapk -w \"$PUBLIC_KEY_PATH\" \"$PRIVATE_KEY_PATH\" \"$TMP_DIR/rom.zip\" \"$PACKAGE\"" || exit 1
    rm -f "$TMP_DIR/rom.zip"
else
    mv -f "$TMP_DIR/rom.zip" "$PACKAGE"
fi

LOG "- Verifying zip"
if ! unzip -tq "$PACKAGE" &> /dev/null; then
    rm -f "$PACKAGE"
    LOGE "Generated zip failed the integrity test"
    exit 1
fi
CHECK_PACKAGE_REFERENCES "$(unzip -Z1 "$PACKAGE")" || { rm -f "$PACKAGE"; exit 1; }
for f in META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
    if ! unzip -Z1 "$PACKAGE" | grep -qxF "$f"; then
        rm -f "$PACKAGE"
        LOGE "Generated zip has no $f"
        exit 1
    fi
done
mv -f "$PACKAGE" "$OUTPUT_FILE"

exit 0
