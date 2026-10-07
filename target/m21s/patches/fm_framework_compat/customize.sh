#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

# Vendor init files, accounts, properties and ueventd are applied by the
# consolidated target/m21s/mods/vendor module. Keep the system framework
# contract in this system compatibility module.
LOG "- Restoring the F415F FM JNI framework contract"
APPLY_PATCH "system" "system/framework/framework.jar" \
    "$MODPATH/patches/system/framework/framework.jar/0001-Restore-F415F-FM-checkBaseFreq-JNI-contract.patch" || return 1

# Keep the source media-codec-list generator and its init declaration. The
# matching S24+ source firmware contains both files and the M21s target uses
# the same Android 17 framework contract.
LOG "- Keeping the Android 17 media codec-list generator"
