#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

# Build an all-ext4 M21s ROM from the already prepared work_dir and create a
# matching GPT repartitioner. The target now defaults to ext4; this helper is
# still useful when the ext4 image sizes require recalculating super.

set -euo pipefail

: "${SRC_DIR:?Source buildenv.sh m21s before running this script}"
: "${WORK_DIR:?Source buildenv.sh m21s before running this script}"

[ "${TARGET_CODENAME:-}" = "m21s" ] || {
    printf '%s\n' 'This script must be run with target m21s.' >&2
    exit 1
}
[ -d "$WORK_DIR" ] || {
    printf '%s\n' "Missing work_dir: $WORK_DIR" >&2
    exit 1
}

MIB=$((1024 * 1024))
SUPER_MARGIN_MIB="${M21S_EXT4_SUPER_MARGIN_MIB:-256}"
case "$SUPER_MARGIN_MIB" in
    ''|*[!0-9]*) printf '%s\n' 'M21S_EXT4_SUPER_MARGIN_MIB must be an integer' >&2; exit 1 ;;
esac

calc_ext4_upper_bound() {
    local DIR="$1"
    local TREE_KIB TREE_BYTES RESERVED
    TREE_KIB="$(du -b -k -s "$DIR" | cut -f 1)"
    TREE_BYTES=$((TREE_KIB * 1024))
    # Same first-pass reservation used by build_fs_image.sh for ext4. The
    # extra margin covers AVB metadata and mkfs rounding.
    RESERVED=$(( (TREE_BYTES * 11) / 10 + 16777216 ))
    printf '%s\n' "$(( (RESERVED + 4095) / 4096 * 4096 ))"
}

TOTAL=0
DETAILS=""
for PARTITION in system vendor product odm; do
    DIR="$WORK_DIR/$PARTITION"
    [ -d "$DIR" ] || continue
    IMAGE_SIZE="$(calc_ext4_upper_bound "$DIR")"
    TOTAL=$((TOTAL + IMAGE_SIZE))
    DETAILS+="$PARTITION=$IMAGE_SIZE\n"
done
[ "$TOTAL" -gt 0 ] || {
    printf '%s\n' 'No OS partition trees were found in work_dir.' >&2
    exit 1
}

# lpmake and the recovery GPT script use whole MiB values. Keep a conservative
# margin above the ext4 first-pass upper bound, then leave 4 MiB for super
# metadata/geometry as in the existing repartitioner.
GROUP_MIB=$(( (TOTAL + MIB - 1) / MIB + SUPER_MARGIN_MIB ))
SUPER_MIB=$((GROUP_MIB + 4))
GROUP_BYTES=$((GROUP_MIB * MIB))
SUPER_BYTES=$((SUPER_MIB * MIB))

OUT_TARGET="$OUT_DIR/target/m21s"
mkdir -p "$OUT_TARGET"
LAYOUT_FILE="$OUT_TARGET/m21s-ext4-layout.env"
{
    printf 'M21S_EXT4_FS_TYPE=ext4\n'
    printf 'M21S_EXT4_GROUP_MIB=%s\n' "$GROUP_MIB"
    printf 'M21S_EXT4_SUPER_MIB=%s\n' "$SUPER_MIB"
    printf 'M21S_EXT4_GROUP_BYTES=%s\n' "$GROUP_BYTES"
    printf 'M21S_EXT4_SUPER_BYTES=%s\n' "$SUPER_BYTES"
    printf 'M21S_EXT4_IMAGE_UPPER_BOUND_BYTES=%s\n' "$TOTAL"
    printf '%b' "$DETAILS"
} > "$LAYOUT_FILE"

REPARTITIONER="$OUT_TARGET/m21s-repartitioner-ext4-experimental.zip"
"$SRC_DIR/platform/exynos9611/installer/repartitioner_m21s/build.sh" \
    "$REPARTITIONER" "$SUPER_MIB"

printf 'Ext4 layout: group=%s MiB, super=%s MiB, image upper bound=%s bytes\n' \
    "$GROUP_MIB" "$SUPER_MIB" "$TOTAL"
printf 'Layout manifest: %s\n' "$LAYOUT_FILE"
printf 'Repartitioner: %s\n' "$REPARTITIONER"

if [ "${M21S_EXT4_LAYOUT_ONLY:-false}" = "true" ]; then
    printf '%s\n' 'Layout-only mode requested; ROM packaging skipped.'
    exit 0
fi

# Keep the exported values explicit for callers that source an older target
# environment before invoking this helper.
export TARGET_OS_FILE_SYSTEM_TYPE="ext4"
export TARGET_GROUP_BASIC_SIZE="$GROUP_BYTES"
export TARGET_SUPER_PARTITION_SIZE="$SUPER_BYTES"
"$SRC_DIR/scripts/internal/build_flashable_zip.sh"
