#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

# The vendor fstab is normalized by target/m21s/mods/vendor. This module owns
# only the matching system init rule, which belongs to /system.
INIT_RC="$WORK_DIR/system/system/etc/init/hw/init.rc"
DATA_RULE="mkdir /data/data 0771 system system encryption=None"
[ -f "$INIT_RC" ] || {
    ABORT "M21s Android init file is missing: ${INIT_RC//$WORK_DIR\//}"
    return 1
}
if grep -q -F -x "    $DATA_RULE" "$INIT_RC"; then
    sed -i "\|^    $DATA_RULE$|d" "$INIT_RC"
fi
if grep -q -F -x "    $DATA_RULE" "$INIT_RC"; then
    ABORT "Failed to remove incompatible unencrypted /data initialization rule"
    return 1
fi
unset INIT_RC DATA_RULE
