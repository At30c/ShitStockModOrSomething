# Adapted from the downloaded Exynos 2100 module. The early order makes
# these libraries available to subsequent camera and WFD compatibility fixes.
if [ "$SOURCE_PLATFORM_SDK_VERSION" -lt 36 ]; then
    LOG "- Source does not require the multilib compatibility runtime"
    return 0
fi

EXYNOS990_RUNTIME32_APEX_MODE="${EXYNOS990_RUNTIME32_APEX_MODE:-merged}"
case "$EXYNOS990_RUNTIME32_APEX_MODE" in
    merged|source_apex)
        ;;
    *)
        LOGE "Invalid EXYNOS990_RUNTIME32_APEX_MODE: $EXYNOS990_RUNTIME32_APEX_MODE"
        return 1
        ;;
esac

INSTALL_DESIX_RUNTIME32_STANDALONE()
{
    local DONOR_APEX="$SRC_DIR/prebuilts/samsung/r11sxxx/system/apex/com.android.runtime.apex"
    local RUNTIME_ROOT="$TMP_DIR/desixtification-runtime32-standalone"
    local DECODED="$RUNTIME_ROOT/donor"
    local PAYLOAD="$RUNTIME_ROOT/payload"
    local BIONIC_LIB
    local DEST
    local RUNTIME_LINKER_FOUND=false

    [ -f "$DONOR_APEX" ] || {
        LOGE "Missing r11s Runtime APEX for standalone ARM32 compatibility"
        return 1
    }

    rm -rf "$RUNTIME_ROOT"
    mkdir -p "$RUNTIME_ROOT"
    LOG "- Extracting standalone ARM32 linker/Bionic from r11s Runtime"
    EVAL "apktool d -j \"$(nproc)\" -o \"$DECODED\" -r \"$DONOR_APEX\""
    EXTRACT_EXT4_IMAGE "$DECODED/unknown/apex_payload.img" "$PAYLOAD" \
        "$RUNTIME_ROOT/fs_config" "$RUNTIME_ROOT/file_contexts" || return 1

    mkdir -p "$WORK_DIR/system/system/bin" "$WORK_DIR/system/system/lib"
    for DEST in linker linker_asan; do
        if [ -e "$PAYLOAD/bin/$DEST" ] || [ -L "$PAYLOAD/bin/$DEST" ]; then
            [ "$DEST" = "linker" ] && RUNTIME_LINKER_FOUND=true
            cp -a "$PAYLOAD/bin/$DEST" "$WORK_DIR/system/system/bin/$DEST" || return 1
            SET_METADATA "system" "system/bin/$DEST" 0 2000 755 \
                "u:object_r:system_linker_exec:s0" || return 1
        fi
    done
    if ! $RUNTIME_LINKER_FOUND; then
        LOGE "r11s Runtime APEX lacks the ARM32 linker"
        return 1
    fi

    for BIONIC_LIB in libc.so libdl.so libdl_android.so libm.so; do
        if [ ! -f "$PAYLOAD/lib/bionic/$BIONIC_LIB" ]; then
            LOGE "r11s Runtime APEX lacks ARM32 Bionic $BIONIC_LIB"
            return 1
        fi
        cp -a "$PAYLOAD/lib/bionic/$BIONIC_LIB" \
            "$WORK_DIR/system/system/lib/$BIONIC_LIB" || return 1
        SET_METADATA "system" "system/lib/$BIONIC_LIB" 0 0 644 \
            "u:object_r:system_lib_file:s0" || return 1
    done
    rm -rf "$RUNTIME_ROOT"
}

if [ "$EXYNOS990_RUNTIME32_APEX_MODE" = "merged" ]; then
LOG_STEP_IN "- Adding S23 FE ARM32 libraries and runtime"

# ADD_TO_WORK_DIR can infer metadata for individual files, but a recursive
# directory import expects every child to already exist in the donor metadata
# files.  The extracted r11s prebuilt intentionally contains only a minimal
# metadata manifest, so register the homogeneous system/lib tree here before
# importing it.  This avoids hundreds of fallback warnings and guarantees the
# permissions/labels used in the rebuilt system image.
DESIX_LIB_ROOT="$SRC_DIR/prebuilts/samsung/r11sxxx/system/lib"
while IFS= read -r -d '' DESIX_LIB_PATH; do
    DESIX_LIB_ENTRY="system/lib/${DESIX_LIB_PATH#"$DESIX_LIB_ROOT"/}"
    if [ -d "$DESIX_LIB_PATH" ]; then
        DESIX_LIB_MODE=755
    else
        DESIX_LIB_MODE=644
    fi

    if ! grep -q -F "$DESIX_LIB_ENTRY " "$WORK_DIR/configs/fs_config-system"; then
        echo "$DESIX_LIB_ENTRY 0 0 $DESIX_LIB_MODE capabilities=0x0" \
            >> "$WORK_DIR/configs/fs_config-system"
    fi

    DESIX_LIB_CONTEXT="/$(_HANDLE_SPECIAL_CHARS "$DESIX_LIB_ENTRY")"
    if ! grep -q -F "$DESIX_LIB_CONTEXT " "$WORK_DIR/configs/file_context-system"; then
        echo "$DESIX_LIB_CONTEXT u:object_r:system_lib_file:s0" \
            >> "$WORK_DIR/configs/file_context-system"
    fi
