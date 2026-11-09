SKIPUNZIP=1

CAPEX="$WORK_DIR/system/system/apex/com.google.android.tethering_compressed.apex"
PATCH_TMP="$TMP_DIR/tethering_legacy"
DECODED="$PATCH_TMP/decoded"
PAYLOAD="$DECODED/unknown/apex_payload"
LEGACY_KERNEL_VERSION="${TETHERING_LEGACY_KERNEL_VERSION:-4.19}"
SERVICE_PATCH_DIR="${TETHERING_SERVICE_PATCH_DIR:-$MODPATH/patches/service-connectivity.jar}"

if [ ! -f "$CAPEX" ]; then
    LOGE "Tethering CAPEX not found: ${CAPEX//$WORK_DIR/}"
    return 1
fi

rm -rf "$PATCH_TMP"
mkdir -p "$PATCH_TMP"

LOG "- Extracting original Tethering APEX"
if unzip -l "$CAPEX" original_apex 2> /dev/null | grep -q "original_apex"; then
    unzip -p "$CAPEX" original_apex > "$PATCH_TMP/original.apex"
else
    # Incremental builds already contain the uncompressed APEX produced by this
    # module, even though the work-dir filename retains the _compressed suffix.
    cp -a "$CAPEX" "$PATCH_TMP/original.apex"
fi
if [ ! -s "$PATCH_TMP/original.apex" ]; then
    LOGE "Failed to extract original_apex from ${CAPEX//$WORK_DIR/}"
    return 1
fi

LOG "- Decoding original Tethering APEX"
EVAL "apktool d -j \"$(nproc)\" -o \"$DECODED\" -r \"$PATCH_TMP/original.apex\""

LOG "- Extracting apex_payload.img"
EXTRACT_EXT4_IMAGE "$DECODED/unknown/apex_payload.img" "$PAYLOAD" \
    "$PATCH_TMP/fs_config" "$PATCH_TMP/file_contexts" || return 1
rm -f "$DECODED/unknown/apex_payload.img"

# The metadata includes the payload root, so the spec list has a bare "/".
# libselinux's selabel_lookup() then stops matching every other path and
# e2fsdroid aborts with 'set_selinux_xattr: No such file or directory searching
# for label "/bin"'. Keep the exact specs first and append a catch-all last so
# nothing is left unlabelled; the first match always wins. lost+found has to
# precede it, otherwise it would be labelled with the payload root's context
# instead of rootfs.
ROOT_SELINUX_LABEL="$(sed -n 's|^/ \([^ ]*\)$|\1|p' "$PATCH_TMP/file_contexts" | head -n 1)"
if [ -z "$ROOT_SELINUX_LABEL" ]; then
    LOGE "Failed to record the Tethering APEX payload SELinux context"
    return 1
fi
printf '/lost\\+found u:object_r:rootfs:s0\n/.* %s\n' "$ROOT_SELINUX_LABEL" \
    >> "$PATCH_TMP/file_contexts"

# The Android 16 connectivity service starts two optional native BPF event
# consumers when their metrics flags are enabled.  Both ring buffers are
# unavailable on the M21s's Linux 4.14 kernel, and the native consumers
# abort system_server when their maps are missing.  Disable both call sites in
# the APEX jar before rebuilding the payload.  The remaining BPF maps are
# opened lazily by BpfNetMaps, which turns a missing map into an
# IllegalStateException; those getters are redirected to an inert map so a
# kernel that cannot enumerate /sys/fs/bpf/netd_shared degrades instead of
# looping system_server.
SERVICE_CONNECTIVITY="$PAYLOAD/javalib/service-connectivity.jar"
SERVICE_CONNECTIVITY_WORK="$WORK_DIR/system/system/framework/service-connectivity.jar"
SERVICE_CONNECTIVITY_PATCH="$SERVICE_PATCH_DIR/0001-disable-local-net-event-listener-on-legacy-bpf.patch"
SERVICE_CONNECTIVITY_LOOPBACK_PATCH="$SERVICE_PATCH_DIR/0002-disable-loopback-event-consumer-on-legacy-bpf.patch"
SERVICE_CONNECTIVITY_BPFFALLBACK_PATCH="$SERVICE_PATCH_DIR/0003-fallback-to-inert-bpf-maps-on-legacy-bpf.patch"
SERVICE_CONNECTIVITY_APP_OPT_IN_PATCH="${TETHERING_APP_OPT_IN_PATCH:-}"

if [ ! -f "$SERVICE_CONNECTIVITY" ]; then
    LOGE "Tethering service-connectivity.jar not found in apex_payload"
    return 1
elif [ ! -f "$SERVICE_CONNECTIVITY_PATCH" ]; then
    LOGE "Missing service-connectivity legacy-kernel patch"
    return 1
elif [ ! -f "$SERVICE_CONNECTIVITY_LOOPBACK_PATCH" ]; then
    LOGE "Missing service-connectivity loopback legacy-kernel patch"
    return 1
elif [ ! -f "$SERVICE_CONNECTIVITY_BPFFALLBACK_PATCH" ]; then
    LOGE "Missing service-connectivity inert BPF map fallback patch"
    return 1
fi

if [ "${TETHERING_SKIP_SERVICE_PATCHES:-false}" = "true" ]; then
    # Recovery-only APEX repairs must preserve the installed connectivity JAR
    # exactly. This is used when modifying a native payload component on a
    # device that already carries a different valid JAR patch layout.
    LOG "- Keeping installed service-connectivity.jar unchanged"
