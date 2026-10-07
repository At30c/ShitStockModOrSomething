#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

# All M21s vendor mutations live in this module. System/APEX/framework changes
# stay in their feature modules; this file owns only /vendor files, vendor
# properties, VINTF declarations, SELinux vendor metadata and vendor firmware.
LOG_STEP_IN "- Applying the consolidated M21s vendor compatibility module"

# -----------------------------------------------------------------------------
# Camera/vendor floating features
# -----------------------------------------------------------------------------
VENDOR_FLOATING_FEATURE="$WORK_DIR/vendor/etc/floating_feature.xml"
if [ -f "$VENDOR_FLOATING_FEATURE" ]; then
    if grep -q '<SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>' "$VENDOR_FLOATING_FEATURE"; then
        EVAL "sed -i -E 's#(<SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>)[^<]*(</SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>)#\\10\\2#' '$VENDOR_FLOATING_FEATURE'"
    else
        EVAL "sed -i '/<\\/SecFloatingFeatureSet>/i\\    <SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>0<\\/SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>' '$VENDOR_FLOATING_FEATURE'"
    fi
    grep -q '<SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>0</SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE>' "$VENDOR_FLOATING_FEATURE" || {
        ABORT "Could not publish camera resolution policy in vendor floating_feature.xml"
        return 1
    }
else
    LOGW "M21s vendor floating_feature.xml is missing; runtime TWRP patch is required"
fi

# -----------------------------------------------------------------------------
# Audio HIDL 6.0 and secondary policy
# -----------------------------------------------------------------------------
AUDIO_MANIFEST="$WORK_DIR/vendor/etc/vintf/manifest.xml"
[ -f "$AUDIO_MANIFEST" ] || {
    ABORT "M21s vendor VINTF manifest is missing"
    return 1
}
for AUDIO_FILE in \
    "$WORK_DIR/vendor/lib64/hw/android.hardware.audio@6.0-impl.so" \
    "$WORK_DIR/vendor/lib64/hw/android.hardware.audio.effect@6.0-impl.so"; do
    [ -f "$AUDIO_FILE" ] || {
        ABORT "M21s stock HIDL 6.0 audio implementation is missing: ${AUDIO_FILE#$WORK_DIR/vendor/}"
        return 1
    }
done
for WIFI_UDI_TOOL in bin/slsi_wlan_udi_log bin/slsi_wlan_udi_log_decode; do
    if [ -e "$WORK_DIR/vendor/$WIFI_UDI_TOOL" ]; then
        DELETE_FROM_WORK_DIR "vendor" "$WIFI_UDI_TOOL" || return 1
    fi
done

AUDIO_SEC_POLICY="$WORK_DIR/vendor/etc/audio_policy_configuration_sec.xml"
if [ -f "$AUDIO_SEC_POLICY" ]; then
    if ! [ -f "$WORK_DIR/vendor/etc/playback_record_audio_policy_configuration.xml" ]; then
        EVAL "sed -i '/playback_record_audio_policy_configuration\\.xml/d' '$AUDIO_SEC_POLICY'"
    fi
    for AUDIO_POLICY_FRAGMENT in \
        a2dp_audio_policy_configuration.xml \
        hearing_aid_audio_policy_configuration.xml \
        r_submix_audio_policy_configuration.xml \
        usb_audio_policy_configuration.xml; do
        [ -f "$WORK_DIR/vendor/etc/$AUDIO_POLICY_FRAGMENT" ] || {
            ABORT "M21s secondary audio policy include is missing: $AUDIO_POLICY_FRAGMENT"
            return 1
        }
    done
    for AUDIO_VOLUME_TABLE in audio_policy_volumes.xml default_volume_tables.xml; do
        [ -f "$WORK_DIR/vendor/etc/$AUDIO_VOLUME_TABLE" ] || {
            ABORT "M21s volume policy table is missing: $AUDIO_VOLUME_TABLE"
            return 1
        }
        grep -q -F "<xi:include href=\"$AUDIO_VOLUME_TABLE\"/>" "$AUDIO_SEC_POLICY" || \
            EVAL "sed -i '/<\\/audioPolicyConfiguration>/i\\    <xi:include href=\"$AUDIO_VOLUME_TABLE\"/>' '$AUDIO_SEC_POLICY'" || return 1
    done
    python3 "$MODPATH/force_m21s_primary_output.py" "$AUDIO_SEC_POLICY" || return 1
