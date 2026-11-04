#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stamps the source commit into the system image.  make_rom.sh runs this on
# every build, after the work dir is created or reused: the work dir is only
# rebuilt when the source contents change, so a commit made afterwards (or
# changes that became committed) must still reach the image.
#
#   ro.unica.commit         8-digit commit, "-dirty" when the tree had changes
#   ro.unica.fingerprint    rebuilt with that commit as its build ID
#   /system/etc/unica_build_info.txt
#                           full commit, branch, subject and the list of files
#                           that differed from the commit, for bug reports

# [
source "$SRC_DIR/scripts/utils/build_utils.sh" || exit 1

ADD_PROPERTY_CONTEXT()
{
    local CONTEXTS="$WORK_DIR/system/system/etc/selinux/plat_property_contexts"

    grep -q "^$1 " "$CONTEXTS" 2> /dev/null || \
        echo "$1 u:object_r:build_prop:s0 exact string" >> "$CONTEXTS"
}
# ]

if [ ! -d "$WORK_DIR/system/system" ]; then
    LOGE "Work dir has no system partition: ${WORK_DIR//$SRC_DIR\//}"
    exit 1
fi

COMMIT="$(git -C "$SRC_DIR" rev-parse --short=8 HEAD 2> /dev/null)"
if [ ! "$COMMIT" ]; then
    LOGW "Source tree is not a git checkout; ro.unica.commit is not set"
    exit 0
fi

# Ignored build outputs (out/, .build/) do not count as changes.
CHANGES="$(git -C "$SRC_DIR" status --porcelain 2> /dev/null)"
ROM_COMMIT="$COMMIT"
[ "$CHANGES" ] && ROM_COMMIT+="-dirty"

SET_PROP "system" "ro.unica.commit" "$ROM_COMMIT"
ADD_PROPERTY_CONTEXT "ro.unica.commit"

# unica/<device>:<MAJOR.MINOR.PATCH>/<commit><.dirty>/<timestamp>:<user|userdebug>/<release|test>-keys
FINGERPRINT="unica/${TARGET_CODENAME}:"
FINGERPRINT+="$(grep -o "^[0-9]\+\.[0-9]\+\.[0-9]\+" <<< "$ROM_VERSION")/"
FINGERPRINT+="${COMMIT}"
[ "$CHANGES" ] && FINGERPRINT+=".dirty"
FINGERPRINT+="/$(GET_PROP "system" "ro.unica.timestamp"):"
$DEBUG && FINGERPRINT+="userdebug/" || FINGERPRINT+="user/"
$ROM_IS_OFFICIAL && FINGERPRINT+="release-keys" || FINGERPRINT+="test-keys"
SET_PROP "system" "ro.unica.fingerprint" "$FINGERPRINT"
ADD_PROPERTY_CONTEXT "ro.unica.fingerprint"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/system/system/etc"
{
    echo "version=$ROM_VERSION ($ROM_CODENAME)"
    echo "device=$TARGET_CODENAME"
    echo "commit=$(git -C "$SRC_DIR" rev-parse HEAD)"
    echo "branch=$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD)"
    echo "commit_date=$(git -C "$SRC_DIR" log -1 --format=%cI)"
    echo "subject=$(git -C "$SRC_DIR" log -1 --format=%s)"
    echo "build_date=$(date -d "@$(GET_PROP "system" "ro.unica.timestamp")" --iso-8601=seconds 2> /dev/null)"
    if [ "$CHANGES" ]; then
        echo "dirty=true"
        echo
        echo "# Files that differed from the commit (git status --porcelain)"
        echo "$CHANGES"
        echo
        echo "# Tracked changes (git diff --stat HEAD)"
        git -C "$SRC_DIR" diff --stat HEAD 2> /dev/null | tail -n 200
    else
        echo "dirty=false"
    fi
} > "$STAGE/system/system/etc/unica_build_info.txt"
ADD_TO_WORK_DIR "$STAGE" "system" "system/etc/unica_build_info.txt" \
    0 0 644 "u:object_r:system_file:s0" > /dev/null || exit 1

LOG "- Build commit: $ROM_COMMIT"

exit 0