else
    LOG "- Decoding apex_payload/javalib/service-connectivity.jar"
    mkdir -p "$(dirname "$SERVICE_CONNECTIVITY_WORK")"
    mv -f "$SERVICE_CONNECTIVITY" "$SERVICE_CONNECTIVITY_WORK"
    DECODE_APK "system" "system/framework/service-connectivity.jar"

    LOG "- Disabling connectivity BPF event consumers on the legacy kernel"
    APPLY_PATCH "system" "system/framework/service-connectivity.jar" \
        "$SERVICE_CONNECTIVITY_PATCH" || return 1
    APPLY_PATCH "system" "system/framework/service-connectivity.jar" \
        "$SERVICE_CONNECTIVITY_LOOPBACK_PATCH" || return 1
    LOG "- Falling back to inert BPF maps on the legacy kernel"
    APPLY_PATCH "system" "system/framework/service-connectivity.jar" \
        "$SERVICE_CONNECTIVITY_BPFFALLBACK_PATCH" || return 1
    if [ -n "$SERVICE_CONNECTIVITY_APP_OPT_IN_PATCH" ]; then
        LOG "- Disabling unsupported satellite app routing"
        APPLY_PATCH "system" "system/framework/service-connectivity.jar" \
            "$SERVICE_CONNECTIVITY_APP_OPT_IN_PATCH" || return 1
    fi

    EVAL "\"$SRC_DIR/scripts/apktool.sh\" b \"system\" \"system/framework/service-connectivity.jar\"" || return 1
    mv -f "$SERVICE_CONNECTIVITY_WORK" "$SERVICE_CONNECTIVITY"
    rm -rf "$APKTOOL_DIR/system/framework/service-connectivity.jar"
fi

NETBPFLOAD="$PAYLOAD/bin/netbpfload"
EXPECTED_SHA256="cad99f3ef16dfb940e2a29b0a5061d0c8d21063604ace33877023bc78a27ad13"
PATCHED_SHA256="b4458f3107e66cff08e01de87586d2659578a4f16f09b13f846f047920eb0e61"
EXPECTED_85_SHA256="7b77a7ac01d01b6787544f2a01a77f4fd929ec6da0625c6f413764e8622ff2a2"
BROKEN_PATCHED_85_SHA256="d7b634fad672b400656f2dced2504b25090e54992d189133b3eaf1dab7c54813"
Q2_ONLY_PATCHED_85_SHA256="8ee75c6fc3eaf73cd6d93cfd9d96b253e4297706921bd57bedf224a5df16468a"
PATCHED_85_SHA256="13e9fedd343f603445b7094aa6d44266614bbd7e1962c10f56b87f445b219ad0"
EXPECTED_9_SHA256="775d705134ac47146a536d31e76af3d439d0e29d48087bc6c64d04c102c4bed6"
PATCHED_9_SHA256="25f3b42b7889d097994f576a63402025cd988b24f401894340b70f1da7219e6d"
# Linux 4.14 cannot verify the bounded loop in the Android 17 DSCP programs.
# These legacy hashes contain the old overly broad branch which also skipped
# netd.o. Keep them only so incremental work directories can be repaired.
LEGACY_DSCP_SKIPPED_PATCHED_9_SHA256="80ecac9684d6cd15f1e7b8636ced0bd3b761d96858a7a466b39173ad97d08d0a"
LEGACY_BPF_KVER_414355_PATCHED_9_SHA256="e2d014d42e193533b190ce6417e9b6bacd2d0cfd4d199bb48a60891caae4b498"
LEGACY_BPF_KVER_414355_V_GATE_PATCHED_9_SHA256="58ba6358de058d267e504c95ec1227c074dfb801ab08b7046b6cc4795fabd941"
# Correct states skip only dscpPolicy.o and dscpPolicy@funcs.o, continuing at
# netd.o and netd@funcs.o respectively.
DSCP_SKIPPED_PATCHED_9_SHA256="4a836d74d50edb498e5618d75be4055569cd4d2fa904c7b5d78f67d0174a6355"
# M21s-specific result after replacing the internal BPF program-selection
# cache with KVER(4, 14, 355). This does not alter uname() or the kernel's
# externally visible release.
BPF_KVER_414355_PATCHED_9_SHA256="59071a0f4fa023846f3f7db090171f67e0d718e175328387574ab3bdc04d6fc9"
# Same Android 17 sequence when the DSCP objects are kept natively (the M21
# kernel now verifies dscpPolicy.o, so TETHERING_BPF_KEEP_DSCP=1 leaves them
# for the loader): PATCHED_9 + the Linux 4.14 program-selection cache.
BPF_KVER_414355_NATIVE_PATCHED_9_SHA256="5c4cb40694afcb21bdefad15cf8970aa1fa2391687dbeb1a6434050acdfd7d38"
# Final native-DSCP M21s state after also bypassing Android V's 4.19 gate.
BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256="e17af1482036b037572c8961029c873a49531be10e0a9b29ac0b90947078d010"
# Result after bypassing Android V's separate 4.19-only gate on the M21s.
BPF_KVER_414355_V_GATE_PATCHED_9_SHA256="02224cd3f3a4aae897056e46eb668d4a58df45c1964da95b90c28c15446e4b1b"
ACTUAL_SHA256="$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)"

# Repair the first M21s implementation in-place. Its branch at 0xf408 jumped
# to the successful return and therefore skipped both dscpPolicy.o *and* the
# required netd.o. Retarget it to netd.o and add the equivalent narrow branch
# from dscpPolicy@funcs.o to netd@funcs.o.
if [ "$ACTUAL_SHA256" = "$LEGACY_DSCP_SKIPPED_PATCHED_9_SHA256" ] || \
        [ "$ACTUAL_SHA256" = "$LEGACY_BPF_KVER_414355_PATCHED_9_SHA256" ] || \
        [ "$ACTUAL_SHA256" = "$LEGACY_BPF_KVER_414355_V_GATE_PATCHED_9_SHA256" ]; then
    LOG "- Repairing cached NetBpfLoad DSCP skip to preserve netd.o"
    HEX_PATCH "$NETBPFLOAD" \
        "2100001400d41d912100805224000094e0030036" \
        "0500001400d41d912100805224000094e0030036" > /dev/null || return 1
    HEX_PATCH "$NETBPFLOAD" \
        "a0ffff9000803b91210080520d00009400010036" \
        "0500001400803b91210080520d00009400010036" > /dev/null || return 1
    ACTUAL_SHA256="$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)"
