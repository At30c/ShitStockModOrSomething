#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# create_kernel_only_target_files <base target-files dir> <output dir>
#
# Target files for a kernel-only update (make_rom.sh -k): the base target
# files hard linked, with only the kernel images replaced by the ones in
# $WORK_DIR/kernel. No partition image is rebuilt, so the incremental zip
# built from base -> output carries only boot/dtbo.
#
# The system partition is untouched, so ro.unica.timestamp stays the base's.
# The new build identity goes into the boot image instead: the bootargs of
# its device tree get androidboot.unica.timestamp=<timestamp>, which init
# exposes as ro.boot.unica.timestamp; the FotaAgent UpdateChecker takes the
# newer of the two. (Samsung's bootloader ignores the boot header command
# line, and the Android 11 first-stage init of the ramdisk does not carry a
# ramdisk build.prop to the second stage.) build_info.txt gets the same
# timestamp.

set -e

#[
source "$SRC_DIR/scripts/utils/install_utils.sh" || exit 1

#]

if [ "$#" != 2 ]; then
    echo "Usage: create_kernel_only_target_files <base target-files dir> <output dir>" >&2
    exit 1
fi

BASE="$1"
OUTPUT="$2"

if [ ! -f "$BASE/build_info.txt" ]; then
    LOGE "Not a target-files directory: ${BASE//$SRC_DIR\//}"
    exit 1
fi
if [ ! -d "$WORK_DIR/kernel" ] || [ ! -f "$WORK_DIR/kernel/boot.img" ]; then
    LOGE "No kernel images in ${WORK_DIR//$SRC_DIR\//}/kernel"
    exit 1
fi

TIMESTAMP="$(date +%s)"
BASE_TIMESTAMP="$(sed -n "s/^timestamp=//p" "$BASE/build_info.txt" | head -n 1)"
if [ ! "$BASE_TIMESTAMP" ] || [ "$TIMESTAMP" -le "$BASE_TIMESTAMP" ]; then
    LOGE "The clock is behind the base build (timestamp ${BASE_TIMESTAMP:-none})"
    exit 1
fi

LOG "- Linking the base target files"
rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
EVAL "cp -al \"$BASE\" \"$OUTPUT\"" || exit 1

while IFS= read -r f; do
    f="$(basename "$f")"

    LOG_STEP_IN "- Replacing $f"
    # Break the hard link before writing: the base must stay intact.
    rm -f "$OUTPUT/$f"
    EVAL "cp \"$WORK_DIR/kernel/$f\" \"$OUTPUT/$f\"" || exit 1
    if [[ "$f" == "boot.img" ]]; then
        if avbtool info_image --image "$OUTPUT/$f" &> /dev/null; then
            EVAL "avbtool erase_footer --image \"$OUTPUT/$f\"" || exit 1
        fi
        EVAL "python3 \"$SRC_DIR/scripts/internal/stamp_boot_bootargs.py\" \"$OUTPUT/$f\" unica.timestamp=$TIMESTAMP" || exit 1
    fi
    if ! $TARGET_DISABLE_AVB_SIGNING; then
        SIGN_IMAGE_WITH_AVB "$OUTPUT/$f" || exit 1
    fi
    LOG_STEP_OUT
done < <(find "$WORK_DIR/kernel" -maxdepth 1 -type f -name "*.img" | sort)

COMMIT="$(git -C "$SRC_DIR" rev-parse --short=8 HEAD 2> /dev/null || true)"
[ "$COMMIT" ] && [ "$(git -C "$SRC_DIR" status --porcelain 2> /dev/null)" ] && COMMIT+="-dirty"

LOG "- Generating build_info.txt"
rm -f "$OUTPUT/build_info.txt"
# system_timestamp: ro.unica.timestamp of the system partition, which a
# chain of kernel-only updates keeps (make_rom.sh -k compares the work dir
# against it).
SYSTEM_TIMESTAMP="$(sed -n "s/^system_timestamp=//p" "$BASE/build_info.txt" | head -n 1)"
sed -e "s/^timestamp=.*/timestamp=$TIMESTAMP/" \
    -e "s/^commit=.*/commit=${COMMIT:-unknown}/" \
    -e "/^kernel_only=/d" -e "/^system_timestamp=/d" \
    "$BASE/build_info.txt" > "$OUTPUT/build_info.txt"
echo "kernel_only=true" >> "$OUTPUT/build_info.txt"
echo "system_timestamp=${SYSTEM_TIMESTAMP:-$BASE_TIMESTAMP}" >> "$OUTPUT/build_info.txt"

exit 0