done < <(find "$DESIX_LIB_ROOT" -mindepth 1 -print0 | sort -z)

ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib" 0 0 755 "u:object_r:system_lib_file:s0" || return 1
SET_METADATA "system" "system/lib" 0 0 755 "u:object_r:system_lib_file:s0" || return 1

# MERGE_DESIX_METADATA <base file> <donor file> <donor paths> <fs_config|file_contexts>
# Replaces the base entries of the listed paths with the donor entries.
MERGE_DESIX_METADATA()
{
    local BASE="$1"
    local DONOR="$2"
    local PATHS="$3"
    local KIND="$4"

    awk -v kind="$KIND" '
        function key(line) {
            if (kind == "fs_config")
                sub(/ [^ ]+ [^ ]+ [^ ]+ capabilities=[^ ]+$/, "", line)
            else
                sub(/ [^ ]+$/, "", line)
            return line
        }
        FILENAME == ARGV[1] { wanted[$0] = 1; next }
        FILENAME == ARGV[2] { if (key($0) in wanted) { print; found[key($0)] = 1 } next }
        !(key($0) in wanted) { print }
        END { for (p in wanted) if (!(p in found)) { print "missing donor metadata: " p > "/dev/stderr"; exit 1 } }
    ' "$PATHS" "$DONOR" "$BASE" > "$BASE.merged" || return 1
    sort -o "$BASE" "$BASE.merged" && rm -f "$BASE.merged"
}