fi

if [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ]; then
    # NetBpfLoad v0.47 aborts API 36 on kernels older than 5.4. Exynos 990 uses
    # Linux 4.19 with the required BPF functionality backported, so skip only
    # this hard version gate while preserving the real kernel version for BPF
    # program selection.
    #
    # Before: tbnz w0, #0, <Android 25Q2 requires kernel 5.4 error path>
    # After:  nop
    LOG "- Disabling NetBpfLoad Android 25Q2 kernel 5.4 version gate"
    HEX_PATCH "$NETBPFLOAD" \
        "1c070094c0160036680800f0" \
        "1c0700941f2003d5680800f0" > /dev/null
    FINAL_SHA256="$PATCHED_SHA256"
elif [ "$ACTUAL_SHA256" = "$PATCHED_SHA256" ]; then
    LOG "- NetBpfLoad Android 25Q2 kernel gate is already disabled"
    FINAL_SHA256="$PATCHED_SHA256"
elif [ "$ACTUAL_SHA256" = "$EXPECTED_85_SHA256" ]; then
    # One UI 8.5 reaches the error block by falling through when the 25Q2
    # compatibility flag is set. Jump over that block unconditionally while
    # preserving the real kernel version for BPF program selection.
    #
    # Before: tbz w10, #0, <after Android 25Q2 kernel 5.4 error block>
    # After:  b <after Android 25Q2 kernel 5.4 error block>
    LOG "- Disabling NetBpfLoad One UI 8.5 kernel 5.4/5.10 version gates"
    HEX_PATCH "$NETBPFLOAD" \
        "5f01057168010054ea5244392a010036a1fffff0" \
        "5f01057168010054ea52443909000014a1fffff0" > /dev/null
    HEX_PATCH "$NETBPFLOAD" \
        "1f110a71280200546808009008614439c8010036a1fffff0" \
        "1f110a712802005468080090086144390e000014a1fffff0" > /dev/null
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$BROKEN_PATCHED_85_SHA256" ]; then
    LOG "- Repairing cached NetBpfLoad One UI 8.5 kernel gate patch"
    HEX_PATCH "$NETBPFLOAD" \
        "5f01057168010054ea5244391f2003d5a1fffff0" \
        "5f01057168010054ea52443909000014a1fffff0" > /dev/null
    HEX_PATCH "$NETBPFLOAD" \
        "1f110a71280200546808009008614439c8010036a1fffff0" \
        "1f110a712802005468080090086144390e000014a1fffff0" > /dev/null
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$Q2_ONLY_PATCHED_85_SHA256" ]; then
    LOG "- Disabling cached NetBpfLoad One UI 8.5 kernel 5.10 gate"
    HEX_PATCH "$NETBPFLOAD" \
        "1f110a71280200546808009008614439c8010036a1fffff0" \
        "1f110a712802005468080090086144390e000014a1fffff0" > /dev/null
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$PATCHED_85_SHA256" ]; then
    LOG "- NetBpfLoad One UI 8.5 kernel gate is already disabled"
    FINAL_SHA256="$PATCHED_85_SHA256"
elif [ "$ACTUAL_SHA256" = "$EXPECTED_9_SHA256" ]; then
    # Android 17 keeps separate 5.4 and 5.10 feature gates. The two TBZ
    # instructions enter their error blocks when the corresponding platform
    # flags are enabled; branch directly to each normal continuation instead.
    LOG "- Disabling NetBpfLoad One UI 9 kernel 5.4/5.10 version gates"
    HEX_PATCH "$NETBPFLOAD" \
        "cb7e1253730800d07f010571680100546b8244392b010036c1ffffb0" \
        "cb7e1253730800d07f010571680100546b82443909000014c1ffffb0" > /dev/null
    HEX_PATCH "$NETBPFLOAD" \
        "5f110a71280100546a0800d04a914439ca000036c1ffffb0" \
        "5f110a71280100546a0800d04a91443906000014c1ffffb0" > /dev/null
    FINAL_SHA256="$PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$PATCHED_9_SHA256" ]; then
    LOG "- NetBpfLoad One UI 9 kernel gates are already disabled"
    FINAL_SHA256="$PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$DSCP_SKIPPED_PATCHED_9_SHA256" ]; then
    # A recovery repair can begin from the previous M21s DSCP-only APEX.
    # Preserve that state so the later selector patch can be applied.
    LOG "- NetBpfLoad One UI 9 DSCP objects are already skipped on Linux 4.14"
    FINAL_SHA256="$DSCP_SKIPPED_PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_PATCHED_9_SHA256" ]; then
    LOG "- NetBpfLoad M21s Linux 4.14 program selector is already patched"
    FINAL_SHA256="$BPF_KVER_414355_PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_V_GATE_PATCHED_9_SHA256" ]; then
    LOG "- NetBpfLoad M21s Android V and program-selection gates are already patched"
    FINAL_SHA256="$BPF_KVER_414355_V_GATE_PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_NATIVE_PATCHED_9_SHA256" ]; then
    LOG "- NetBpfLoad M21s Linux 4.14 program selector (native DSCP) is already patched"
    FINAL_SHA256="$BPF_KVER_414355_NATIVE_PATCHED_9_SHA256"
elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256" ]; then
    LOG "- NetBpfLoad M21s Android V and program-selection gates (native DSCP) are already patched"
    FINAL_SHA256="$BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256"
else
    LOGE "Unsupported netbpfload build: $ACTUAL_SHA256"
    LOGE "Expected a supported One UI 8.0/8.5/9 original or patched build"
    return 1
fi

if [ "$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)" != "$FINAL_SHA256" ]; then
    LOGE "netbpfload patch validation failed"
    return 1
fi

