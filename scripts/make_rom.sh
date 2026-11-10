#!/usr/bin/env bash
# Copyright (c) 2025 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# Run from an immutable snapshot. A build can take hours, and changing this
# file while Bash is still reading it can otherwise corrupt the command being
# parsed at the current file offset.
if [ -z "${UNICA_MAKE_ROM_SNAPSHOT:-}" ]; then
    UNICA_MAKE_ROM_SNAPSHOT_PATH="$(mktemp "${TMPDIR:-/tmp}/unica-make-rom.XXXXXX")" || exit 1
    cp -a "${BASH_SOURCE[0]}" "$UNICA_MAKE_ROM_SNAPSHOT_PATH" || {
        rm -f -- "$UNICA_MAKE_ROM_SNAPSHOT_PATH"
        exit 1
    }
    export UNICA_MAKE_ROM_SNAPSHOT=1
    export UNICA_MAKE_ROM_SNAPSHOT_PATH
    trap 'rm -f -- "$UNICA_MAKE_ROM_SNAPSHOT_PATH"' EXIT
    exec bash "$UNICA_MAKE_ROM_SNAPSHOT_PATH" "$@"
fi

# [
source "$SRC_DIR/scripts/utils/firmware_utils.sh" || exit 1

FORCE=false
USE_APK_CACHE=false
BUILD_ROM=false
BUILD_ZIP=true
BUILD_INCREMENTAL=false
# -k: reuse the work dir of the last build, rebuild only the kernel modules
# (module.prop "kernel=true") and make an incremental zip against it.
KERNEL_ONLY=false
# FotaAgent result (/cache/fota/fota.status): incremental zips always record
# it; full zips only with -u/--fota-status (exported for the zip generators).
export FOTA_STATUS_IN_FULL_ZIP=false
SKIP_DEBUG_INSTALL=false

START_TIME="$(date +%s)"

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")"
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
APK_CACHE_DIR="$OUT_DIR/target/$TARGET_CODENAME/apk_cache"
APK_DECODE_CACHE_DIR="$OUT_DIR/target/$TARGET_CODENAME/apk_decode_cache"
APK_BUILD_LIST="$OUT_DIR/target/$TARGET_CODENAME/tmp/apk-cache-build.list"
APK_CACHE_FORMAT="unica-apk-cache-v2"
INCREMENTAL_DIR="$OUT_DIR/target/$TARGET_CODENAME/incremental"
# Target files are stored as directories of images (see install_utils.sh).
# A base-target-files.zip from older builds is still used once as the source.
INCREMENTAL_BASE="$INCREMENTAL_DIR/base-target-files"
INCREMENTAL_PREV="$INCREMENTAL_DIR/base-target-files.prev"
INCREMENTAL_TARGET="$INCREMENTAL_DIR/target-files"
INCREMENTAL_LEGACY_BASE="$INCREMENTAL_DIR/base-target-files.zip"
INCREMENTAL_LEGACY_PREV="$INCREMENTAL_DIR/base-target-files.prev.zip"
# Target files of published releases (pinned by fota_release.py upload
# --publish): the builds that devices actually run. -i diffs against the
# newest $ROM_INCREMENTAL_BASES of them, one zip each.
INCREMENTAL_PUBLISHED="$INCREMENTAL_DIR/published"
INCREMENTAL_MAX_BASES="${ROM_INCREMENTAL_BASES:-2}"

GET_PATCHED_APK_HASH()
{
    local DECODED_PATH="$1"
    local RELATIVE_PATH="$2"
    local CERT_PREFIX="aosp"

    [ -d "$DECODED_PATH" ] || return 1
    $ROM_IS_OFFICIAL && CERT_PREFIX="unica"

    {
        printf '%s\n' "$APK_CACHE_FORMAT" "$RELATIVE_PATH"
        find "$DECODED_PATH" -type f \
            ! -path "$DECODED_PATH/build/*" \
            ! -path "$DECODED_PATH/dist/*" \
            -print0 | sort -z | xargs -0 sha256sum
        sha256sum "$SRC_DIR/scripts/apktool.sh"
        if [[ "$RELATIVE_PATH" == *.apk ]]; then
            sha256sum "$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem" \
                "$SRC_DIR/security/${CERT_PREFIX}_platform.pk8"
        fi
    } | sha256sum | cut -d " " -f 1
}