fi
grep -q -F '<fqname>@5.0::IDevicesFactory/default</fqname>' "$AUDIO_MANIFEST" || {
    ABORT "M21s vendor VINTF has no HIDL 5.0 audio factory to upgrade"
    return 1
}
grep -q -F '<fqname>@5.0::IEffectsFactory/default</fqname>' "$AUDIO_MANIFEST" || {
    ABORT "M21s vendor VINTF has no HIDL 5.0 audio-effects factory to upgrade"
    return 1
}
EVAL "sed -i \
    -e '/<name>android.hardware.audio<\\/name>/,/<\\/hal>/ { \
        s#<version>5.0</version>#<version>6.0</version>#; \
        s#@5.0::IDevicesFactory/default#@6.0::IDevicesFactory/default#; \
    }' \
    -e '/<name>android.hardware.audio.effect<\\/name>/,/<\\/hal>/ { \
        s#<version>5.0</version>#<version>6.0</version>#; \
        s#@5.0::IEffectsFactory/default#@6.0::IEffectsFactory/default#; \
    }' \
    '$AUDIO_MANIFEST'" || return 1
grep -q -F '<fqname>@6.0::IDevicesFactory/default</fqname>' "$AUDIO_MANIFEST" || {
    ABORT "Could not declare the M21s HIDL 6.0 audio factory"
    return 1
}
grep -q -F '<fqname>@6.0::IEffectsFactory/default</fqname>' "$AUDIO_MANIFEST" || {
    ABORT "Could not declare the M21s HIDL 6.0 audio-effects factory"
    return 1
}

# -----------------------------------------------------------------------------
# Android 17 FBE userdata contract
# -----------------------------------------------------------------------------
FSTAB="$WORK_DIR/vendor/etc/fstab.exynos9611"
[ -s "$FSTAB" ] || {
    ABORT "M21s vendor fstab is missing or empty: ${FSTAB//$WORK_DIR\//}"
    return 1
}
grep -q '^/dev/block/by-name/userdata[[:space:]]' "$FSTAB" || {
    ABORT "M21s fstab has no userdata entry"
    return 1
}
if grep '^/dev/block/by-name/userdata[[:space:]]' "$FSTAB" | grep -q 'fileencryption=ice'; then
    LOG "  - Converting M21s userdata from the legacy ICE alias to AES-256 FBE v1"
    sed -i '/^\/dev\/block\/by-name\/userdata[[:space:]]/s#fileencryption=ice#fileencryption=aes-256-xts:aes-256-cts:v1#' "$FSTAB"
fi
if ! grep '^/dev/block/by-name/userdata[[:space:]]' "$FSTAB" | grep -q 'fileencryption=aes-256-xts:aes-256-cts:v1'; then
    ABORT "M21s userdata fstab entry must use the Android 17-compatible AES-256 FBE v1 policy"
    return 1
fi

# -----------------------------------------------------------------------------
# Codec2 vendor seccomp policy
# -----------------------------------------------------------------------------
if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 36 ]]; then
    CODEC2_POLICY="$WORK_DIR/vendor/etc/seccomp_policy/samsung.software.media.c2-base-policy"
    if [ -f "$CODEC2_POLICY" ]; then
        CODEC2_OLD_RULE="mremap: arg3 == 3"
        CODEC2_NEW_RULE="mremap: arg3 == 3 || arg3 == MREMAP_MAYMOVE"
        if grep -q -F -x "$CODEC2_OLD_RULE" "$CODEC2_POLICY" && ! grep -q -F -x "$CODEC2_NEW_RULE" "$CODEC2_POLICY"; then
            EVAL "sed -i 's/^mremap: arg3 == 3$/mremap: arg3 == 3 || arg3 == MREMAP_MAYMOVE/' \"$CODEC2_POLICY\""
        fi
        for CODEC2_SYSCALL_RULE in "setsockopt: 1" "listen: 1" "bind: 1"; do
            if ! grep -q -F -x "$CODEC2_SYSCALL_RULE" "$CODEC2_POLICY" && grep -q -F -x "prctl: 1" "$CODEC2_POLICY"; then
                EVAL "sed -i '/^prctl: 1$/i$CODEC2_SYSCALL_RULE' \"$CODEC2_POLICY\""
            fi
        done
    else
        LOGW "- Codec2 seccomp policy is absent on the M21s target; skipping vendor rule update"
    fi
fi