if [ "$LEGACY_KERNEL_VERSION" = "4.14" ] && [ "${TETHERING_BPF_KEEP_DSCP:-0}" != "1" ]; then
    # The explicit Android 17 5.4/5.10 version gates above are already
    # bypassed.  Do not falsify the running kernel version: it selects the
    # compatible 4.9-4.19 netd programs.  Instead, bypass only the two DSCP
    # objects, which are hard-coded for Linux 5.15+ and fail the 4.14 BPF
    # verifier before their optional metadata can be honored.
    #
    # Branch around only dscpPolicy.o and dscpPolicy@funcs.o. Their immediate
    # successors are netd.o and netd@funcs.o, which provide the xt_bpf pinned
    # programs required by BandwidthController and must still be loaded.
    ACTUAL_SHA256="$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)"
    if [ "$ACTUAL_SHA256" = "$PATCHED_9_SHA256" ]; then
        LOG "- Skipping Linux 5.15-only DSCP BPF objects on Linux 4.14"
        HEX_PATCH "$NETBPFLOAD" \
            "80fffff000d41d912100805224000094e0030036" \
            "0500001400d41d912100805224000094e0030036" > /dev/null || return 1
        HEX_PATCH "$NETBPFLOAD" \
            "a0ffff9000803b91210080520d00009400010036" \
            "0500001400803b91210080520d00009400010036" > /dev/null || return 1
        FINAL_SHA256="$DSCP_SKIPPED_PATCHED_9_SHA256"
    elif [ "$ACTUAL_SHA256" = "$DSCP_SKIPPED_PATCHED_9_SHA256" ] || \
            [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_PATCHED_9_SHA256" ] || \
            [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_V_GATE_PATCHED_9_SHA256" ]; then
        LOG "- Linux 5.15-only DSCP BPF objects are already skipped on Linux 4.14"
        FINAL_SHA256="$ACTUAL_SHA256"
    else
        LOGE "Unsupported Android 17 netbpfload after kernel-gate patch: $ACTUAL_SHA256"
        return 1
    fi

    if [ "$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)" != "$FINAL_SHA256" ]; then
        LOGE "netbpfload DSCP-skip patch validation failed"
        return 1
    fi
fi

# On the M21s Android 17's NetBpfLoad process receives 6.6.40 from uname()
# despite the booted kernel being 4.14.355. The loader then rejects every
# netd.o section: none has a range covering 6.6, so it creates no
# /sys/fs/bpf/netd_shared maps and netd1shot aborts with reboot_on_failure.
#
# Override only the already-parsed BPF selection cache with KVER(4,14,355).
# The sequence is the eight instructions that assemble and bounds-check the
# uname version before storing it in gKernelVersion. It becomes two MOVs and
# six NOPs. The OS-wide uname result remains unchanged.
if [ "$TETHERING_BPF_PROGRAM_KVER" = "4.14.355" ]; then
    ACTUAL_SHA256="$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)"
    if [ "$ACTUAL_SHA256" = "$PATCHED_9_SHA256" ]; then
        LOG "- Selecting Linux 4.14 netd BPF programs on M21s (native DSCP)"
        HEX_PATCH "$NETBPFLOAD" \
            "a8035eb8e92340b9081d08530841092b62280054e90b40b90801092b22280054" \
            "682c8052c881a0721f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5" > /dev/null || return 1
        FINAL_SHA256="$BPF_KVER_414355_NATIVE_PATCHED_9_SHA256"
    elif [ "$ACTUAL_SHA256" = "$DSCP_SKIPPED_PATCHED_9_SHA256" ]; then
        LOG "- Selecting Linux 4.14 netd BPF programs on M21s (DSCP skipped)"
        HEX_PATCH "$NETBPFLOAD" \
            "a8035eb8e92340b9081d08530841092b62280054e90b40b90801092b22280054" \
            "682c8052c881a0721f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5" > /dev/null || return 1
        FINAL_SHA256="$BPF_KVER_414355_PATCHED_9_SHA256"
    elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_PATCHED_9_SHA256" ] || \
            [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_V_GATE_PATCHED_9_SHA256" ] || \
            [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_NATIVE_PATCHED_9_SHA256" ] || \
            [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256" ]; then
        LOG "- Linux 4.14 netd BPF programs are already selected on M21s"
        FINAL_SHA256="$ACTUAL_SHA256"
    else
        LOGE "Unsupported netbpfload build for M21s BPF program selection: $ACTUAL_SHA256"
        return 1
    fi

    if [ "$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)" != "$FINAL_SHA256" ]; then
        LOGE "netbpfload M21s BPF program-selection patch validation failed"
        return 1
    fi
fi