GET_BUILT_APK_PATH()
{
    local RELATIVE_PATH="$1"
    local PARTITION
    local FILE

    PARTITION="$(cut -d "/" -f 1 -s <<< "$RELATIVE_PATH")"
    FILE="$(cut -d "/" -f 2- -s <<< "$RELATIVE_PATH")"

    case "$PARTITION" in
        "system")
            echo "$WORK_DIR/system/system/$FILE"
            ;;
        "system_ext")
            if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
                echo "$WORK_DIR/system_ext/$FILE"
            else
                echo "$WORK_DIR/system/system/system_ext/$FILE"
            fi
            ;;
        *)
            echo "$WORK_DIR/$PARTITION/$FILE"
            ;;
    esac
}

RESTORE_APK_CACHE()
{
    local CACHE_HASH
    local CURRENT_HASH
    local DECODED_PATH
    local RELATIVE_PATH
    local OUTPUT_FILE
    local HIT_COUNT="0"
    local MISS_COUNT="0"

    mkdir -p "$(dirname "$APK_BUILD_LIST")"
    : > "$APK_BUILD_LIST"

    while IFS= read -r -d '' f; do
        DECODED_PATH="$f"
        RELATIVE_PATH="${f/$APKTOOL_DIR\//}"
        OUTPUT_FILE="$(GET_BUILT_APK_PATH "$RELATIVE_PATH")"
        CURRENT_HASH="$(GET_PATCHED_APK_HASH "$DECODED_PATH" "$RELATIVE_PATH")" || return 1
        CACHE_HASH="$(cat "$APK_CACHE_DIR/hashes/$RELATIVE_PATH" 2> /dev/null || true)"

        if [ "$CACHE_HASH" = "$CURRENT_HASH" ] && \
                [ -f "$APK_CACHE_DIR/files/$RELATIVE_PATH" ]; then
            mkdir -p "$(dirname "$OUTPUT_FILE")"
            cp -a --reflink=auto "$APK_CACHE_DIR/files/$RELATIVE_PATH" "$OUTPUT_FILE"
            HIT_COUNT=$((HIT_COUNT + 1))
        else
            printf '%s\0' "$DECODED_PATH" >> "$APK_BUILD_LIST"
            MISS_COUNT=$((MISS_COUNT + 1))
        fi
    done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) -print0)

    LOG "- APK/JAR incremental cache: $HIT_COUNT reused, $MISS_COUNT to build"
    return 0
}

UPDATE_APK_CACHE()
{
    local CACHE_TMP
    local DECODED_PATH
    local FILE_HASH
    local RELATIVE_PATH
    local OUTPUT_FILE

    [ -d "$APKTOOL_DIR" ] || return 0
    CACHE_TMP="$APK_CACHE_DIR.tmp.$$"
    rm -rf "$CACHE_TMP"
    mkdir -p "$CACHE_TMP/files" "$CACHE_TMP/hashes"

    while IFS= read -r -d '' f; do
        DECODED_PATH="$f"
        RELATIVE_PATH="${f/$APKTOOL_DIR\//}"
        OUTPUT_FILE="$(GET_BUILT_APK_PATH "$RELATIVE_PATH")"
        [ -f "$OUTPUT_FILE" ] || return 1
        FILE_HASH="$(GET_PATCHED_APK_HASH "$DECODED_PATH" "$RELATIVE_PATH")" || return 1
        mkdir -p "$CACHE_TMP/files/$(dirname "$RELATIVE_PATH")" \
            "$CACHE_TMP/hashes/$(dirname "$RELATIVE_PATH")"
        cp -a --reflink=auto "$OUTPUT_FILE" "$CACHE_TMP/files/$RELATIVE_PATH"
        printf '%s' "$FILE_HASH" > "$CACHE_TMP/hashes/$RELATIVE_PATH"
    done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) -print0)

    printf '%s' "$APK_CACHE_FORMAT" > "$CACHE_TMP/.format"
    rm -rf "$APK_CACHE_DIR"
    mv "$CACHE_TMP" "$APK_CACHE_DIR"
    LOG "- Updated per-file APK/JAR cache"
}