# -----------------------------------------------------------------------------
# S20+ sysinput HIDL 1.3 vendor chain
# -----------------------------------------------------------------------------
SYSINPUT_DONOR="y2sxxx"
SYSINPUT_ROOT="$SRC_DIR/prebuilts/samsung/$SYSINPUT_DONOR"
SYSINPUT_MANIFEST="$SYSINPUT_ROOT/vendor/etc/vintf/sysinput-hidl-1.3.xml"
SYSINPUT_SERVICE="$SYSINPUT_ROOT/vendor/bin/hw/vendor.samsung.hardware.sysinput@1.3-service"
SYSINPUT_RC="$SYSINPUT_ROOT/vendor/etc/init/vendor.samsung.hardware.sysinput@1.3-service.rc"
for SYSINPUT_FILE in "$SYSINPUT_MANIFEST" "$SYSINPUT_SERVICE" "$SYSINPUT_RC"; do
    [ -f "$SYSINPUT_FILE" ] || {
        ABORT "S20+ sysinput prebuilt is incomplete: ${SYSINPUT_FILE#$SYSINPUT_ROOT/}"
        return 1
    }
done
for SYSINPUT_VERSION in 1.0 1.1 1.2 1.3; do
    SYSINPUT_LIB="$SYSINPUT_ROOT/vendor/lib64/vendor.samsung.hardware.sysinput@${SYSINPUT_VERSION}.so"
    [ -f "$SYSINPUT_LIB" ] || {
        ABORT "S20+ sysinput prebuilt dependency is missing: vendor/lib64/vendor.samsung.hardware.sysinput@${SYSINPUT_VERSION}.so"
        return 1
    }
done
if [ -f "$WORK_DIR/vendor/bin/hw/vendor.samsung.hardware.sysinput@1.2-service" ]; then
    DELETE_FROM_WORK_DIR "vendor" "bin/hw/vendor.samsung.hardware.sysinput@1.2-service" || return 1
fi
if [ -f "$WORK_DIR/vendor/etc/init/vendor.samsung.hardware.sysinput@1.2-service.rc" ]; then
    DELETE_FROM_WORK_DIR "vendor" "etc/init/vendor.samsung.hardware.sysinput@1.2-service.rc" || return 1
fi
ADD_TO_WORK_DIR "$SYSINPUT_DONOR" "vendor" "bin/hw/vendor.samsung.hardware.sysinput@1.3-service" 0 2000 755 "u:object_r:hal_sec_inputdev_default_exec:s0" || return 1
ADD_TO_WORK_DIR "$SYSINPUT_DONOR" "vendor" "etc/init/vendor.samsung.hardware.sysinput@1.3-service.rc" 0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
for SYSINPUT_VERSION in 1.0 1.1 1.2 1.3; do
    ADD_TO_WORK_DIR "$SYSINPUT_DONOR" "vendor" "lib64/vendor.samsung.hardware.sysinput@${SYSINPUT_VERSION}.so" 0 0 644 "u:object_r:vendor_file:s0" || return 1
done
python3 - "$WORK_DIR/vendor/etc/vintf/manifest.xml" "$SYSINPUT_MANIFEST" <<'PY'
import re
import sys
from pathlib import Path

target = Path(sys.argv[1])
donor = Path(sys.argv[2])
pattern = re.compile(r'    <hal format="hidl">\s*<name>vendor\.samsung\.hardware\.sysinput</name>.*?    </hal>\s*', re.S)
target_text = target.read_text()
donor_text = donor.read_text()
match = pattern.search(donor_text)
if not match:
    raise SystemExit("S20+ manifest has no sysinput HIDL block")
if not pattern.search(target_text):
    raise SystemExit("M21s manifest has no sysinput HIDL block")
target.write_text(pattern.sub(match.group(0), target_text, count=1))
PY
if ! grep -q 'hal_sec_inputdev_default_exec' "$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"; then
    ABORT "M21s SELinux file context for sysinput service is missing"
    return 1
fi
if ! grep -q 'vendor\.samsung\.hardware\.sysinput::ISehSysInputDev' "$WORK_DIR/vendor/etc/selinux/vendor_hwservice_contexts"; then
    ABORT "M21s SELinux hwservice context for sysinput is missing"
    return 1
fi