# Never replace the complete Runtime/I18n APEX with the Android 16 donor.
# Besides ARM32, those packages also contain Bionic/ICU for ARM64. Mixing that
# ARM64 runtime with the Android 17 framework causes CFI failures (notably
# netd1shot crashing in __cfi_slowpath).  Start from the source APEX and merge
# only the missing ARM32 payload directories from r11s.
MERGE_DESIX_APEX_ARM32()
{
    local APEX_NAME="$1"
    local MERGE_BIN_LINKER="$2"
    local BASE_APEX="$WORK_DIR/system/system/apex/$APEX_NAME.apex"
    local DONOR_APEX="$SRC_DIR/prebuilts/samsung/r11sxxx/system/apex/$APEX_NAME.apex"
    local MERGE_ROOT="$TMP_DIR/desixtification-${APEX_NAME##*.}"
    local BASE_DECODED="$MERGE_ROOT/base"
    local DONOR_DECODED="$MERGE_ROOT/donor"
    local PAYLOAD="$BASE_DECODED/unknown/apex_payload"
    local DONOR_PAYLOAD="$MERGE_ROOT/donor_payload"
    local DONOR_PATHS="$MERGE_ROOT/donor_paths"
    local FS_CONFIG="$MERGE_ROOT/fs_config"
    local FILE_CONTEXTS="$MERGE_ROOT/file_contexts"
    local SALT CERT_PREFIX BUILT_APEX ARM32_RUNTIME_BIN

    if [ ! -f "$BASE_APEX" ] || [ ! -f "$DONOR_APEX" ]; then
        LOGE "Missing base or donor APEX for $APEX_NAME"
        return 1
    fi
    rm -rf "$MERGE_ROOT"
    mkdir -p "$MERGE_ROOT"

    LOG "- Decoding source $APEX_NAME"
    EVAL "apktool d -j \"$(nproc)\" -o \"$BASE_DECODED\" -r \"$BASE_APEX\""
    LOG "- Decoding r11s $APEX_NAME"
    EVAL "apktool d -j \"$(nproc)\" -o \"$DONOR_DECODED\" -r \"$DONOR_APEX\""

    EXTRACT_EXT4_IMAGE "$BASE_DECODED/unknown/apex_payload.img" "$PAYLOAD" \
        "$FS_CONFIG" "$FILE_CONTEXTS" || return 1
    EXTRACT_EXT4_IMAGE "$DONOR_DECODED/unknown/apex_payload.img" "$DONOR_PAYLOAD" \
        "$MERGE_ROOT/donor_fs_config" "$MERGE_ROOT/donor_file_contexts" || return 1
    if [ ! -d "$DONOR_PAYLOAD/lib" ]; then
        LOGE "$APEX_NAME donor has no ARM32 lib directory"
        return 1
    fi

    # Paths taken from the donor keep the donor's metadata.
    cp -a "$DONOR_PAYLOAD/lib" "$PAYLOAD/" || return 1
    (cd "$DONOR_PAYLOAD" && find lib) > "$DONOR_PATHS"
    if [ "$MERGE_BIN_LINKER" = "true" ]; then
        for ARM32_RUNTIME_BIN in linker linker_asan crash_dump32; do
            if [ -e "$DONOR_PAYLOAD/bin/$ARM32_RUNTIME_BIN" ] || \
                    [ -L "$DONOR_PAYLOAD/bin/$ARM32_RUNTIME_BIN" ]; then
                cp -a "$DONOR_PAYLOAD/bin/$ARM32_RUNTIME_BIN" \
                    "$PAYLOAD/bin/$ARM32_RUNTIME_BIN" || return 1
                echo "bin/$ARM32_RUNTIME_BIN" >> "$DONOR_PATHS"
            fi
        done
    fi
    MERGE_DESIX_METADATA "$FS_CONFIG" "$MERGE_ROOT/donor_fs_config" \
        "$DONOR_PATHS" fs_config || return 1
    sed -e 's|^|/|' -e 's|\.|\\.|g' -e 's|+|\\+|g' -e 's|\[|\\[|g' \
        -e 's|\]|\\]|g' -e 's|\*|\\*|g' "$DONOR_PATHS" > "$DONOR_PATHS.ctx"
    MERGE_DESIX_METADATA "$FILE_CONTEXTS" "$MERGE_ROOT/donor_file_contexts" \
        "$DONOR_PATHS.ctx" file_contexts || return 1
    rm -rf "$DONOR_DECODED" "$DONOR_PAYLOAD" "$DONOR_PATHS" "$DONOR_PATHS.ctx" \
        "$MERGE_ROOT/donor_fs_config" "$MERGE_ROOT/donor_file_contexts"
    rm -f "$BASE_DECODED/unknown/apex_payload.img"

    LOG "- Rebuilding merged $APEX_NAME payload"
    "$SRC_DIR/scripts/build_fs_image.sh" ext4 --no-avb \
        -o "$BASE_DECODED/unknown/apex_payload.img" -p system \
        "$PAYLOAD" "$FILE_CONTEXTS" "$FS_CONFIG" > /dev/null || return 1
    rm -rf "$PAYLOAD" "$FILE_CONTEXTS" "$FS_CONFIG"

    SALT="$(sha256sum "$BASE_DECODED/unknown/apex_manifest.pb" | cut -d ' ' -f 1)"
    EVAL "avbtool add_hashtree_footer --do_not_generate_fec --algorithm SHA256_RSA4096 --hash_algorithm sha256 --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --prop \"apex.key:$APEX_NAME\" --salt \"$SALT\" --image \"$BASE_DECODED/unknown/apex_payload.img\""
    EVAL "avbtool extract_public_key --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --output \"$BASE_DECODED/unknown/apex_pubkey\""
    mkdir -p "$BASE_DECODED/build/apk"
    cp -a "$BASE_DECODED/original/META-INF" "$BASE_DECODED/build/apk/META-INF"
    EVAL "apktool b -j \"$(nproc)\" \"$BASE_DECODED\""
    BUILT_APEX="$BASE_DECODED/dist/$APEX_NAME.apex"
    [ -f "$BUILT_APEX" ] || BUILT_APEX="$BASE_DECODED/dist/$(basename "$BASE_APEX")"
    if [ ! -f "$BUILT_APEX" ]; then
        LOGE "Rebuilt $APEX_NAME was not produced"
        return 1
    fi
    CERT_PREFIX=aosp
    $ROM_IS_OFFICIAL && CERT_PREFIX=unica
    EVAL "signapk -a 4096 --align-file-size \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$BUILT_APEX\" \"$BUILT_APEX.signed\""
    mv -f "$BUILT_APEX.signed" "$BASE_APEX"
    rm -rf "$MERGE_ROOT"
}

MERGE_DESIX_APEX_ARM32 "com.android.runtime" true || return 1
MERGE_DESIX_APEX_ARM32 "com.android.i18n" false || return 1
# tzdata6 is byte-identical between the current source and donor; retain the
# source package so future source changes cannot be silently downgraded.
ADD_TO_WORK_DIR "r11sxxx" "system" "system/bin/bootstrap/linker" \
    0 0 755 "u:object_r:system_file:s0" || return 1
