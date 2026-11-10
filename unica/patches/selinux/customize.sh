# UN1CA SELinux entries removal list
# - Append new type entries to the ENTRIES list
# - Add the EXACT type entry, DO NOT just add a common pattern (eg. "fabriccrypto", "fabriccrypto_exec" and NOT just "fabriccrypto")
# - DO NOT add the API version at the end of the entry (eg. "fabriccrypto" and NOT "fabriccrypto_30_0")
# - DO NOT add any parenthesis or statements (eg. "fabriccrypto" and NOT "expanttypeattribute ... (fabriccrypto)")
# - DO NOT add unnecessary types or remove the existing ones unless they aren't necessary anymore for all devices

# One UI 8.0 additions
ENTRIES+="
heatmap_default
heatmap_default_exec
"

# The S24+ system_ext mapping contains these API-31 compatibility attributes,
# but the M21s/F415F vendor policy does not publish them. Keeping their
# expandtypeattribute/typeattributeset pairs makes Android 17's secilc abort
# during first-stage SELinux policy compilation. They are not required by the
# target vendor policy, so remove the aliases through the normal compatibility
# mapping cleanup below.
if [[ "$TARGET_CODENAME" == "m21s" ]]; then
    ENTRIES+="
perf_prop
qb_id_prop
"
fi

DUPLICATES+="
init.svc.vendor.wvkprov_server_hal
"

# One UI 7.0 additions
ENTRIES+="
attiqi_app
attiqi_app_data_file
ker_app
kpp_app
kpp_data_file
"

# One UI 6.1.1 additions
ENTRIES+="
hal_dsms_default
hal_dsms_default_exec
proc_compaction_proactiveness
sbauth
sbauth_exec
"

# One UI 5.1.1 additions
ENTRIES+="
audiomirroring
audiomirroring_exec
audiomirroring_service
fabriccrypto
fabriccrypto_exec
fabriccrypto_data_file
hal_dsms_service
uwb_regulation_skip_prop
"

# [
GET_SYSTEM_EXT()
{
    if $TARGET_OS_BUILD_SYSTEM_EXT_PARTITION; then
        echo "system_ext"
    else
        echo "system/system/system_ext"
    fi
}

CIL_NAME="$(head -n 1 "$WORK_DIR/vendor/etc/selinux/plat_sepolicy_vers.txt")"
PATCHED=false
SYSTEM_EXT_SELINUX="$WORK_DIR/$(GET_SYSTEM_EXT)/etc/selinux"
VENDOR_SEPOLICY="$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"

# The One UI 9 SystemUI used by the Exynos 990 targets updates
# sys.locksecured when Keyguard changes state.  The generic `sys.` entry from
# the platform labels it as system_prop, which platform_app_36 cannot set and
# makes SystemUI crash in a loop.  Use the existing Samsung aod_prop instead:
# it is already explicitly writable by the SystemUI domain and gives this one
# exact boolean property its intended, narrow label.
#
# StorageNotification also opens the kernel uevent socket.  This SystemUI is
# labelled platform_app_36 on these targets, while its source policy omitted
# the matching socket grant.  Add only the four operations used by
# UEventObserver; do not grant write, connect or send permissions.
if [[ "$TARGET_PLATFORM" == "exynos990" ]]; then
    LOCKSECURED_PROPERTY_CONTEXT="sys.locksecured u:object_r:aod_prop:s0 exact bool"
    if ! grep -qE '^sys\.locksecured[[:space:]]' "$SYSTEM_EXT_SELINUX/system_ext_property_contexts"; then
        printf '%s\n' "$LOCKSECURED_PROPERTY_CONTEXT" >> "$SYSTEM_EXT_SELINUX/system_ext_property_contexts"
        PATCHED=true
    fi

    # TileServices also records its lazy-boot state from SystemUI.  On this
    # mixed Android 17 framework the generic sys.* fallback labels it as
    # system_prop, which platform_app_36 cannot set.  Keep the exact boolean
    # beside sys.locksecured in the existing SystemUI-writable aod_prop type.
    TILE_LAZY_BOOTED_PROPERTY_CONTEXT="sys.tile.lazy_booted u:object_r:aod_prop:s0 exact bool"
    if ! grep -qE '^sys\.tile\.lazy_booted[[:space:]]' "$SYSTEM_EXT_SELINUX/system_ext_property_contexts"; then
        printf '%s\n' "$TILE_LAZY_BOOTED_PROPERTY_CONTEXT" >> "$SYSTEM_EXT_SELINUX/system_ext_property_contexts"
        PATCHED=true
    fi

    SYSTEMUI_UEVENT_RULE="(allow platform_app_36 self (netlink_kobject_uevent_socket (read create bind setopt)))"
    if ! grep -qF "$SYSTEMUI_UEVENT_RULE" "$SYSTEM_EXT_SELINUX/system_ext_sepolicy.cil"; then
        printf '%s\n' "$SYSTEMUI_UEVENT_RULE" >> "$SYSTEM_EXT_SELINUX/system_ext_sepolicy.cil"
        PATCHED=true
    fi

    # AODService runs in the same platform_app_36 domain as SystemUI.  It
    # reads the physical UDFPS position from
    # /sys/class/fingerprint/fingerprint/position.  The legacy y2s policy
    # granted the old platform_app_30_0 domain access to the target's
    # sysfs_ss_writable nodes, but Android 17 does not carry that grant to
    # platform_app_36.  Without the read-only traversal and file access the
    # service falls back to the donor's hard-coded sensor dimensions, placing
    # Now Bar with the wrong bottom margin.  Keep this to the three operations
    # used by File.exists(), File.length(), and FileInputStream.
    SYSTEMUI_FOD_POSITION_RULES=(
        "(allow platform_app_36 sysfs_ss_writable (dir (getattr search)))"
        "(allow platform_app_36 sysfs_ss_writable (file (getattr open read)))"
        "(allow platform_app_36 sysfs_ss_writable (lnk_file (getattr read)))"
    )
    for SYSTEMUI_FOD_POSITION_RULE in "${SYSTEMUI_FOD_POSITION_RULES[@]}"; do
        if ! grep -qF "$SYSTEMUI_FOD_POSITION_RULE" "$VENDOR_SEPOLICY"; then
            printf '%s\n' "$SYSTEMUI_FOD_POSITION_RULE" >> "$VENDOR_SEPOLICY"
            PATCHED=true
        fi
    done