# -----------------------------------------------------------------------------
# TEEgris init and Keymaster readiness
# -----------------------------------------------------------------------------
TEEGRIS_RC="$WORK_DIR/vendor/etc/init/teegris_v3.rc"
TEEGRIS_PATCH="$MODPATH/patches/vendor/etc/init/teegris_v3.rc/0001-Allow-boot-when-tzdev-unavailable.patch"
TEEGRIS_TZDEV_PATCH="$MODPATH/patches/vendor/etc/init/teegris_v3.rc/0002-Prepare-tzdev-before-starting-TEEgris.patch"
TEEGRIS_IWD_PATCH="$MODPATH/patches/vendor/etc/init/teegris_v3.rc/0003-Prepare-TEEgris-IWD-device-nodes.patch"
TEEGRIS_KEYSTORE_PATCH="$MODPATH/patches/vendor/etc/init/teegris_v3.rc/0004-Restart-Keymaster-and-Keystore-after-TEE-ready.patch"
TEEGRIS_TZTS_PATCH="$MODPATH/patches/vendor/etc/init/teegris_v3.rc/0005-Wait-for-TZTS-before-restarting-Keymaster.patch"
TEEGRIS_ORDER_PATCH="$MODPATH/patches/vendor/etc/init/teegris_v3.rc/0006-Restore-ordered-TEEgris-startup.patch"
if [ -f "$TEEGRIS_RC" ]; then
    M21S_VENDOR_APPLY_PATCH() {
        local patch="$1"
        if git -C "$WORK_DIR/vendor" apply --reverse --check --unsafe-paths "$patch" >/dev/null 2>&1; then
            return 0
        elif git -C "$WORK_DIR/vendor" apply --check --unsafe-paths "$patch" >/dev/null 2>&1; then
            EVAL "LC_ALL=C git apply --directory=\"$WORK_DIR/vendor\" --unsafe-paths \"$patch\""
        else
            ABORT "M21s vendor patch does not apply: $(basename "$patch")"
            return 1
        fi
    }
    for TEEGRIS_PATCH_FILE in "$TEEGRIS_PATCH" "$TEEGRIS_TZDEV_PATCH" "$TEEGRIS_IWD_PATCH" "$TEEGRIS_KEYSTORE_PATCH" "$TEEGRIS_TZTS_PATCH" "$TEEGRIS_ORDER_PATCH"; do
        M21S_VENDOR_APPLY_PATCH "$TEEGRIS_PATCH_FILE" || return 1
    done
    SET_METADATA vendor etc/init/teegris_v3.rc 0 0 644 u:object_r:vendor_configs_file:s0 || return 1
    unset -f M21S_VENDOR_APPLY_PATCH
fi

# -----------------------------------------------------------------------------
# Vendor boot compatibility: init files, accounts, properties, ueventd
# -----------------------------------------------------------------------------
RECOVERY_INIT="$WORK_DIR/vendor/etc/init/init.recovery.exynos9611.rc"
BASEBAND_INIT="$WORK_DIR/vendor/etc/init/init.baseband.rc"
VENDOR_PASSWD="$WORK_DIR/vendor/etc/passwd"
VENDOR_GROUP="$WORK_DIR/vendor/etc/group"
LEGACY_UEVENTD="$WORK_DIR/vendor/ueventd.rc"
VENDOR_UEVENTD="$WORK_DIR/vendor/etc/ueventd.rc"
[ -f "$RECOVERY_INIT" ] || { ABORT "File not found: vendor/etc/init/init.recovery.exynos9611.rc"; return 1; }
[ -f "$BASEBAND_INIT" ] || { ABORT "File not found: vendor/etc/init/init.baseband.rc"; return 1; }
[ -f "$VENDOR_PASSWD" ] || { ABORT "File not found: vendor/etc/passwd"; return 1; }
[ -f "$VENDOR_GROUP" ] || { ABORT "File not found: vendor/etc/group"; return 1; }
M21S_VENDOR_APPLY_TEXT_PATCH() {
    local patch="$1"
    if git -C "$WORK_DIR/vendor" apply --reverse --check --unsafe-paths "$patch" >/dev/null 2>&1; then
        return 0
    fi
    EVAL "LC_ALL=C git apply --directory=\"$WORK_DIR/vendor\" --unsafe-paths \"$patch\""
}
M21S_VENDOR_APPLY_TEXT_PATCH "$MODPATH/patches/vendor/etc/init/init.recovery.exynos9611.rc/0001-Gate-recovery-only-events.patch" || return 1
M21S_VENDOR_APPLY_TEXT_PATCH "$MODPATH/patches/vendor/etc/init/init.baseband.rc/0001-Drop-unexported-clatd-property-triggers.patch" || return 1
if ! grep -q '^vendor_dsms:' "$VENDOR_PASSWD"; then printf '%s\n' 'vendor_dsms::5031:5031::/:/bin/sh' >> "$VENDOR_PASSWD"; fi
if ! grep -q '^vendor_ker:' "$VENDOR_PASSWD"; then printf '%s\n' 'vendor_ker::5554:5554::/:/bin/sh' >> "$VENDOR_PASSWD"; fi
if ! grep -q '^vendor_dsms:' "$VENDOR_GROUP"; then printf '%s\n' 'vendor_dsms::5031:' >> "$VENDOR_GROUP"; fi
if ! grep -q '^vendor_ker:' "$VENDOR_GROUP"; then printf '%s\n' 'vendor_ker::5554:' >> "$VENDOR_GROUP"; fi
SET_METADATA vendor etc/passwd 0 0 644 u:object_r:vendor_configs_file:s0 || return 1
SET_METADATA vendor etc/group 0 0 644 u:object_r:vendor_configs_file:s0 || return 1
SET_PROP vendor net.dns1 --delete || return 1
SET_PROP vendor net.dns2 --delete || return 1
SET_PROP vendor ro.vendor.api_level 31 || return 1
if [ -f "$LEGACY_UEVENTD" ]; then
    cp -a "$LEGACY_UEVENTD" "$VENDOR_UEVENTD" || return 1
    SET_METADATA vendor etc/ueventd.rc 0 0 644 u:object_r:vendor_configs_file:s0 || return 1
    DELETE_FROM_WORK_DIR vendor ueventd.rc || return 1
