#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

# DressRoom's One UI 9 object-capture path expects an ArcSoft pipeline that
# the F415F/M21s vendor does not provide. Keep this target-only patch separate
# from the generic wallpaper catalogue merge.
APPLY_PATCH "system" "system/priv-app/DressRoom/DressRoom.apk" \
    "$MODPATH/DressRoom.apk/0001-Disable-unsupported-object-capture-on-target.patch" || return 1