fi

# Android 17 no longer labels the legacy ION node because current devices use
# DMA-BUF heaps. Exynos 990's gralloc 2.0 allocator still opens /dev/ion; when
# left as the generic "device" type SELinux rejects the open even though the
# node is mode 0666. Restore the public legacy label expected by vendor policy.
VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
if ! grep -qE '^[[:space:]]*/dev/ion[[:space:]]+u:object_r:ion_device:s0([[:space:]]|$)' \
        "$VENDOR_FILE_CONTEXTS"; then
    sed -i -E '/^[[:space:]]*\/dev\/ion([[:space:]]|$)/d' "$VENDOR_FILE_CONTEXTS"
    printf '%s\n' '/dev/ion    u:object_r:ion_device:s0' >> "$VENDOR_FILE_CONTEXTS"
    PATCHED=true
fi

# The Android 17 platform policy grants the graphics allocator access only to
# DMA-BUF heaps. The Exynos 990 allocator predates that interface and performs
# its allocations through ION, so restore the corresponding Android 11 rule in
# the target vendor policy. Keep this scoped to the allocator HAL instead of
# granting generic access to every process or to the generic device type.
ION_ALLOCATOR_TYPE="ion_device_${CIL_NAME//./_}"
ION_ALLOCATOR_RULE="(allow hal_graphics_allocator $ION_ALLOCATOR_TYPE (chr_file (ioctl read write getattr lock append map open watch watch_reads)))"
if ! grep -qF "$ION_ALLOCATOR_RULE" "$VENDOR_SEPOLICY"; then
    printf '%s\n' "$ION_ALLOCATOR_RULE" >> "$VENDOR_SEPOLICY"
    PATCHED=true
fi

# Both suspend implementations enumerate /sys/class/wakeup.  On current
# devices its links resolve to sysfs_wakeup, but on the Exynos 990 they also
# resolve to generic sysfs nodes (sensor/biometric wakeups) and to vendor
# sysfs_battery nodes (charging wakeups).  Android 17 supplies the former
# sysfs_wakeup rules, but not the two legacy target labels, which makes the
# running system_suspend service continuously fail to read event_count.
#
# Keep the compatibility grant read-only and limited to system_suspend.  The
# vendor policy already groups its intended suspend-readable target labels in
# system_suspend_access_sysnode, so do not name every vendor type directly.
# /sys/kernel/debug/wakeup_sources is not used here and deliberately remains
# inaccessible.
SUSPEND_REQUIRED_RULES=(
    "(allow system_suspend sysfs_wakeup (dir (ioctl read getattr lock open watch watch_reads search)))"
    "(allow system_suspend sysfs_wakeup (file (ioctl read getattr lock map open watch watch_reads)))"
    "(allow system_suspend sysfs_wakeup (lnk_file (ioctl read getattr lock map open watch watch_reads)))"
    "(allow system_suspend_server system_suspend_hwservice (hwservice_manager (add find)))"
    "(allow system_suspend_server hidl_base_hwservice (hwservice_manager (add)))"
)
for SUSPEND_RULE in "${SUSPEND_REQUIRED_RULES[@]}"; do
    if ! grep -q -F "$SUSPEND_RULE" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"; then
        ABORT "Missing required system suspend SELinux rule: $SUSPEND_RULE"
        return 1
    fi