BUILD_APKS()
{
    local BUILD_LIST="${1:-}"
    local MAX_JOBS
    MAX_JOBS="$(nproc)"
    [ "$MAX_JOBS" -gt "8" ] && MAX_JOBS="8"

    if [ -d "$APKTOOL_DIR" ]; then
        if [ -n "$BUILD_LIST" ] && [ ! -s "$BUILD_LIST" ]; then
            LOG "- All APKs/JARs were restored from incremental cache"
            return 0
        fi

        LOG_STEP_IN true "Building APKs/JARs"

        # shellcheck disable=SC2016
        if [ -n "$BUILD_LIST" ]; then
            cat "$BUILD_LIST"
        else
            find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) -print0
        fi | xargs -0 -r -I "{}" -P "$MAX_JOBS" \
            bash -c '
                FILE="${1/$APKTOOL_DIR\//}"
                PARTITION="$(cut -d "/" -f 1 -s <<< "$FILE")"
                [[ "$PARTITION" != "system" ]] && FILE="$(cut -d "/" -f 2- -s <<< "$FILE")"
                "$SRC_DIR/scripts/apktool.sh" b -j "$2" "$PARTITION" "$FILE"
            ' "bash" "{}" "$MAX_JOBS" || exit 1

        LOG_STEP_OUT
    fi
}

GET_WORK_DIR_HASH()
{
    local FIRMWARE_IDENTITY
    FIRMWARE_IDENTITY="$(cat \
        "$FW_DIR/$SOURCE_FIRMWARE_PATH/.extracted" \
        "$FW_DIR/$TARGET_FIRMWARE_PATH/.extracted" 2> /dev/null | \
        sha256sum | cut -d " " -f 1)"

    {
        if [ "${TARGET_PLATFORM//none/}" ] && [ -d "$SRC_DIR/platform/$TARGET_PLATFORM" ]; then
            find -H "$SRC_DIR/scripts" "$SRC_DIR/unica" \
                "$SRC_DIR/platform/$TARGET_PLATFORM" \
                "$SRC_DIR/target/$TARGET_CODENAME" -type f -print0
        else
            find -H "$SRC_DIR/scripts" "$SRC_DIR/unica" \
                "$SRC_DIR/target/$TARGET_CODENAME" -type f -print0
        fi
    } | sort -z | xargs -0 sha1sum | {
        cat
        printf 'firmware_identity  %s\n' "$FIRMWARE_IDENTITY"
    } | sha1sum | cut -d " " -f 1
}

PREPARE_SCRIPT()
{
    while [[ "$#" != 0 ]]; do
        if [[ "$1" == "--force" ]] || [[ "$1" == "-f" ]]; then
            FORCE=true
        elif [[ "$1" == "--use-apk-cache" ]] || [[ "$1" == "-c" ]]; then
            USE_APK_CACHE=true
        elif [[ "$1" == "--no-rom-zip" ]] || [[ "$1" == "-z" ]]; then
            BUILD_ZIP=false
        elif [[ "$1" == "--incremental" ]] || [[ "$1" == "-i" ]]; then
            BUILD_INCREMENTAL=true
        elif [[ "$1" == "--fota-status" ]] || [[ "$1" == "-u" ]]; then
            FOTA_STATUS_IN_FULL_ZIP=true
        elif [[ "$1" == "--kernel-only" ]] || [[ "$1" == "-k" ]]; then
            KERNEL_ONLY=true
            BUILD_INCREMENTAL=true
        else
            if [[ "$1" == "-"* ]]; then
                LOGE "Unknown option: $1"
            fi
            PRINT_USAGE
            exit 1
        fi

        shift
    done
}

# shellcheck disable=SC2317,SC2329
PRINT_BUILD_OUTCOME()
{
    local EXIT_CODE="$?"
    local END_TIME
    local ESTIMATED

    [ -n "${UNICA_MAKE_ROM_SNAPSHOT_PATH:-}" ] && \
        rm -f -- "$UNICA_MAKE_ROM_SNAPSHOT_PATH"

    END_TIME="$(date +%s)"
    ESTIMATED="$((END_TIME - START_TIME))"

    if [[ "$EXIT_CODE" != "0" ]]; then
        echo -n -e '\n\033[1;31m'"Build failed "
    else
        echo -n -e '\n\033[1;32m'"Build completed "
    fi
    echo -e "in $((ESTIMATED / 3600))hrs $(((ESTIMATED / 60) % 60))min $((ESTIMATED % 60))sec."'\033[0m\n'
}