# Android V has an earlier, independent 4.19 minimum-version gate. It runs
# after the selector cache was initialized and before any object is loaded.
# Branch only around its error return; subsequent per-program 4.14 matching
# and the BPF verifier remain active.
if [ "$TETHERING_BPF_PROGRAM_KVER" = "4.14.355" ]; then
    ACTUAL_SHA256="$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)"
    if [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_NATIVE_PATCHED_9_SHA256" ]; then
        LOG "- Bypassing Android V's 4.19-only NetBpfLoad gate on M21s (native DSCP)"
        HEX_PATCH "$NETBPFLOAD" \
            "690800d01f491071297144394801005429010034c1ffffb0" \
            "690800d01f491071297144394801005409000014c1ffffb0" > /dev/null || return 1
        FINAL_SHA256="$BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256"
    elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_PATCHED_9_SHA256" ]; then
        LOG "- Bypassing Android V's 4.19-only NetBpfLoad gate on M21s"
        HEX_PATCH "$NETBPFLOAD" \
            "690800d01f491071297144394801005429010034c1ffffb0" \
            "690800d01f491071297144394801005409000014c1ffffb0" > /dev/null || return 1
        FINAL_SHA256="$BPF_KVER_414355_V_GATE_PATCHED_9_SHA256"
    elif [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_V_GATE_PATCHED_9_SHA256" ] || \
            [ "$ACTUAL_SHA256" = "$BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256" ]; then
        LOG "- Android V's 4.19-only NetBpfLoad gate is already bypassed on M21s"
        FINAL_SHA256="$ACTUAL_SHA256"
    else
        LOGE "Unsupported netbpfload build for M21s Android V kernel gate: $ACTUAL_SHA256"
        return 1
    fi

    if [ "$(sha256sum "$NETBPFLOAD" | cut -d ' ' -f 1)" != "$FINAL_SHA256" ]; then
        LOGE "netbpfload M21s Android V kernel-gate patch validation failed"
        return 1
    fi
fi

NETD_UPDATABLE="$PAYLOAD/lib64/libnetd_updatable.so"
EXPECTED_NETD_SHA256="eda006b2bc421bb2581b2193c10444b7ee158bf728034e1e57ba8425e82a6386"
PATCHED_NETD_SHA256="3ebd27e5f3a6f6c4efe04672c6b835701c8cf6cec584792e907e75d140bee67f"
EXPECTED_NETD_85_SHA256="b15352158c8633d3a3b743331ce149daa29c6b7d656eed014392da082cf187cc"
BROKEN_PATCHED_NETD_85_SHA256="4a6ba0362a869ee8e91b8317b57614cbd9d77872416543c413262e4c52b10aa2"
PATCHED_NETD_85_SHA256="d62c8a9d351296e992f965e396c52cddc0db435ebd89b02d3c6834ade7b0c0d3"
EXPECTED_NETD_9_SHA256="b201bb4871e76bf68f096892e1358efb51dac1008f42d3b3d4d7637a284817f9"
BROKEN_PATCHED_NETD_9_SHA256="9f424b3d59957f25975260ad9267af6598ae94905988935b397495e8c71f630e"
PATCHED_NETD_9_SHA256="ff780803b29a3fb993c841ca8da6166dcb32c8eb65f216cdab10b3066713ca32"
# Android V has a second, independent legacy-kernel rejection in
# libnetd_updatable. This is intentionally a separate state from the 5.4
# gate above: it preserves the normal continuation and only skips the V
# platform's 4.19 minimum-version error path on the M21s Linux 4.14 kernel.
PATCHED_NETD_9_V_GATE_SHA256="4a149ce65e7f9a052127bd1490edc2af7fe2d11cd8dce2e40d721257e561032e"
# The M21s kernel can run the base BPF framework but cannot load every Android
# 17 networking program.  This state retains the version-gate repair above
# and makes the netd BPF handler non-fatal so an unavailable optional program
# does not trigger init's netd1shot reboot_on_failure.
PATCHED_NETD_9_BPF_NONFATAL_SHA256="ca94a16c778741cbd87fa2dbf4f2db4d8511b22e32e6380232ee7386bc61ecff"
ACTUAL_NETD_SHA256="$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)"

if [ "$ACTUAL_NETD_SHA256" = "$EXPECTED_NETD_SHA256" ]; then
    # libnetd_updatable performs the same API 36/kernel 5.4 check when netd
    # starts. Keeping this gate makes netd abort after NetBpfLoad successfully
    # loaded the kernel-4.19 variants of its maps and programs.
    #
    # Before: b.ls <25Q2+ kernel version unsupported error path>
    # After:  nop
    LOG "- Disabling netd Android 25Q2 kernel 5.4 version gate"
    HEX_PATCH "$NETD_UPDATABLE" \
        "1f01096be9430054e00301aa" \
        "1f01096b1f2003d5e00301aa" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_SHA256" ]; then
    LOG "- netd Android 25Q2 kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$EXPECTED_NETD_85_SHA256" ]; then
    # Like NetBpfLoad above, this TBZ skips the unsupported-kernel error
    # object. Replacing it with NOP would fall through into the error; branch
    # unconditionally to the normal continuation instead.
    LOG "- Disabling netd One UI 8.5 kernel 5.4 version gate"
    HEX_PATCH "$NETD_UPDATABLE" \
        "1f010571c805005448a341398805003600088052" \
        "1f010571c805005448a341392c00001400088052" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_85_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$BROKEN_PATCHED_NETD_85_SHA256" ]; then
    LOG "- Repairing cached netd One UI 8.5 kernel gate patch"
    HEX_PATCH "$NETD_UPDATABLE" \
        "1f010571c805005448a341391f2003d500088052" \
        "1f010571c805005448a341392c00001400088052" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_85_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_85_SHA256" ]; then
    LOG "- netd One UI 8.5 kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_85_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$EXPECTED_NETD_9_SHA256" ]; then
    # Android 17 moved the 25Q2 test. Turn its conditional jump into the same
    # unconditional jump to the supported-kernel continuation.
    LOG "- Disabling netd One UI 9 kernel 5.4 version gate"
    HEX_PATCH "$NETD_UPDATABLE" \
        "687e12531f010571e81c0054680000f008714039881c0036" \
        "687e12531f010571e7000014680000f008714039881c0036" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_9_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$BROKEN_PATCHED_NETD_9_SHA256" ]; then
    # The first Android 17 patch jumped to 0x9678, in the middle of the
    # expected<T> result writeback path, before its destination pointer was
    # initialized. netd consequently wrote through x11=0x12800c and crashed.
    # Branch to 0x9684, the normal continuation used by the original gate.
    LOG "- Repairing cached netd One UI 9 kernel gate branch target"
    HEX_PATCH "$NETD_UPDATABLE" \
        "687e12531f010571e4000014680000f008714039881c0036" \
        "687e12531f010571e7000014680000f008714039881c0036" > /dev/null
    FINAL_NETD_SHA256="$PATCHED_NETD_9_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_SHA256" ]; then
    LOG "- netd One UI 9 kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_9_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_V_GATE_SHA256" ]; then
    LOG "- netd One UI 9 Android V legacy-kernel gate is already disabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_9_V_GATE_SHA256"
elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_BPF_NONFATAL_SHA256" ]; then
    LOG "- netd One UI 9 legacy BPF compatibility fallback is already enabled"
    FINAL_NETD_SHA256="$PATCHED_NETD_9_BPF_NONFATAL_SHA256"
