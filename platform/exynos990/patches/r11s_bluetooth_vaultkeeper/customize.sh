# Persist the selected coherent stack across apply_modules.sh invocations.
# Device patches run before ROM patches, so CIDManager consumes this marker
# later and makes this module authoritative for the final system files.
mkdir -p "$WORK_DIR/configs"
printf '%s\n' "$MODPATH" > "$WORK_DIR/configs/vaultkeeper_system_stack.path"

# The Bluetooth APEX stays the Android 17 one from the source firmware. The
# S23 FE BP4A APEX this module used to ship calls
# TelephonyManager#getMultiSimConfiguration(), which Android 17 removed, so
# com.android.bluetooth crashed on AT+COPS from car head units. Restore the
# source files explicitly so a cached work dir from an older build does not
# keep the S23 FE copies. unica/patches/bluetooth then patches this APEX and
# disables VaultKeeper in libbluetooth_jni.so, so its AIDL VaultKeeper client
# never needs the vendor service, which y2s only has as HIDL 2.0.
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/apex/com.android.bt.apex" \
    0 0 644 "u:object_r:system_file:s0"
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/lib64/libbt-iopdb.so" \
    0 0 644 "u:object_r:system_lib_file:s0"
ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/lib64/libbt-iopdb_mod.so" \
    0 0 644 "u:object_r:system_lib_file:s0"