PRINT_USAGE()
{
    echo "Usage: make_rom [options]" >&2
    echo " -f, --force : Force ROM build" >&2
    echo " -c, --use-apk-cache : Incrementally rebuild only changed APKs/JARs" >&2
    echo " -i, --incremental : Build a block-level update from the previous target-files snapshot" >&2
    echo " -u, --fota-status : Also record the FotaAgent install result in full ROM zips" >&2
    echo " -k, --kernel-only : Rebuild only the kernel (boot/dtbo) on the last build and make an incremental zip" >&2
    echo " --no-rom-zip : Do not build ROM zip" >&2
}
# ]

PREPARE_SCRIPT "$@"

# apktool.sh is also invoked indirectly by patch modules. Exporting the cache
# policy here lets every decode participate without changing module scripts.
export APK_DECODE_CACHE_DIR
if $USE_APK_CACHE; then
    export APK_DECODE_CACHE_MODE="reuse"
else
    export APK_DECODE_CACHE_MODE="refresh"
    rm -rf "$APK_DECODE_CACHE_DIR"
fi

# Reuse a completed work directory when the source tree and firmware identity
# are unchanged. This keeps the expensive extraction/patch/APK phase out of a
# packaging-only rerun; -c still controls only the separate APK/JAR cache.
BUILD_ROM=true
if $KERNEL_ONLY; then
    # The kernel-only update is a diff against the last build, which must be
    # both the reused work dir and the incremental baseline (the build that is
    # installed on the device).  Other source changes are left out on purpose
    # and .completed is not refreshed, so the next normal build rebuilds them.
    if [ ! -f "$WORK_DIR/.completed" ]; then
        LOGE "-k needs the work dir of a completed build: ${WORK_DIR//$SRC_DIR\//}"
        exit 1
    fi
    if [ ! -f "$INCREMENTAL_BASE/build_info.txt" ]; then
        LOGE "-k needs the incremental baseline of the installed build: ${INCREMENTAL_BASE//$SRC_DIR\//}"
        exit 1
    fi
    WORK_DIR_TIMESTAMP="$(sed -n "s/^ro.unica.timestamp=//p" "$WORK_DIR/system/system/build.prop" | head -n 1)"
    # After a kernel-only update the baseline keeps the system timestamp
    # apart from its own (the kernel's).
    BASE_TIMESTAMP="$(sed -n "s/^system_timestamp=//p" "$INCREMENTAL_BASE/build_info.txt" | head -n 1)"
    [ "$BASE_TIMESTAMP" ] || \
        BASE_TIMESTAMP="$(sed -n "s/^timestamp=//p" "$INCREMENTAL_BASE/build_info.txt" | head -n 1)"
    if [ ! "$WORK_DIR_TIMESTAMP" ] || [[ "$WORK_DIR_TIMESTAMP" != "$BASE_TIMESTAMP" ]]; then
        LOGE "The work dir (timestamp ${WORK_DIR_TIMESTAMP:-none}) is not the incremental baseline (timestamp ${BASE_TIMESTAMP:-none})"
        LOGE "Build and install a full or incremental update with this version of make_rom.sh first"
        exit 1
    fi
    if [[ "$(cat "$WORK_DIR/.completed")" != "$(GET_WORK_DIR_HASH)" ]]; then
        LOGW "Source changes outside the kernel modules are not part of a kernel-only update"
    fi
    BUILD_ROM=false
elif ! $FORCE && [ -d "$WORK_DIR" ] && [ -f "$WORK_DIR/.completed" ]; then
    if [[ "$(cat "$WORK_DIR/.completed")" == "$(GET_WORK_DIR_HASH)" ]]; then
        LOGW "No changes have been detected in the build environment; reusing work dir"
        BUILD_ROM=false
    else
        LOGW "Changes detected in the build environment; rebuilding work dir"
    fi
fi

trap 'PRINT_BUILD_OUTCOME' EXIT
trap 'echo' INT