else
    LOGE "Unsupported libnetd_updatable build: $ACTUAL_NETD_SHA256"
    LOGE "Expected a supported One UI 8.0/8.5/9 original or patched build"
    return 1
fi

if [ "$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)" != "$FINAL_NETD_SHA256" ]; then
    LOGE "libnetd_updatable patch validation failed"
    return 1
fi

# On Android V, libnetd_updatable repeats a stricter 4.19 minimum check after
# NetBpfLoad has completed. For Linux 4.14 it takes the error builder that
# returns "V+ platform with kernel version < 4.19.0 is unsupported", causing
# init's netd1shot service to abort and reboot_on_failure to restart the phone.
#
# The target is the `tbz w8, #0, normal_continuation` immediately after the
# platform-version check. Make it an unconditional branch to the same normal
# continuation, retaining every subsequent BPF/map check.
if [ "$TETHERING_BPF_PROGRAM_KVER" = "4.14.355" ]; then
    ACTUAL_NETD_SHA256="$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)"
    if [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_SHA256" ]; then
        LOG "- Bypassing netd Android V's 4.19-only kernel gate on M21s"
        HEX_PATCH "$NETD_UPDATABLE" \
            "08b3403988080036" \
            "08b3403944000014" > /dev/null || return 1
        FINAL_NETD_SHA256="$PATCHED_NETD_9_V_GATE_SHA256"
    elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_V_GATE_SHA256" ] || \
            [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_BPF_NONFATAL_SHA256" ]; then
        LOG "- netd Android V's 4.19-only kernel gate is already bypassed on M21s"
        FINAL_NETD_SHA256="$ACTUAL_NETD_SHA256"
    else
        LOGE "Unsupported libnetd_updatable build for M21s Android V kernel gate: $ACTUAL_NETD_SHA256"
        return 1
    fi

    if [ "$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)" != "$FINAL_NETD_SHA256" ]; then
        LOGE "netd Android V kernel-gate patch validation failed"
        return 1
    fi
fi

