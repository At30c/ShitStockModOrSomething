# Copyright (c) 2025 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# [
source "$SRC_DIR/scripts/utils/common_utils.sh"
# ]

# GET_DISK_USAGE <file>
# Returns the size in bytes of the supplied file.
GET_DISK_USAGE()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || return 1

    local FILE="$1"

    if [ ! -e "$FILE" ]; then
        LOGE "File not found: ${FILE//$SRC_DIR\//}"
        return 1
    fi

    local SIZE
    # https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/tools/releasetools/build_image.py#63
    SIZE="$(du -b -k -s "$FILE" | cut -f 1)"

    bc -l <<< "$SIZE * 1024"
}

# GET_IMAGE_SIZE <file>
# Returns the size in bytes of the supplied image.
GET_IMAGE_SIZE()
{
    _CHECK_NON_EMPTY_PARAM "FILE" "$1" || return 1

    local FILE="$1"

    if [ ! -f "$FILE" ]; then
        LOGE "File not found: ${FILE//$SRC_DIR\//}"
        return 1
    fi

    if IS_SPARSE_IMAGE "$FILE"; then
        local BLOCK_SIZE
        local BLOCKS
        BLOCK_SIZE="$(printf "%d" "0x$(READ_BYTES_AT "$FILE" "12" "4")")"
        BLOCKS="$(printf "%d" "0x$(READ_BYTES_AT "$FILE" "16" "4")")"

        bc -l <<< "$BLOCKS * $BLOCK_SIZE"
    else
        GET_DISK_USAGE "$FILE"
    fi
}

# BUILD_TARGET_PHYSICAL_PARTITION_IMAGES <output directory>
# Build the target's fixed Prism/Optics trees as standalone ext4 images. These
# partitions live outside super and therefore use their own SELinux contexts
# and byte-sized partition limits from target/<device>/config.sh.
BUILD_TARGET_PHYSICAL_PARTITION_IMAGES()
{
    _CHECK_NON_EMPTY_PARAM "OUTPUT_DIR" "$1" || return 1

    local OUTPUT_DIR="$1"
    if [[ "${TARGET_BUILD_PHYSICAL_PARTITIONS:-false}" != "true" ]]; then
        return 0
    fi

    local CSC_DIR="$SRC_DIR/target/$TARGET_CODENAME/CSC"
    if [ ! -d "$CSC_DIR" ]; then
        LOGE "Physical partition source directory not found: ${CSC_DIR//$SRC_DIR\//}"
        return 1
    fi

    mkdir -p "$OUTPUT_DIR"

    local PARTITION
    local SOURCE_DIR
    local CONTEXT_SOURCE
    local CONTEXT_FILE
    local FS_CONFIG_FILE
    local SIZE_VAR
    local ENTRY
    local RELATIVE
    local MODE
    for PARTITION in prism optics; do
        SOURCE_DIR="$CSC_DIR/$PARTITION"
        CONTEXT_SOURCE="$CSC_DIR/file_context-$PARTITION"
        SIZE_VAR="TARGET_$(tr '[:lower:]' '[:upper:]' <<< "$PARTITION")_PARTITION_SIZE"
        CONTEXT_FILE="$OUTPUT_DIR/.${PARTITION}_file_context"
        FS_CONFIG_FILE="$OUTPUT_DIR/.${PARTITION}_fs_config"

        [ -d "$SOURCE_DIR" ] || {
            LOGE "Physical partition tree not found: ${SOURCE_DIR//$SRC_DIR\//}"
            return 1
        }
        [ -f "$CONTEXT_SOURCE" ] || {
            LOGE "SELinux context file not found: ${CONTEXT_SOURCE//$SRC_DIR\//}"
            return 1
        }
        _CHECK_NON_EMPTY_PARAM "$SIZE_VAR" "${!SIZE_VAR}" || return 1

        cp -a "$CONTEXT_SOURCE" "$CONTEXT_FILE" || return 1
        {
            # e2fsdroid represents the image root with an empty path. Child
            # entries are rooted at the partition mount point (as in the
            # generated vendor/product fs_config files).
            echo " 0 0 755 capabilities=0x0"
            while IFS= read -r ENTRY; do
                RELATIVE="${ENTRY#"$SOURCE_DIR"/}"
                MODE="$(stat -c '%a' "$ENTRY")"
                echo "$PARTITION/$RELATIVE 0 0 $MODE capabilities=0x0"
            done < <(find "$SOURCE_DIR" -mindepth 1 -print | sort)
        } > "$FS_CONFIG_FILE"

        LOG "- Building $PARTITION image from target/$TARGET_CODENAME/CSC/$PARTITION"
        "$SRC_DIR/scripts/build_fs_image.sh" ext4 \
            --avb --partition-name "$PARTITION" \
            --output "$OUTPUT_DIR/$PARTITION.img" \
            --partition-size "${!SIZE_VAR}" \
            "$SOURCE_DIR" "$CONTEXT_FILE" "$FS_CONFIG_FILE" || return 1

        rm -f "$CONTEXT_FILE" "$FS_CONFIG_FILE"
    done
}

# [
DEPENDENCIES=(
    "7z" "awk" "basename" "bc" "brotli" "cat" "clang" "cmake"
    "cp" "cpio" "curl" "cut" "cwebp" "dd" "dirname" "du" "ffmpeg"
    "file" "getfattr" "git" "grep" "head" "java" "ln"
    "lz4" "make" "md5sum" "mkdir" "mount" "mv" "perl" "protoc"
    "python3" "rm" "rsync" "sed" "sha1sum" "sort" "split" "stat"
    "sudo" "tail" "tar" "touch" "tr" "truncate" "umount" "unzip"
    "wc" "whoami" "xargs" "xxd" "zip" "zstd"
)
MISSING=()
for d in "${DEPENDENCIES[@]}"; do
    if ! type "$d" &> /dev/null; then
        MISSING+=("$d")
    fi
done
if [ "${#MISSING[@]}" -ne 0 ]; then
    echo -e '\033[1;31m'"The following dependencies are missing from your system:"'\033[0;31m' >&2
    printf '%s ' "${MISSING[@]}" >&2
    echo -e '\033[0m' >&2
    return 1
fi
unset DEPENDENCIES MISSING

if ! "$SRC_DIR/external/make.sh" --check-tools; then
    LOG_STEP_IN true "Building required tools..."
    "$SRC_DIR/external/make.sh" || return 1
    LOG_STEP_OUT
fi
# ]