if $BUILD_ROM; then
    if [ -d "$WORK_DIR" ]; then
        LOG "- Cleaning stale work dir before rebuild"
        rm -rf "${WORK_DIR:?}"
    fi
    [ -d "$APKTOOL_DIR" ] && rm -rf "$APKTOOL_DIR"

    if [ ! -f "$FW_DIR/$SOURCE_FIRMWARE_PATH/.extracted" ] || [ ! -f "$FW_DIR/$TARGET_FIRMWARE_PATH/.extracted" ]; then
        if ! ODIN_FIRMWARE_IS_COMPLETE "$ODIN_DIR/$SOURCE_FIRMWARE_PATH" || \
                ! ODIN_FIRMWARE_IS_COMPLETE "$ODIN_DIR/$TARGET_FIRMWARE_PATH"; then
            LOG_STEP_IN true "Downloading required firmwares"
            "$SRC_DIR/scripts/download_fw.sh" || exit 1
            LOG_STEP_OUT
        fi
        LOG_STEP_IN true "Extracting required firmwares"
        "$SRC_DIR/scripts/extract_fw.sh" || exit 1
        LOG_STEP_OUT
    fi

    LOG_STEP_IN true "Creating work dir"
    "$SRC_DIR/scripts/internal/create_work_dir.sh" || exit 1
    LOG_STEP_OUT

    if [ -d "$SRC_DIR/platform/$TARGET_PLATFORM/patches" ]; then
        LOG_STEP_IN true "Applying platform patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/platform/$TARGET_PLATFORM/patches" || exit 1
        LOG_STEP_OUT
    fi
    if [ -d "$SRC_DIR/target/$TARGET_CODENAME/patches" ]; then
        LOG_STEP_IN true "Applying device patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/target/$TARGET_CODENAME/patches" || exit 1
        LOG_STEP_OUT
    fi
    if [ -d "$SRC_DIR/unica/patches" ]; then
        LOG_STEP_IN true "Applying ROM patches"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/patches" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/platform/$TARGET_PLATFORM/mods" ]; then
        LOG_STEP_IN true "Applying platform mods"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/platform/$TARGET_PLATFORM/mods" || exit 1
        LOG_STEP_OUT
    fi

    if [ -d "$SRC_DIR/unica/mods" ]; then
        LOG_STEP_IN true "Applying ROM mods"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/unica/mods" || exit 1
        LOG_STEP_OUT
    fi

    # Target modules are applied last so a device-specific policy or APK
    # patch cannot be overwritten by a shared ROM module.  Keep these out of
    # unica/mods: the target tree is the source of truth for device-only work.
    if [ -d "$SRC_DIR/target/$TARGET_CODENAME/mods" ]; then
        LOG_STEP_IN true "Applying target mods"
        "$SRC_DIR/scripts/internal/apply_modules.sh" "$SRC_DIR/target/$TARGET_CODENAME/mods" || exit 1
        LOG_STEP_OUT
    fi

    if $USE_APK_CACHE; then
        RESTORE_APK_CACHE || exit 1
        BUILD_APKS "$APK_BUILD_LIST"
    else
        BUILD_APKS
    fi
    UPDATE_APK_CACHE || exit 1

    echo -n "$(GET_WORK_DIR_HASH)" > "$WORK_DIR/.completed"
fi

if $KERNEL_ONLY; then
    LOG_STEP_IN true "Rebuilding kernel modules"
    KERNEL_MODULES=0
    for MODULES_DIR in "$SRC_DIR/platform/$TARGET_PLATFORM/patches" "$SRC_DIR/target/$TARGET_CODENAME/patches"; do
        [ -d "$MODULES_DIR" ] || continue
        while IFS= read -r MODULE_PROP; do
            grep -q "^kernel=true$" "$MODULE_PROP" || continue
            [ -f "$(dirname "$MODULE_PROP")/disable" ] && continue
            "$SRC_DIR/scripts/internal/apply_modules.sh" "$(dirname "$MODULE_PROP")" || exit 1
            KERNEL_MODULES=$((KERNEL_MODULES + 1))
        done < <(find "$MODULES_DIR" -mindepth 2 -maxdepth 2 -name module.prop | sort)
    done
    if [[ "$KERNEL_MODULES" == "0" ]]; then
        LOGE "No kernel module (module.prop \"kernel=true\") for $TARGET_CODENAME"
        exit 1
    fi
    LOG_STEP_OUT
fi

# Runs on every build, also when the work dir is reused: the source commit
# can change without changing the contents GET_WORK_DIR_HASH looks at.
# Kernel-only updates leave the system partition as installed; their build
# identity goes into the boot image (create_kernel_only_target_files.sh).
if [ -d "$WORK_DIR" ] && ! $KERNEL_ONLY; then
    LOG_STEP_IN true "Stamping build commit"
    "$SRC_DIR/scripts/internal/stamp_build_info.sh" || exit 1
    LOG_STEP_OUT