done

SUSPEND_PLATFORM_POLICY="$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"
SUSPEND_PLATFORM_RULES=(
    "(allow system_suspend sysfs (dir (ioctl read getattr lock open watch watch_reads search)))"
    "(allow system_suspend sysfs (file (ioctl read getattr lock map open watch watch_reads)))"
    "(allow system_suspend sysfs (lnk_file (ioctl read getattr lock map open watch watch_reads)))"
)
for SUSPEND_RULE in "${SUSPEND_PLATFORM_RULES[@]}"; do
    if ! grep -q -F "$SUSPEND_RULE" "$SUSPEND_PLATFORM_POLICY"; then
        printf '%s\n' "$SUSPEND_RULE" >> "$SUSPEND_PLATFORM_POLICY"
        PATCHED=true
    fi
done

# system_suspend_access_sysnode is declared by vendors that need system_suspend
# to inspect legacy sysfs wakeup providers.  Add the narrow target-side grant
# only when that compatibility attribute exists, so other targets are not
# changed or made dependent on a target-private type.
if grep -q -F '(typeattributeset system_suspend_access_sysnode ' "$VENDOR_SEPOLICY"; then
    SUSPEND_VENDOR_RULES=(
        "(allow system_suspend system_suspend_access_sysnode (dir (ioctl read getattr lock open watch watch_reads search)))"
        "(allow system_suspend system_suspend_access_sysnode (file (ioctl read getattr lock map open watch watch_reads)))"
        "(allow system_suspend system_suspend_access_sysnode (lnk_file (ioctl read getattr lock map open watch watch_reads)))"
    )
    for SUSPEND_RULE in "${SUSPEND_VENDOR_RULES[@]}"; do
        if ! grep -q -F "$SUSPEND_RULE" "$VENDOR_SEPOLICY"; then
            printf '%s\n' "$SUSPEND_RULE" >> "$VENDOR_SEPOLICY"
            PATCHED=true
        fi
    done
fi

# Android 17 sources no longer ship the Android 10/11 compatibility mappings
# required by the Exynos 990 vendor policy. They must exist in system_ext
# before the removal pass below reads the target vendor's CIL version.
for LEGACY_MAPPING in 29.0.cil 29.0.compat.cil 30.0.cil 30.0.compat.cil; do
    if [ ! -f "$SYSTEM_EXT_SELINUX/mapping/$LEGACY_MAPPING" ]; then
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system_ext" \
            "etc/selinux/mapping/$LEGACY_MAPPING" \
            0 0 644 "u:object_r:system_file:s0" || return 1
        PATCHED=true
    fi
done

CIL_FILE="$SYSTEM_EXT_SELINUX/mapping/$CIL_NAME.cil"
if [ ! -f "$CIL_FILE" ]; then
    ABORT "Missing system_ext SELinux mapping for target vendor policy $CIL_NAME"
fi

VENDOR_API_LIST="$(find "$SYSTEM_EXT_SELINUX/mapping" -type f -printf "%f\n" | \
                    sed '/.compat./d' | sed 's/.cil//' | sed 's/\./_/' | sort)"
# ]

for e in $ENTRIES; do
    if grep -q -F "($e)" "$CIL_FILE" || \
         grep -q -F "${e}_${CIL_NAME//./_}" "$CIL_FILE"; then
        # the problematic entry is currently present in system_ext, check if we need to remove it
        if ! grep -q -F "(type $e)" "$WORK_DIR/vendor/etc/selinux/plat_pub_versioned.cil"; then
            PATCHED=true
            # the problematic entry is not supported by the target device
            LOG "- \"$e\" SELinux entry not supported. Removing"
            sed -i "/($e)/d" "$CIL_FILE"
            for a in $VENDOR_API_LIST; do
                sed -i "/${e}_${a}/d" "$CIL_FILE"
            done
            if grep -q "genfscon.*$e" "$SYSTEM_EXT_SELINUX/system_ext_sepolicy.cil"; then
                sed -i "/genfscon.*$e/d" "$SYSTEM_EXT_SELINUX/system_ext_sepolicy.cil"
            fi
            if grep -q "genfscon.*$e" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"; then
                sed -i "/genfscon.*$e/d" "$WORK_DIR/system/system/etc/selinux/plat_sepolicy.cil"
            fi
        fi
    fi