SET_METADATA "system" "system/bin/bootstrap/linker" 0 0 755 "u:object_r:system_file:s0" || return 1
# Keep the target's ARM32 BoringSSL helper available alongside the imported
# ARM32 crypto library for the Exynos 9611/M21s chain. It is not selected while
# ro.zygote=zygote64 and the aggregate ABI-32 list is empty, but retaining the
# native F415F executable preserves the complete legacy runtime for targeted
# tests without transplanting a cross-SoC vendor binary.
if [[ "$TARGET_PLATFORM" == "exynos9611" ]]; then
    TARGET_FW_DIR="$FW_DIR/$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
    if [ -f "$TARGET_FW_DIR/system/system/bin/boringssl_self_test32" ]; then
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/bin/boringssl_self_test32" 0 0 755 \
            "u:object_r:boringssl_self_test_exec:s0" || return 1
    else
        LOGE "Target F415F system/bin/boringssl_self_test32 is missing"
        return 1
    fi
    unset TARGET_FW_DIR
fi
# This download has no separate ASan binary. Use its ordinary linker as
# fallback, matching the non-ASan runtime links in the donor module.
ln -sfn linker "$WORK_DIR/system/system/bin/bootstrap/linker_asan" || return 1
SET_METADATA "system" "system/bin/bootstrap/linker_asan" 0 0 755 "u:object_r:system_file:s0" || return 1
for DESIX_LINK in linker linker_asan; do
    ln -sfn /apex/com.android.runtime/bin/linker "$WORK_DIR/system/system/bin/$DESIX_LINK" || return 1
    SET_METADATA "system" "system/bin/$DESIX_LINK" 0 0 755 "u:object_r:system_file:s0" || return 1
done
for DESIX_LINK in libc.so libdl.so libdl_android.so libm.so; do
    ln -sfn "/apex/com.android.runtime/lib/bionic/$DESIX_LINK" "$WORK_DIR/system/system/lib/$DESIX_LINK" || return 1
    SET_METADATA "system" "system/lib/$DESIX_LINK" 0 0 644 "u:object_r:system_lib_file:s0" || return 1
done
LOG_STEP_OUT
else
    # Keep the source S24+ Runtime/I18n/ART APEXes and do not add the donor
    # ARM32 linker or Bionic links.  A small non-Bionic exception is kept for
    # the later WFD compatibility module, which patches this library directly.
    # This is an A/B diagnostic variant for the Chromium/AppZygote crash; all
    # property fixes below remain active so the comparison is limited to the
    # runtime payload rather than an unrelated missing build input.
    LOG "- Source APEX test mode: preserving S24+ Runtime/I18n/ART APEXes"
    INSTALL_DESIX_RUNTIME32_STANDALONE || return 1
    # These target-side 32-bit framework libraries are referenced by vendor
    # sensor/GPU/minijail clients. Keep their ABI paired with the S20+ vendor;
    # libminijail/libcap are only available in the r11s ARM32 donor.
    for DESIX_TARGET_LIB in \
        android.frameworks.sensorservice@1.0.so \
        android.hardware.sensors@1.0.so \
        libGLESv3.so; do
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" \
            "system/lib/$DESIX_TARGET_LIB" 0 0 644 \
            "u:object_r:system_lib_file:s0" || return 1
    done
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libminijail.so" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libcap.so" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
    ADD_TO_WORK_DIR "r11sxxx" "system" "system/lib/libstagefright.so" \
        0 0 644 "u:object_r:system_lib_file:s0" || return 1
fi

# The source migration is zygote64-only. Keep the product ABI contract
# identical across every partition: aggregate lists contain only arm64 and
# the ABI-32 keys are explicitly empty. Legacy vendor clients still receive
# private ARM32 linker/runtime files from the compatibility layer; advertising
# a 32-bit product ABI here causes an early reboot on this target family.

SET_PROP "vendor" "ro.vendor.product.cpu.abilist" "arm64-v8a"
SET_PROP "vendor" "ro.vendor.product.cpu.abilist32" ""
SET_PROP "vendor" "ro.vendor.product.cpu.abilist64" "arm64-v8a"
SET_PROP "odm" "ro.odm.product.cpu.abilist" "arm64-v8a"
SET_PROP "odm" "ro.odm.product.cpu.abilist32" ""
SET_PROP "odm" "ro.odm.product.cpu.abilist64" "arm64-v8a"

SET_PROP "vendor" "ro.zygote" "zygote64"
SET_PROP "vendor" "dalvik.vm.dex2oat64.enabled" "true"
SET_PROP "system" "persist.sys.disable_rescue" "true"
unset DESIX_LINK DESIX_LIB_CONTEXT DESIX_LIB_ENTRY DESIX_LIB_MODE DESIX_LIB_PATH \
    DESIX_LIB_ROOT DESIX_TARGET_LIB
unset -f MERGE_DESIX_APEX_ARM32 MERGE_DESIX_METADATA
unset -f INSTALL_DESIX_RUNTIME32_STANDALONE