fi

if $BUILD_ZIP; then
    mkdir -p "$INCREMENTAL_DIR"
    rm -rf "$INCREMENTAL_TARGET" "$INCREMENTAL_DIR/target-files.zip"

    # Incremental zips start from published builds, not from the last build:
    # base-target-files follows every build, including test builds that are
    # never published, and the published one used to be rotated away.
    INCREMENTAL_SOURCES=()
    if $BUILD_INCREMENTAL; then
        if [ -d "$INCREMENTAL_PUBLISHED" ]; then
            while IFS= read -r d; do
                INCREMENTAL_SOURCES+=("$d")
            done < <(
                for d in "$INCREMENTAL_PUBLISHED"/*/; do
                    d="${d%/}"
                    [ -f "$d/build_info.txt" ] || continue
                    echo "$(sed -n "s/^timestamp=//p" "$d/build_info.txt" | head -n 1) $d"
                done | sort -rn | head -n "$INCREMENTAL_MAX_BASES" | cut -d " " -f 2-
            )
        fi
        if [ "${#INCREMENTAL_SOURCES[@]}" = 0 ]; then
            if [ -d "$INCREMENTAL_BASE" ]; then
                INCREMENTAL_SOURCES=("$INCREMENTAL_BASE")
            elif [ -f "$INCREMENTAL_LEGACY_BASE" ]; then
                INCREMENTAL_SOURCES=("$INCREMENTAL_LEGACY_BASE")
            fi
            [ "${#INCREMENTAL_SOURCES[@]}" != 0 ] && \
                LOGW "No published baseline in ${INCREMENTAL_PUBLISHED//$SRC_DIR\//}; using the last build as the incremental base"
        fi
    fi

    # Every zip is built from target-files, which then become the baseline
    # of the next incremental (and -k) update.  Full builds used to skip this,
    # so after installing one the baseline no longer matched the device.
    LOG_STEP_IN true "Creating target-files"
    if $KERNEL_ONLY; then
        # Only the kernel images change: link the baseline instead of
        # rebuilding every partition image just to diff them as unchanged.
        "$SRC_DIR/scripts/internal/create_kernel_only_target_files.sh" \
            "$INCREMENTAL_BASE" "$INCREMENTAL_TARGET" || exit 1
    else
        "$SRC_DIR/scripts/internal/create_target_files_zip.sh" "$INCREMENTAL_TARGET" || exit 1
    fi
    LOG_STEP_OUT

    if [ "${#INCREMENTAL_SOURCES[@]}" != 0 ]; then
        for INCREMENTAL_SOURCE in "${INCREMENTAL_SOURCES[@]}"; do
            LOG_STEP_IN true "Creating incremental ROM zip from ${INCREMENTAL_SOURCE//$SRC_DIR\//}"
            "$SRC_DIR/scripts/build_flashable_zip.sh" \
                --incremental "$INCREMENTAL_SOURCE" "$INCREMENTAL_TARGET" || exit 1
            LOG_STEP_OUT
        done
    else
        $BUILD_INCREMENTAL && \
            LOGW "No incremental base exists; creating a full ZIP and establishing the baseline"
        LOG_STEP_IN true "Creating zip"
        "$SRC_DIR/scripts/build_flashable_zip.sh" "$INCREMENTAL_TARGET" || exit 1
        LOG_STEP_OUT
    fi

    # Promote the target only after the ZIP was generated successfully. A
    # failed build must never destroy the last known installable baseline.
    # The previous baseline is kept: if the ZIP just built is never
    # installed, the next one can be rebuilt against it with
    # build_flashable_zip.sh -i.
    if [ -d "$INCREMENTAL_BASE" ]; then
        rm -rf "$INCREMENTAL_PREV"
        rm -f "$INCREMENTAL_LEGACY_PREV" "$INCREMENTAL_LEGACY_BASE"
        mv -f "$INCREMENTAL_BASE" "$INCREMENTAL_PREV"
    elif [ -f "$INCREMENTAL_LEGACY_BASE" ]; then
        mv -f "$INCREMENTAL_LEGACY_BASE" "$INCREMENTAL_LEGACY_PREV"
    fi
    mv -f "$INCREMENTAL_TARGET" "$INCREMENTAL_BASE"
    LOG "- Updated incremental baseline: ${INCREMENTAL_BASE//$SRC_DIR\//}"
fi

exit 0
