# Property identifying the UN1CA version
SET_PROP "system" "ro.unica.version" "$ROM_VERSION"
EVAL "echo \"ro.unica.version u:object_r:build_prop:s0 exact string\" >> \"$WORK_DIR/system/system/etc/selinux/plat_property_contexts\""

# Property identifying the UN1CA build time
SET_PROP "system" "ro.unica.timestamp" "$ROM_BUILD_TIMESTAMP"
EVAL "echo \"ro.unica.timestamp u:object_r:build_prop:s0 exact string\" >> \"$WORK_DIR/system/system/etc/selinux/plat_property_contexts\""

# Property identifying the device codename UN1CA is being built for
SET_PROP "system" "ro.unica.device" "$TARGET_CODENAME"
EVAL "echo \"ro.unica.device u:object_r:build_prop:s0 exact string\" >> \"$WORK_DIR/system/system/etc/selinux/plat_property_contexts\""

# ro.unica.commit and ro.unica.fingerprint are stamped by
# scripts/internal/stamp_build_info.sh on every build (including reused work
# dirs), so they always carry the commit the image was built from.
