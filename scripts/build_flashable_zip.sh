#!/usr/bin/env bash
# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# [
source "$SRC_DIR/scripts/utils/install_utils.sh" || exit 1

INCREMENTAL=false
SOURCE_ZIP=""
TARGET_ZIP=""
OUTPUT_FILE=""

PREPARE_SCRIPT()
{
    if [[ "$#" == 0 ]]; then
        PRINT_USAGE
        exit 1
    fi

    while [[ "$1" == "-"* ]]; do
        if [[ "$1" == "--incremental" ]] || [[ "$1" == "-i" ]]; then
            INCREMENTAL=true
            shift; SOURCE_ZIP="$1"
        elif [[ "$1" == "--output" ]] || [[ "$1" == "-o" ]]; then
            shift; OUTPUT_FILE="$1"
            if [[ "$OUTPUT_FILE" != *".zip" ]]; then
                LOGE "Output file name must have \".zip\" extension"
                exit 1
            fi
        else
            LOGE "Unknown option: $1"
            exit 1
        fi

        shift
    done

    TARGET_ZIP="$1"
    if [ ! "$TARGET_ZIP" ]; then
        PRINT_USAGE
        exit 1
    elif [ ! -e "$TARGET_ZIP" ]; then
        LOGE "File not found: ${TARGET_ZIP//$SRC_DIR\//}"
        exit 1
    fi

    if [ "$SOURCE_ZIP" ]; then
        if [ ! -e "$SOURCE_ZIP" ]; then
            LOGE "File not found: ${SOURCE_ZIP//$SRC_DIR\//}"
            exit 1
        fi
    fi

    if [ ! "$OUTPUT_FILE" ]; then
        local TARGET_BUILD_INFO

        TARGET_BUILD_INFO="$(READ_TARGET_FILES_BUILD_INFO "$TARGET_ZIP")" || exit 1

        OUTPUT_FILE="$OUT_DIR/UN1CA_"
        OUTPUT_FILE+="$(grep "^version" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
        OUTPUT_FILE+="_"
        OUTPUT_FILE+="$(date -d "@$(grep "^timestamp" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)" "+%Y%m%d")"
        OUTPUT_FILE+="_"
        OUTPUT_FILE+="$(grep "^device" <<< "$TARGET_BUILD_INFO" | cut -d "=" -f 2 -s)"
        if $INCREMENTAL; then
            local SOURCE_BUILD_INFO

            SOURCE_BUILD_INFO="$(READ_TARGET_FILES_BUILD_INFO "$SOURCE_ZIP")" || exit 1

            OUTPUT_FILE+="-INCREMENTAL_"
            OUTPUT_FILE+="$(grep "^timestamp" <<< "$SOURCE_BUILD_INFO" | cut -d "=" -f 2 -s)"
        fi
        if ! $DEBUG || $ROM_IS_OFFICIAL; then
            OUTPUT_FILE+="-sign"
        fi
        OUTPUT_FILE+=".zip"
    fi
}

PRINT_USAGE()
{
    echo "Usage: build_flashable_zip [options] <target-files zip or dir>" >&2
    echo " -i, --incremental : Generate an incremental zip using the given target-files zip or dir as source" >&2
    echo " -o, --output : Specify the output zip path, defaults to $OUT_DIR" >&2
}
# ]

PREPARE_SCRIPT "$@"

if $INCREMENTAL; then
    "$SRC_DIR/scripts/internal/build_incremental_ota_zip.sh" "$SOURCE_ZIP" "$TARGET_ZIP" "$OUTPUT_FILE" || exit 1
else
    "$SRC_DIR/scripts/internal/build_full_ota_zip.sh" "$TARGET_ZIP" "$OUTPUT_FILE" || exit 1
fi

exit 0