# BpfHandler::init() checks every required pinned networking program. The
# Android 17 netd object includes skfilter allowlist/denylist programs, but
# the running M21s 4.14 kernel rejects at least allowlist_xtbpf. Returning its
# error makes libnetd_updatable_init abort, and init subsequently reboots
# because netd1shot has reboot_on_failure. Preserve BpfHandler's attempt to
# initialize all maps/programs, but ignore its aggregate error at the one
# handoff to libnetd_updatable_init. Runtime operations still receive their
# normal BPF syscall errors; only the boot-wide fatal policy is relaxed.
if [ "$TETHERING_BPF_PROGRAM_KVER" = "4.14.355" ]; then
    ACTUAL_NETD_SHA256="$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)"
    if [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_V_GATE_SHA256" ]; then
        LOG "- Making unavailable legacy netd BPF programs non-fatal on M21s"
        HEX_PATCH "$NETD_UPDATABLE" \
            "e86340b9c8040035a81640f9" \
            "e86340b91f2003d5a81640f9" > /dev/null || return 1
        FINAL_NETD_SHA256="$PATCHED_NETD_9_BPF_NONFATAL_SHA256"
    elif [ "$ACTUAL_NETD_SHA256" = "$PATCHED_NETD_9_BPF_NONFATAL_SHA256" ]; then
        LOG "- Unavailable legacy netd BPF programs are already non-fatal on M21s"
        FINAL_NETD_SHA256="$PATCHED_NETD_9_BPF_NONFATAL_SHA256"
    else
        LOGE "Unsupported libnetd_updatable build for M21s BPF fallback: $ACTUAL_NETD_SHA256"
        return 1
    fi

    if [ "$(sha256sum "$NETD_UPDATABLE" | cut -d ' ' -f 1)" != "$FINAL_NETD_SHA256" ]; then
        LOGE "netd M21s BPF fallback patch validation failed"
        return 1
    fi
fi

# Android 17's netd.o still carries dedicated Android T implementations for
# Linux 4.19, but their program metadata caps the platform API at 36.  On API
# 37 NetBpfLoad therefore skips both ingress_stats_4_19_t and
# egress_stats_4_19_t, and netd aborts because their pinned programs do not
# exist.  Extend only these two 4.19 variants to future platform APIs; their
# kernel range remains [4.19, 5.4), so no newer implementation is affected.
NETD_BPF="$PAYLOAD/etc/bpf/mainline/netd.o"
EXPECTED_NETD_BPF_9_SHA256="4418d9cca4dca5ca4ea8cfc2a61cee247946e6fa0d0ec111ed6b10954a9a2e5a"
PATCHED_NETD_BPF_9_SHA256="05cc78cebc8b6fe0b5203096f4cd0246a9bb9eeb2ee3c72cdf2d0dad8d865b24"
PATCHED_NETD_BPF_414_9_SHA256="de859dc1efb34bfc53678b3844daeedb8b52fbc984ec13110775787d162c48e4"
PATCHED_NETD_BPF_414_RETURN_SHA256="012895118a9e32706f0cfab4e04a4ff883e81b8f775ce246c72678b1ca4f8917"
PATCHED_NETD_BPF_414_CONDITIONAL_RETURN_SHA256="38cba2f3cc728c3339c7fdce1dcc5065f25323705b9ede2fe4e386fe8f5c3365"
ACTUAL_NETD_BPF_SHA256="$(sha256sum "$NETD_BPF" | cut -d ' ' -f 1)"

if [ "$ACTUAL_NETD_BPF_SHA256" = "$EXPECTED_NETD_BPF_9_SHA256" ]; then
    if [ "$LEGACY_KERNEL_VERSION" = "4.14" ]; then
        LOG "- Extending netd Android 4.9-4.19 ingress/egress programs to API 37"
        # Linux 4.14 selects the 4.9 <= kernel < 4.19 variants. Their Android
        # T implementations stop at API 35, so API 37 otherwise skips them.
        # Extend only ingress_stats_4_9_t and egress_stats_4_9_t.
        HEX_PATCH "$NETD_BPF" \
            "000009040000130400000000e40c0000ac0d0000" \
            "000009040000130400000000e40c000000000100" > /dev/null || return 1
        HEX_PATCH "$NETD_BPF" \
            "000009040000130400000000e40c0000ac0d0000" \
            "000009040000130400000000e40c000000000100" > /dev/null || return 1
        FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_414_9_SHA256"
    elif [ "$LEGACY_KERNEL_VERSION" = "4.19" ]; then
        LOG "- Extending netd Android 4.19 ingress/egress programs to API 37"
        # android_prog_def: min_kver=4.19, max_kver=5.4, min_api=3300,
        # max_api=3600 -> max_api=65536. The pattern occurs exactly twice, for
        # ingress_stats_4_19_t and egress_stats_4_19_t.
        HEX_PATCH "$NETD_BPF" \
            "000013040000040500000000e40c0000100e0000" \
            "000013040000040500000000e40c000000000100" > /dev/null || return 1
        HEX_PATCH "$NETD_BPF" \
            "000013040000040500000000e40c0000100e0000" \
            "000013040000040500000000e40c000000000100" > /dev/null || return 1
        FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_9_SHA256"
    else
        LOGE "Unsupported legacy kernel version for netd.o: $LEGACY_KERNEL_VERSION"
        return 1
    fi
elif [ "$LEGACY_KERNEL_VERSION" = "4.14" ] && \
        [ "$ACTUAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_414_9_SHA256" ]; then
    LOG "- netd Android 4.9-4.19 programs already support API 37"
    FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_414_9_SHA256"
elif [ "$LEGACY_KERNEL_VERSION" = "4.14" ] && \
        [ "$ACTUAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_414_RETURN_SHA256" ]; then
    LOG "- netd Android 4.9 programs use the first legacy return workaround"
    FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_414_RETURN_SHA256"
elif [ "$LEGACY_KERNEL_VERSION" = "4.14" ] && \
        [ "$ACTUAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_414_CONDITIONAL_RETURN_SHA256" ]; then
    LOG "- netd Android 4.9 programs already use explicit boolean returns"
    FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_414_CONDITIONAL_RETURN_SHA256"
elif [ "$LEGACY_KERNEL_VERSION" = "4.19" ] && \
        [ "$ACTUAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_9_SHA256" ]; then
    LOG "- netd Android 4.19 programs already support API 37"
    FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_9_SHA256"
else
    LOGE "Unsupported Android 17 netd.o build: $ACTUAL_NETD_BPF_SHA256"
    return 1
fi

# Linux 4.14's verifier loses the [0, 1] scalar range of `match` even after
# its `& 1` operation. Preserve the exact boolean semantics with two explicit
# constant-return paths. This also migrates the first MOV-only workaround,
# which proved insufficient on the device verifier.
if [ "$LEGACY_KERNEL_VERSION" = "4.14" ] && { \
        [ "$FINAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_414_9_SHA256" ] || \
        [ "$FINAL_NETD_BPF_SHA256" = "$PATCHED_NETD_BPF_414_RETURN_SHA256" ]; \
        }; then
    LOG "- Materializing netd 4.9 ingress/egress boolean returns on Linux 4.14"

    printf '%s' \
        '5708000001000000b70000000000000045080100010000009500000000000000b7000000010000009500000000000000' | \
        xxd -r -p | dd of="$NETD_BPF" bs=1 seek=$((0x100f8)) conv=notrunc status=none
    printf '%s' \
        'b70000000000000045080100010000009500000000000000b7000000010000009500000000000000' | \
        xxd -r -p | dd of="$NETD_BPF" bs=1 seek=$((0x24cf8)) conv=notrunc status=none
    FINAL_NETD_BPF_SHA256="$PATCHED_NETD_BPF_414_CONDITIONAL_RETURN_SHA256"
fi

if [ "$(sha256sum "$NETD_BPF" | cut -d ' ' -f 1)" != \
        "$FINAL_NETD_BPF_SHA256" ]; then
    LOGE "netd.o legacy-kernel API-range patch validation failed"
    return 1
fi

# dscpPolicy is deliberately restricted by AOSP to Linux 5.15 and newer. It
# scans up to 16 policies with a bounded BPF loop, while pre-5.3 verifiers
# reject every back-edge before doing range analysis. Keep both DSCP files
# present: netbpfload opens their fixed paths before it can classify an object.
# The optional metadata bit is retained while the loader's fatal-error path is
# patched separately; removing the files causes an immediate ENOENT failure.
if [ "$LEGACY_KERNEL_VERSION" = "4.14" ]; then
    DSCP_BPF="$PAYLOAD/etc/bpf/mainline/dscpPolicy.o"
    EXPECTED_DSCP_BPF_9_SHA256="418b9b09c96ed964bc408bff5df8f31e9fd5057d7f2bb56c3704c62c2ebdadec"
    PATCHED_DSCP_BPF_414_9_SHA256="3b9e62946d63e0e3a925080d68f96bc768cbdf22db14c0a14b3b2fde950f04b6"
    ACTUAL_DSCP_BPF_SHA256="$(sha256sum "$DSCP_BPF" | cut -d ' ' -f 1)"

    if [ "$ACTUAL_DSCP_BPF_SHA256" = "$EXPECTED_DSCP_BPF_9_SHA256" ]; then
        LOG "- Marking the Linux 5.15-only DSCP program optional on Linux 4.14"
        HEX_PATCH "$DSCP_BPF" \
            "030000000000000000000000e803000000000f05ffffffff00000000e40c0000" \
            "030000000000000000000000e803000000000f05ffffffff01000000e40c0000" \
            > /dev/null || return 1
        FINAL_DSCP_BPF_SHA256="$PATCHED_DSCP_BPF_414_9_SHA256"
    elif [ "$ACTUAL_DSCP_BPF_SHA256" = "$PATCHED_DSCP_BPF_414_9_SHA256" ]; then
        LOG "- Linux 5.15-only DSCP program is already optional on Linux 4.14"
        FINAL_DSCP_BPF_SHA256="$PATCHED_DSCP_BPF_414_9_SHA256"
    else
        LOGE "Unsupported Android 17 dscpPolicy.o build: $ACTUAL_DSCP_BPF_SHA256"
        return 1
    fi

    if [ "$(sha256sum "$DSCP_BPF" | cut -d ' ' -f 1)" != \
            "$FINAL_DSCP_BPF_SHA256" ]; then
        LOGE "dscpPolicy.o optional-program patch validation failed"
        return 1
    fi
fi

LOG "- Rebuilding apex_payload.img"
"$SRC_DIR/scripts/build_fs_image.sh" "ext4" --no-avb \
    -o "$DECODED/unknown/apex_payload.img" -p "system" \
    "$PAYLOAD" "$PATCH_TMP/file_contexts" "$PATCH_TMP/fs_config" > /dev/null

rm -rf "$PAYLOAD" "$PATCH_TMP/file_contexts" "$PATCH_TMP/fs_config"

LOG "- Signing Tethering APEX payload"
SALT="$(sha256sum "$DECODED/unknown/apex_manifest.pb" | cut -d ' ' -f 1)"
EVAL "avbtool add_hashtree_footer --do_not_generate_fec --algorithm \"SHA256_RSA4096\" --hash_algorithm \"sha256\" --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --prop \"apex.key:com.android.tethering\" --salt \"$SALT\" --image \"$DECODED/unknown/apex_payload.img\""
EVAL "avbtool extract_public_key --key \"$SRC_DIR/security/avb/testkey_rsa4096.pem\" --output \"$DECODED/unknown/apex_pubkey\""

LOG "- Rebuilding uncompressed Tethering APEX"
mkdir -p "$DECODED/build/apk"
cp -a "$DECODED/original/META-INF" "$DECODED/build/apk/META-INF"
EVAL "apktool b -j \"$(nproc)\" \"$DECODED\""

BUILT_APEX="$DECODED/dist/original.apex"
if [ ! -f "$BUILT_APEX" ]; then
    LOGE "Rebuilt Tethering APEX not found"
    return 1
fi

CERT_PREFIX="aosp"
if $ROM_IS_OFFICIAL; then
    CERT_PREFIX="unica"
fi

LOG "- Signing Tethering APEX container"
EVAL "signapk -a 4096 --align-file-size \"$SRC_DIR/security/${CERT_PREFIX}_platform.x509.pem\" \"$SRC_DIR/security/${CERT_PREFIX}_platform.pk8\" \"$BUILT_APEX\" \"$BUILT_APEX.signed\""

# APEXd accepts an uncompressed APEX in place of its CAPEX. Keeping the original
# path also avoids stale filesystem metadata entries during incremental builds.
mv -f "$BUILT_APEX.signed" "$CAPEX"
rm -rf "$PATCH_TMP"

unset CAPEX PATCH_TMP DECODED PAYLOAD LEGACY_KERNEL_VERSION SERVICE_PATCH_DIR \
    TETHERING_BPF_KEEP_DSCP \
    NETBPFLOAD EXPECTED_SHA256 PATCHED_SHA256 \
    EXPECTED_85_SHA256 BROKEN_PATCHED_85_SHA256 \
    Q2_ONLY_PATCHED_85_SHA256 PATCHED_85_SHA256 EXPECTED_9_SHA256 \
    PATCHED_9_SHA256 LEGACY_DSCP_SKIPPED_PATCHED_9_SHA256 \
    LEGACY_BPF_KVER_414355_PATCHED_9_SHA256 \
    LEGACY_BPF_KVER_414355_V_GATE_PATCHED_9_SHA256 \
    DSCP_SKIPPED_PATCHED_9_SHA256 \
    BPF_KVER_414355_PATCHED_9_SHA256 BPF_KVER_414355_V_GATE_PATCHED_9_SHA256 \
    ACTUAL_SHA256 FINAL_SHA256 \
    TETHERING_BPF_PROGRAM_KVER \
    SERVICE_CONNECTIVITY SERVICE_CONNECTIVITY_WORK SERVICE_CONNECTIVITY_PATCH \
    SERVICE_CONNECTIVITY_LOOPBACK_PATCH SERVICE_CONNECTIVITY_LOCNET_PATCH \
    TETHERING_SKIP_SERVICE_PATCHES \
    NETD_UPDATABLE EXPECTED_NETD_SHA256 PATCHED_NETD_SHA256 \
    EXPECTED_NETD_85_SHA256 BROKEN_PATCHED_NETD_85_SHA256 \
    PATCHED_NETD_85_SHA256 EXPECTED_NETD_9_SHA256 \
    BROKEN_PATCHED_NETD_9_SHA256 PATCHED_NETD_9_SHA256 PATCHED_NETD_9_V_GATE_SHA256 \
    PATCHED_NETD_9_BPF_NONFATAL_SHA256 \
    ACTUAL_NETD_SHA256 FINAL_NETD_SHA256 SALT \
    NETD_BPF EXPECTED_NETD_BPF_9_SHA256 PATCHED_NETD_BPF_9_SHA256 \
    PATCHED_NETD_BPF_414_9_SHA256 PATCHED_NETD_BPF_414_RETURN_SHA256 \
    PATCHED_NETD_BPF_414_CONDITIONAL_RETURN_SHA256 \
    ACTUAL_NETD_BPF_SHA256 \
    FINAL_NETD_BPF_SHA256 \
    DSCP_BPF EXPECTED_DSCP_BPF_9_SHA256 PATCHED_DSCP_BPF_414_9_SHA256 \
    ACTUAL_DSCP_BPF_SHA256 FINAL_DSCP_BPF_SHA256 \
    BUILT_APEX CERT_PREFIX