done

for e in $DUPLICATES; do
    if grep -q "^$e.*" "$SYSTEM_EXT_SELINUX/system_ext_property_contexts"; then
        # the problematic entry is currently present in system_ext, check if we need to remove it
        if grep -q "^$e.*" "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"; then
            PATCHED=true
            # the problematic entry is found in target vendor
            LOG "- \"$e\" SELinux duplicate entry found. Removing"
            sed -i "s/^$e/#SEC_DUPLICATE: $e/g" "$WORK_DIR/vendor/etc/selinux/vendor_property_contexts"
        fi
    fi
done

# New source releases may omit the legacy platform mappings. Import only
# missing files from the target firmware, retaining the source's own mappings.
for LEGACY_MAPPING in 29.0.cil 29.0.compat.cil 30.0.cil 30.0.compat.cil; do
    if [ ! -f "$WORK_DIR/system/system/etc/selinux/mapping/$LEGACY_MAPPING" ]; then
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/etc/selinux/mapping/$LEGACY_MAPPING" \
            0 0 644 "u:object_r:system_file:s0" || return 1
        PATCHED=true
    fi
done

# The legacy mappings above come from the target firmware and predate the
# per-SDK app domains of the Android 17 platform (platform_app_36,
# priv_app_36). The source's own 31.0+ mappings add those domains to the
# versioned attributes, but the imported 29.0/30.0 ones only list the base
# domain, so no vendor rule written for platform_app_30_0 or priv_app_30_0
# reaches apps running in the new domains. GOS (platform_app_36) is one of
# them: it cannot read sysfs_thermal, IPM fails "SLSI temp heuristics" and
# Game Booster's performance monitor gets no FPS/CPU/GPU data. Copy the
# domain lists from the source's 31.0 mapping into the target's mapping.
PLAT_MAPPING_DIR="$WORK_DIR/system/system/etc/selinux/mapping"
if [ -f "$PLAT_MAPPING_DIR/31.0.cil" ] && [ -f "$PLAT_MAPPING_DIR/$CIL_NAME.cil" ] && \
        [ "$CIL_NAME" != "31.0" ]; then
    while read -r APP_DOMAIN SDK_DOMAIN; do
        VERSIONED_ATTR="${APP_DOMAIN}_${CIL_NAME//./_}"
        if grep -q -F "(typeattributeset $VERSIONED_ATTR ($APP_DOMAIN))" "$PLAT_MAPPING_DIR/$CIL_NAME.cil"; then
            LOG "- Mapping $SDK_DOMAIN to $VERSIONED_ATTR"
            sed -i "s/^(typeattributeset $VERSIONED_ATTR ($APP_DOMAIN))$/(typeattributeset $VERSIONED_ATTR ($APP_DOMAIN $SDK_DOMAIN))/" \
                "$PLAT_MAPPING_DIR/$CIL_NAME.cil"
            PATCHED=true
        fi
    done < <(sed -n -E 's/^\(typeattributeset ([a-z_0-9]+)_31_0 \(([a-z_0-9]+) (\2_[0-9]+)\)\)$/\2 \3/p' \
        "$PLAT_MAPPING_DIR/31.0.cil")
fi

if ! $PATCHED; then
    LOG "\033[0;33m! Nothing to do\033[0m"
fi

unset ENTRIES DUPLICATES CIL_NAME CIL_FILE PATCHED SYSTEM_EXT_SELINUX VENDOR_FILE_CONTEXTS VENDOR_SEPOLICY
unset ION_ALLOCATOR_TYPE ION_ALLOCATOR_RULE SUSPEND_REQUIRED_RULES SUSPEND_PLATFORM_POLICY \
    SUSPEND_PLATFORM_RULES SUSPEND_VENDOR_RULES SUSPEND_RULE VENDOR_API_LIST LEGACY_MAPPING
unset SYSTEMUI_FOD_POSITION_RULES SYSTEMUI_FOD_POSITION_RULE
unset PLAT_MAPPING_DIR APP_DOMAIN SDK_DOMAIN VERSIONED_ATTR
unset -f GET_SYSTEM_EXT