elif [ ! -f "$VENDOR_UEVENTD" ]; then
    ABORT "Target vendor has no ueventd.rc to migrate"
    return 1
fi
unset -f M21S_VENDOR_APPLY_TEXT_PATCH

# -----------------------------------------------------------------------------
# F41 sensorhub firmware staged by the kernel module
# -----------------------------------------------------------------------------
STOCK_DTBO_IMAGE="$WORK_DIR/kernel/dtbo.img"
SENSORHUB_FIRMWARE="$OUT_DIR/kernel_tmp-exynos9611/firmware/sensorhub/shub_ramen_m31.fw"
[ -s "$STOCK_DTBO_IMAGE" ] || { ABORT "Target firmware did not provide kernel/dtbo.img"; return 1; }
[ -s "$SENSORHUB_FIRMWARE" ] || { ABORT "Pinned kernel source does not provide the F41 M31 sensorhub firmware"; return 1; }
grep -aFq 'sensorhub/shub_ramen_m31.fw' "$STOCK_DTBO_IMAGE" || {
    ABORT "F41 DTBO does not request the expected M31 sensorhub firmware"
    return 1
}
mkdir -p "$WORK_DIR/vendor/firmware/sensorhub" || return 1
cp -f "$SENSORHUB_FIRMWARE" "$WORK_DIR/vendor/firmware/sensorhub/shub_ramen_m31.fw" || return 1
cmp -s "$SENSORHUB_FIRMWARE" "$WORK_DIR/vendor/firmware/sensorhub/shub_ramen_m31.fw" || {
    ABORT "Staged M31 sensorhub firmware does not match pinned kernel source"
    return 1
}
SET_METADATA vendor firmware/sensorhub 0 0 755 u:object_r:vendor_fw_file:s0 || return 1
SET_METADATA vendor firmware/sensorhub/shub_ramen_m31.fw 0 0 644 u:object_r:vendor_fw_file:s0 || return 1

LOG_STEP_OUT
unset VENDOR_FLOATING_FEATURE AUDIO_MANIFEST AUDIO_FILE AUDIO_SEC_POLICY AUDIO_POLICY_FRAGMENT AUDIO_VOLUME_TABLE WIFI_UDI_TOOL
unset FSTAB CODEC2_POLICY CODEC2_OLD_RULE CODEC2_NEW_RULE CODEC2_SYSCALL_RULE
unset SYSINPUT_DONOR SYSINPUT_ROOT SYSINPUT_MANIFEST SYSINPUT_SERVICE SYSINPUT_RC SYSINPUT_FILE SYSINPUT_VERSION SYSINPUT_LIB
unset TEEGRIS_RC TEEGRIS_PATCH TEEGRIS_TZDEV_PATCH TEEGRIS_IWD_PATCH TEEGRIS_KEYSTORE_PATCH TEEGRIS_TZTS_PATCH TEEGRIS_ORDER_PATCH TEEGRIS_PATCH_FILE
unset RECOVERY_INIT BASEBAND_INIT VENDOR_PASSWD VENDOR_GROUP LEGACY_UEVENTD VENDOR_UEVENTD
unset STOCK_DTBO_IMAGE SENSORHUB_FIRMWARE
