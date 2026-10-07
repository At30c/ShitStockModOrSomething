#!/usr/bin/env bash

# Build the Exynos9611Development universal9611 kernel with the M21 board
# defconfig and replace only the kernel payload inside the target stock boot
# image. The stock ramdisk/DTB/cmdline are deliberately retained because the
# current M21s target is assembled from the SM-F415F firmware package. Keep
# its F41 DTBO intact: it describes the physical board and its M31 sensorhub.

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

KERNEL_REPO="https://github.com/Exynos9611Development/android_kernel_samsung_universal9611.git"
KERNEL_REF="SomethingNew-15-OUI"
KERNEL_COMMIT="933cc29fad7b2cfcfd0a529684c7377cbd6cd8cd"
KERNEL_TARGET="m21"
KERNEL_TMP_DIR="$OUT_DIR/kernel_tmp-$TARGET_PLATFORM"
KERNEL_CACHE_VERSION="7"
KERNEL_CACHE_FILE="$KERNEL_TMP_DIR/.unica-kernel-cache"
KERNEL_PATCH_DIR="$MODPATH/patches"
KERNEL_TOOLS_DIR="$TOOLS_DIR/bin"
KERNEL_IMAGE="$KERNEL_TMP_DIR/out/arch/arm64/boot/Image"
STOCK_BOOT_IMAGE="$WORK_DIR/kernel/boot.img"
STOCK_DTBO_IMAGE="$WORK_DIR/kernel/dtbo.img"
SENSORHUB_FIRMWARE="$KERNEL_TMP_DIR/firmware/sensorhub/shub_ramen_m31.fw"
BOOT_WORK_DIR="$KERNEL_TMP_DIR/boot-repack"
KERNEL_TOOLCHAIN_DIR="$KERNEL_TMP_DIR/toolchain"
KERNEL_TOOLCHAIN_BIN="$KERNEL_TOOLCHAIN_DIR/bin"
# The manager APK shipped through unica/mods/preload is signed with
# prebuilts/kernelsu-next/ksu-manager.jks. Embed its v2 signer certificate
# size/hash so the kernel recognises exactly that manager; the official
# KernelSU-Next release key (and the default 0x3e6/79e590...) must not be used.
KSU_NEXT_MANAGER_SIZE="0x308"
KSU_NEXT_MANAGER_HASH="8b4967968e3418f3ec3bf00fa2e7c2fbfbfb9813d220a4d5a1a9f2b0b1b6edaf"

case "$KERNEL_TMP_DIR" in
    "$OUT_DIR"/kernel_tmp-exynos9611) ;;
    *) ABORT "Refusing to use an unexpected Exynos 9611 kernel path: $KERNEL_TMP_DIR"; return 1 ;;
esac

for TOOL in "$KERNEL_TOOLS_DIR/unpack_bootimg" "$KERNEL_TOOLS_DIR/mkbootimg"; do
    if [ ! -x "$TOOL" ]; then
        ABORT "Missing required boot-image tool: $TOOL"
        return 1
    fi
done
if [ ! -s "$STOCK_BOOT_IMAGE" ]; then
    ABORT "Target firmware did not provide kernel/boot.img"
    return 1
fi

CLONE_KERNEL()
{
    if [ -d "$KERNEL_TMP_DIR" ] && [ ! -d "$KERNEL_TMP_DIR/.git" ]; then
        if [ -n "$(find "$KERNEL_TMP_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            ABORT "Existing Exynos9611 kernel mount is not a git checkout: $KERNEL_TMP_DIR"
            return 1
        fi
        rmdir -- "$KERNEL_TMP_DIR"
    fi

    if [ ! -d "$KERNEL_TMP_DIR/.git" ]; then
        LOG "- Cloning universal9611 kernel ($KERNEL_REF)"
        EVAL "git clone --recurse-submodules --branch \"$KERNEL_REF\" --single-branch \"$KERNEL_REPO\" \"$KERNEL_TMP_DIR\"" || return 1
    else
        LOG "- Reusing mounted universal9611 kernel checkout"
        if [ "$(git -C "$KERNEL_TMP_DIR" rev-parse HEAD 2>/dev/null)" != "$KERNEL_COMMIT" ]; then
            LOG "- Updating the mounted checkout to the pinned kernel revision"
            EVAL "git -C \"$KERNEL_TMP_DIR\" fetch --depth=1 origin \"$KERNEL_REF\"" || return 1
        fi
    fi

    if [ "$(git -C "$KERNEL_TMP_DIR" rev-parse HEAD 2>/dev/null)" != "$KERNEL_COMMIT" ]; then
        EVAL "git -C \"$KERNEL_TMP_DIR\" checkout --detach --force \"$KERNEL_COMMIT\"" || return 1
    fi
    EVAL "git -C \"$KERNEL_TMP_DIR\" submodule update --init --recursive" || return 1
    [ "$(git -C "$KERNEL_TMP_DIR" rev-parse HEAD)" = "$KERNEL_COMMIT" ] ||
        ABORT "Kernel checkout is not pinned to $KERNEL_COMMIT"
}

GET_KERNEL_PATCHSET_DIGEST()
{
    local PATCH
    local -a PATCHES=("$KERNEL_PATCH_DIR"/*.patch)

    if [ ! -e "${PATCHES[0]}" ]; then
        printf 'none\n'
        return 0
    fi
    for PATCH in "${PATCHES[@]}"; do
        printf '%s  %s\n' "$(GET_FILE_SHA256 "$PATCH")" "$(basename "$PATCH")"
    done | sha256sum | cut -d ' ' -f 1
}

KERNEL_PATCH_ALREADY_PRESENT()
{
    local PATCH_NAME="$1"

    # Patches may already be present in the mounted tree (incremental builds).
    # Use semantic checks so git apply --check/reverse-check don't block.
    case "$PATCH_NAME" in
        0009-bpf-verifier-accept-bounded-loops.patch)
            local HEADER="$KERNEL_TMP_DIR/include/linux/bpf_verifier.h"
            local VERIFIER="$KERNEL_TMP_DIR/kernel/bpf/verifier.c"
            [ -f "$HEADER" ] && [ -f "$VERIFIER" ] || return 1
            grep -Eq '^[[:space:]]*u32 branches;' "$HEADER" || return 1
            grep -Eq '^[[:space:]]*struct bpf_verifier_state \*branch_parent;' "$HEADER" || return 1
            grep -Eq '^[[:space:]]*u32 prev_insn_processed, insn_processed;' "$HEADER" || return 1
            grep -Eq '^[[:space:]]*u32 prev_jmps_processed, jmps_processed;' "$HEADER" || return 1
            grep -Eq '^#define BPF_COMPLEXITY_LIMIT_INSNS[[:space:]]+1000000$' "$VERIFIER" || return 1
            grep -Eq '^#define BPF_COMPLEXITY_LIMIT_STACK[[:space:]]+8192$' "$VERIFIER" || return 1
            grep -q 'bpf_verifier_log_needed(&verifier_log)' "$VERIFIER" || return 1
            grep -q '^static void update_branch_counts(struct bpf_verifier_state \*st)' "$VERIFIER" || return 1
            grep -q 'bool loop_ok)' "$VERIFIER" || return 1
            grep -q 'if (loop_ok && env->allow_ptr_leaks)' "$VERIFIER" || return 1
            grep -q '^static bool states_maybe_looping(struct bpf_verifier_state \*old,' "$VERIFIER" || return 1
            grep -q 'if (sl->state.branches)' "$VERIFIER" || return 1
            grep -q 'bool add_new_state = false' "$VERIFIER" || return 1
            grep -q '^miss:' "$VERIFIER" || return 1
            grep -q 'env->prev_insn_processed = env->insn_processed' "$VERIFIER" || return 1
            grep -q 'env->prev_jmps_processed = env->jmps_processed' "$VERIFIER" || return 1
            grep -q 'cur->branch_parent = &new_sl->state' "$VERIFIER" || return 1
            grep -q 'state->branches = 1' "$VERIFIER" || return 1
            grep -q '++env->insn_processed' "$VERIFIER" || return 1
            grep -q 'env->jmps_processed++' "$VERIFIER" || return 1
            grep -q 'update_branch_counts(env->cur_state)' "$VERIFIER" || return 1
            grep -q 'env->allow_ptr_leaks = capable(CAP_SYS_ADMIN)' "$VERIFIER" || return 1
            return 0
            ;;
        0011-bpf-verifier-accept-pseudo-map-value.patch)
            [ -f "$KERNEL_TMP_DIR/include/uapi/linux/bpf.h" ] || return 1
            [ -f "$KERNEL_TMP_DIR/include/linux/bpf.h" ] || return 1
            [ -f "$KERNEL_TMP_DIR/include/linux/bpf_verifier.h" ] || return 1
            [ -f "$KERNEL_TMP_DIR/kernel/bpf/arraymap.c" ] || return 1
            [ -f "$KERNEL_TMP_DIR/kernel/bpf/verifier.c" ] || return 1
            grep -q '#define BPF_PSEUDO_MAP_VALUE' "$KERNEL_TMP_DIR/include/uapi/linux/bpf.h" || return 1
            grep -q 'map_direct_value_addr' "$KERNEL_TMP_DIR/include/linux/bpf.h" || return 1
            grep -q 'map_index' "$KERNEL_TMP_DIR/include/linux/bpf_verifier.h" || return 1
            grep -q 'array_map_direct_value_addr' "$KERNEL_TMP_DIR/kernel/bpf/arraymap.c" || return 1
            grep -q 'invalid access to map value pointer, value_size' "$KERNEL_TMP_DIR/kernel/bpf/verifier.c" || return 1
            return 0
            ;;
        0012-bpf-ringbuf-backport.patch)
            [ -f "$KERNEL_TMP_DIR/include/uapi/linux/bpf.h" ] || return 1
            [ -f "$KERNEL_TMP_DIR/include/linux/bpf_types.h" ] || return 1
            [ -f "$KERNEL_TMP_DIR/include/linux/bpf.h" ] || return 1
            [ -f "$KERNEL_TMP_DIR/kernel/bpf/ringbuf.c" ] || return 1
            grep -q 'BPF_MAP_TYPE_RINGBUF' "$KERNEL_TMP_DIR/include/uapi/linux/bpf.h" || return 1
            grep -q 'BPF_MAP_TYPE_RINGBUF' "$KERNEL_TMP_DIR/include/linux/bpf_types.h" || return 1
            grep -q 'bpf_ringbuf_' "$KERNEL_TMP_DIR/include/linux/bpf.h" || return 1
            grep -q 'ringbuf_reserve' "$KERNEL_TMP_DIR/kernel/bpf/syscall.c" 2>/dev/null || grep -q 'bpf_ringbuf_reserve' "$KERNEL_TMP_DIR/include/linux/bpf.h" >/dev/null 2>&1
            [ -f "$KERNEL_TMP_DIR/kernel/bpf/ringbuf.c" ] || return 1
            return 0
            ;;
    esac

    return 1
}

APPLY_KERNEL_PATCHES()
{
    local PATCH
    local -a PATCHES=("$KERNEL_PATCH_DIR"/*.patch)

    if [ ! -e "${PATCHES[0]}" ]; then
        LOG "- No Exynos 9611 kernel compatibility patches are configured"
        return 0
    fi

    for PATCH in "${PATCHES[@]}"; do
        if git -C "$KERNEL_TMP_DIR" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
            LOG "- Kernel patch already applied: $(basename "$PATCH")"
        elif KERNEL_PATCH_ALREADY_PRESENT "$(basename "$PATCH")"; then
            LOG "- Kernel patch already applied (semantic check): $(basename "$PATCH")"
        elif git -C "$KERNEL_TMP_DIR" apply --check "$PATCH" >/dev/null 2>&1; then
            LOG "- Applying kernel compatibility patch: $(basename "$PATCH")"
            EVAL "git -C \"$KERNEL_TMP_DIR\" apply --whitespace=nowarn \"$PATCH\"" || return 1
        else
            ABORT "Kernel patch does not apply cleanly: ${PATCH//$SRC_DIR\//}"
            return 1
        fi
    done
}

GET_FILE_SHA256()
{
    sha256sum "$1" | cut -d ' ' -f 1
}

GET_KERNEL_CACHE_KEY()
{
    {
        printf 'version=%s\n' "$KERNEL_CACHE_VERSION"
        git -C "$KERNEL_TMP_DIR" rev-parse HEAD
        git -C "$KERNEL_TMP_DIR" diff --no-ext-diff --binary
        git -C "$KERNEL_TMP_DIR" diff --cached --no-ext-diff --binary
        git -C "$KERNEL_TMP_DIR" submodule status --recursive
        printf 'integration=%s\n' "$(GET_FILE_SHA256 "$MODPATH/customize.sh")"
        printf 'patchset=%s\n' "$(GET_KERNEL_PATCHSET_DIGEST)"
        printf 'target=%s oneui=1\n' "$KERNEL_TARGET"
        printf 'ksu_manager=%s/%s\n' "$KSU_NEXT_MANAGER_SIZE" "$KSU_NEXT_MANAGER_HASH"
        printf 'clang=%s\n' "$(readlink -f "$KERNEL_TOOLCHAIN_BIN/clang")"
        "$KERNEL_TOOLCHAIN_BIN/clang" --version 2>/dev/null | head -n1
    } | sha256sum | cut -d ' ' -f 1
}

GET_CACHE_VALUE()
{
    sed -n "s/^$2=//p" "$1" | head -n 1
}

KERNEL_CACHE_IS_VALID()
{
    [ -f "$KERNEL_CACHE_FILE" ] || return 1
    [ "$(GET_CACHE_VALUE "$KERNEL_CACHE_FILE" version)" = "$KERNEL_CACHE_VERSION" ] || return 1
    [ "$(GET_CACHE_VALUE "$KERNEL_CACHE_FILE" target)" = "$KERNEL_TARGET" ] || return 1
    [ "$(GET_CACHE_VALUE "$KERNEL_CACHE_FILE" key)" = "$KERNEL_CACHE_KEY" ] || return 1
    [ -s "$KERNEL_IMAGE" ] || return 1
    [ "$(GET_FILE_SHA256 "$KERNEL_IMAGE")" = "$(GET_CACHE_VALUE "$KERNEL_CACHE_FILE" image_sha256)" ] || return 1
    return 0
}

WRITE_KERNEL_CACHE_MANIFEST()
{
    local TEMP_FILE="${KERNEL_CACHE_FILE}.tmp"
    {
        printf 'version=%s\n' "$KERNEL_CACHE_VERSION"
        printf 'target=%s\n' "$KERNEL_TARGET"
        printf 'key=%s\n' "$KERNEL_CACHE_KEY"
        printf 'commit=%s\n' "$(git -C "$KERNEL_TMP_DIR" rev-parse HEAD)"
        printf 'image_sha256=%s\n' "$(GET_FILE_SHA256 "$KERNEL_IMAGE")"
    } > "$TEMP_FILE" || return 1
    mv -f -- "$TEMP_FILE" "$KERNEL_CACHE_FILE"
}

VALIDATE_BUILT_KERNEL()
{
    [ -s "$KERNEL_IMAGE" ] || {
        ABORT "universal9611 build did not produce Image"
        return 1
    }
    [ -s "$KERNEL_TMP_DIR/out/.config" ] || {
        ABORT "universal9611 build did not produce the M21 kernel configuration"
        return 1
    }
    grep -q '^CONFIG_SENSORS_SSP_M21=y$' "$KERNEL_TMP_DIR/out/.config" || {
        ABORT "universal9611 build did not select CONFIG_SENSORS_SSP_M21"
        return 1
    }
    if grep -q '^CONFIG_SENSORS_SSP_M31=y$' "$KERNEL_TMP_DIR/out/.config"; then
        ABORT "universal9611 build selected the M31 sensor profile instead of M21"
        return 1
    fi
    grep -q '^CONFIG_MALI_BIFROST_R32P1=y$' "$KERNEL_TMP_DIR/out/.config" || {
        ABORT "universal9611 build did not select the M21 stock Mali r32p1 DDK"
        return 1
    }
    if grep -q '^CONFIG_MALI_BIFROST_R38P1=y$' "$KERNEL_TMP_DIR/out/.config"; then
        ABORT "universal9611 build selected the incompatible Mali r38p1 DDK"
        return 1
    fi
    grep -aFq 'sensorhub/shub_ramen_m21.fw' "$KERNEL_IMAGE" || {
        ABORT "M21 kernel Image does not contain the required sensorhub firmware"
        return 1
    }
    if grep -aFq 'sensorhub/shub_ramen_m31.fw' "$KERNEL_IMAGE"; then
        ABORT "M21 kernel Image unexpectedly contains the M31 sensorhub firmware"
        return 1
    fi

    # The retained stock SM-F415F DTBO declares gw1 (rear, module id 62),
    # imx616 (front, module id 121), gc5035 and 4ha.  Without the matching
    # CIS objects the FIMC-IS module table can never resolve those ids and
    # CameraService removes every camera because the camtype stays
    # UNKNOWN_UNKNOWN_FIMC_IS.
    local CAMERA_CIS_REQUIRED="CONFIG_CAMERA_CIS_GW1_OBJ CONFIG_CAMERA_CIS_IMX616_OBJ CONFIG_CAMERA_CIS_GC5035_OBJ CONFIG_CAMERA_CIS_4HA_OBJ"
    local CAMERA_CIS_FORBIDDEN="CONFIG_CAMERA_CIS_GM2_OBJ CONFIG_CAMERA_CIS_HI2021Q_OBJ"
    local CAMERA_CIS_SYMBOL
    for CAMERA_CIS_SYMBOL in $CAMERA_CIS_REQUIRED; do
        grep -q "^${CAMERA_CIS_SYMBOL}=y$" "$KERNEL_TMP_DIR/out/.config" || {
            ABORT "universal9611 build did not select the F41 sensor ${CAMERA_CIS_SYMBOL}"
            return 1
        }
    done
    for CAMERA_CIS_SYMBOL in $CAMERA_CIS_FORBIDDEN; do
        if grep -q "^${CAMERA_CIS_SYMBOL}=y$" "$KERNEL_TMP_DIR/out/.config"; then
            ABORT "universal9611 build selected the absent M21 sensor ${CAMERA_CIS_SYMBOL}"
            return 1
        fi
    done
    # CAMERA_FXT_V41 carries the F41 sensor rails and gw1/imx616 EEPROM maps;
    # CAMERA_MMS_V21 is the mismatched M21 profile.
    grep -q '^CONFIG_CAMERA_FXT_V41=y$' "$KERNEL_TMP_DIR/out/.config" || {
        ABORT "universal9611 build did not select the F41 FIMC-IS profile CONFIG_CAMERA_FXT_V41"
        return 1
    }
    if grep -q '^CONFIG_CAMERA_MMS_V21=y$' "$KERNEL_TMP_DIR/out/.config"; then
        ABORT "universal9611 build selected the M21 FIMC-IS profile CONFIG_CAMERA_MMS_V21"
        return 1
    fi
    grep -q '^CONFIG_CAMERA_ACT_DW9817_OBJ=y$' "$KERNEL_TMP_DIR/out/.config" || {
        ABORT "universal9611 build did not select the F41 actuator CONFIG_CAMERA_ACT_DW9817_OBJ"
        return 1
    }

    # The CIS drivers and their module wrappers are what register module ids
    # 62/121.  Object file names are not embedded in a linked vmlinux, so verify
    # that the objects were actually built instead of grepping the Image.
    local CIS_OBJECTS
    CIS_OBJECTS="cis/fimc-is-cis-gw1.o cis/fimc-is-cis-imx616.o modules/fimc-is-device-module-gw1.o modules/fimc-is-device-module-imx616.o"
    local CIS_OBJECT
    for CIS_OBJECT in $CIS_OBJECTS; do
        [ -s "$KERNEL_TMP_DIR/out/drivers/media/platform/exynos/fimc-is2/sensor/module_framework/$CIS_OBJECT" ] || {
            ABORT "universal9611 build did not produce the F41 camera object ${CIS_OBJECT}"
            return 1
        }
    done
}

PREPARE_KERNEL_TOOLCHAIN()
{
    local TOOLCHAIN_ROOT="${EXYNOS9611_TOOLCHAIN_DIR:-}"
    local CANDIDATE
    local TOOL
    local SOURCE_BIN
    local -a CANDIDATES=()

    if [ -n "$TOOLCHAIN_ROOT" ]; then
        # An explicit override is authoritative; silently falling back to a
        # different compiler would make a supposedly pinned kernel build
        # irreproducible.
        CANDIDATES+=("$TOOLCHAIN_ROOT")
    else
        # Prefer a matching AOSP prebuilt when the caller has one in the
        # source tree, then fall back to the LLVM package on the build host.
        CANDIDATES+=(
            "$SRC_DIR/prebuilts/clang/host/linux-x86/clang-r383902b1"
            "$SRC_DIR/prebuilts/clang/host/linux-x86/clang-r383902"
            "$OUT_DIR/tools/clang-r383902b1"
        )
        while IFS= read -r CANDIDATE; do
            CANDIDATES+=("$CANDIDATE")
        done < <(find /usr/lib -mindepth 1 -maxdepth 1 -type d -name 'llvm-*' | sort -Vr)
    fi

    for CANDIDATE in "${CANDIDATES[@]}"; do
        [ -x "$CANDIDATE/bin/clang" ] || continue
        TOOLCHAIN_ROOT="$CANDIDATE"
        break
    done
    if [ -z "$TOOLCHAIN_ROOT" ] || [ ! -x "$TOOLCHAIN_ROOT/bin/clang" ]; then
        ABORT "No usable LLVM toolchain found. Set EXYNOS9611_TOOLCHAIN_DIR to a toolchain containing bin/clang"
        return 1
    fi

    if [ -e "$KERNEL_TOOLCHAIN_DIR" ] && [ ! -f "$KERNEL_TOOLCHAIN_DIR/.unica-managed" ]; then
        if [ ! -x "$KERNEL_TOOLCHAIN_BIN/clang" ]; then
            ABORT "Existing kernel toolchain is incomplete: $KERNEL_TOOLCHAIN_BIN/clang"
            return 1
        fi
        LOG "- Reusing existing universal9611 toolchain: $KERNEL_TOOLCHAIN_DIR"
        return 0
    fi

    rm -rf -- "$KERNEL_TOOLCHAIN_DIR"
    mkdir -p "$KERNEL_TOOLCHAIN_BIN"
    printf '%s\n' "$TOOLCHAIN_ROOT" > "$KERNEL_TOOLCHAIN_DIR/.unica-managed"

    # build_kernel.py requires ./toolchain/bin/clang. Keep this staging
    # directory inside the checkout while leaving the compiler outside it,
    # so the large prebuilt is never copied into OUT_DIR or the repository.
    for TOOL in clang clang++ ld.lld llvm-as llvm-ar llvm-objdump llvm-readelf \
        llvm-nm llvm-objcopy llvm-strip; do
        [ -x "$TOOLCHAIN_ROOT/bin/$TOOL" ] || {
            ABORT "LLVM toolchain is missing bin/$TOOL: $TOOLCHAIN_ROOT"
            return 1
        }
        ln -s -- "$TOOLCHAIN_ROOT/bin/$TOOL" "$KERNEL_TOOLCHAIN_BIN/$TOOL"
    done

    # The 4.14 Makefile overrides READELF with the CROSS_COMPILE-prefixed
    # name even under LLVM=1. Point those probes at the same LLVM utilities;
    # no native aarch64 GCC/binutils package is required for LLVM_IAS=1.
    for TOOL in readelf objcopy objdump nm ar strip; do
        case "$TOOL" in
            readelf) SOURCE_BIN="$KERNEL_TOOLCHAIN_BIN/llvm-readelf" ;;
            objcopy) SOURCE_BIN="$KERNEL_TOOLCHAIN_BIN/llvm-objcopy" ;;
            objdump) SOURCE_BIN="$KERNEL_TOOLCHAIN_BIN/llvm-objdump" ;;
            nm) SOURCE_BIN="$KERNEL_TOOLCHAIN_BIN/llvm-nm" ;;
            ar) SOURCE_BIN="$KERNEL_TOOLCHAIN_BIN/llvm-ar" ;;
            strip) SOURCE_BIN="$KERNEL_TOOLCHAIN_BIN/llvm-strip" ;;
        esac
        ln -s -- "$SOURCE_BIN" "$KERNEL_TOOLCHAIN_BIN/aarch64-linux-gnu-$TOOL"
    done

    if [[ "$TOOLCHAIN_ROOT" == /usr/lib/llvm-* ]]; then
        LOG "- Using host LLVM fallback ($TOOLCHAIN_ROOT); set EXYNOS9611_TOOLCHAIN_DIR to pin AOSP clang-r383902"
    else
        LOG "- Using kernel toolchain: $TOOLCHAIN_ROOT"
    fi
}

BUILD_KERNEL_IMAGE()
{
    LOG "- Building Something New kernel for $KERNEL_TARGET (One UI)"
    export KSU_NEXT_MANAGER_SIZE KSU_NEXT_MANAGER_HASH
    cd "$KERNEL_TMP_DIR" || return 1
    # build_kernel.py selects exynos9611-m21_defconfig, oneui.config and
    # then emits out/arch/arm64/boot/Image.
    KERNEL_CACHE_KEY="$(GET_KERNEL_CACHE_KEY)" || return 1
    if KERNEL_CACHE_IS_VALID; then
        VALIDATE_BUILT_KERNEL || return 1
        return 0
    fi
    LOG "- Kernel cache is missing or outdated; compiling the mounted source"
    # LLVM 20+ diagnoses the old kernel's intentionally uninitialized const
    # module-parameter placeholders as Werror.  This is a compiler warning,
    # not a runtime/kernel correctness check; keep the rest of the kernel's
    # Werror policy intact and append (rather than overwrite) caller flags.
    local SAVED_KCFLAGS="${KCFLAGS-}"
    local SAVED_KERNEL_BUILD_DEBUG="${KERNEL_BUILD_DEBUG-}"
    local SAVED_KERNEL_BUILD_LOG="${KERNEL_BUILD_LOG-}"
    local CLANG_MAJOR
    CLANG_MAJOR="$("$KERNEL_TOOLCHAIN_BIN/clang" --version 2>/dev/null |
        sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p' | head -n1)"
    if [[ "$CLANG_MAJOR" =~ ^[0-9]+$ ]] && [ "$CLANG_MAJOR" -ge 20 ]; then
        local LLVM21_COMPAT_FLAGS="-Wno-default-const-init-field-unsafe -Wno-default-const-init-var-unsafe"
        if [[ -n "$KCFLAGS" ]]; then
            export KCFLAGS="$KCFLAGS $LLVM21_COMPAT_FLAGS"
        else
            export KCFLAGS="$LLVM21_COMPAT_FLAGS"
        fi
    fi
    # Keep the kernel build incremental and expose the real compiler/linker
    # diagnostics. The log lives outside the cleaned kernel output directory
    # so a failed build remains inspectable for the next attempt.
    export KERNEL_BUILD_DEBUG=1
    export KERNEL_BUILD_LOG="$KERNEL_TMP_DIR/kernel-build.log"
    if ! python3 build_kernel.py --target="$KERNEL_TARGET" --oneui --allow-dirty; then
        export KCFLAGS="$SAVED_KCFLAGS"
        export KERNEL_BUILD_DEBUG="$SAVED_KERNEL_BUILD_DEBUG"
        export KERNEL_BUILD_LOG="$SAVED_KERNEL_BUILD_LOG"
        cd "$SRC_DIR" || return 1
        return 1
    fi
    export KCFLAGS="$SAVED_KCFLAGS"
    export KERNEL_BUILD_DEBUG="$SAVED_KERNEL_BUILD_DEBUG"
    export KERNEL_BUILD_LOG="$SAVED_KERNEL_BUILD_LOG"
    cd "$SRC_DIR" || return 1
    VALIDATE_BUILT_KERNEL || return 1
    KERNEL_CACHE_KEY="$(GET_KERNEL_CACHE_KEY)" || return 1
    WRITE_KERNEL_CACHE_MANIFEST || ABORT "Could not write the verified kernel cache manifest"
}

REPACK_BOOT_IMAGE()
{
    local -a MKBOOTIMG_ARGS=()
    local ARG_INDEX
    local HAS_KERNEL=false
    local NEW_BOOT="$BOOT_WORK_DIR/boot.img"

    rm -rf -- "$BOOT_WORK_DIR"
    mkdir -p "$BOOT_WORK_DIR/unpacked"
    EVAL "\"$KERNEL_TOOLS_DIR/unpack_bootimg\" --boot_img \"$STOCK_BOOT_IMAGE\" --out \"$BOOT_WORK_DIR/unpacked\" --format mkbootimg -0 > \"$BOOT_WORK_DIR/mkbootimg.args\"" || return 1

    while IFS= read -r -d '' ARG; do
        MKBOOTIMG_ARGS+=("$ARG")
    done < "$BOOT_WORK_DIR/mkbootimg.args"

    for ((ARG_INDEX = 0; ARG_INDEX < ${#MKBOOTIMG_ARGS[@]}; ARG_INDEX++)); do
        if [[ "${MKBOOTIMG_ARGS[ARG_INDEX]}" == "--kernel" ]]; then
            [ $((ARG_INDEX + 1)) -lt ${#MKBOOTIMG_ARGS[@]} ] ||
                ABORT "unpack_bootimg returned --kernel without a value"
            MKBOOTIMG_ARGS[ARG_INDEX + 1]="$KERNEL_IMAGE"
            HAS_KERNEL=true
            break
        fi
    done
    $HAS_KERNEL || ABORT "Could not locate --kernel in unpack_bootimg output"

    EVAL "\"$KERNEL_TOOLS_DIR/mkbootimg\" \"\${MKBOOTIMG_ARGS[@]}\" --output \"$NEW_BOOT\"" || return 1
    [ -s "$NEW_BOOT" ] || ABORT "mkbootimg did not produce the repacked boot image"

    if [ "$TARGET_BOOT_PARTITION_SIZE" != "none" ] &&
            [ "$(stat -c '%s' "$NEW_BOOT")" -gt "$TARGET_BOOT_PARTITION_SIZE" ]; then
        ABORT "Repacked boot image exceeds TARGET_BOOT_PARTITION_SIZE"
    fi

    EVAL "\"$KERNEL_TOOLS_DIR/unpack_bootimg\" --boot_img \"$NEW_BOOT\" --out \"$BOOT_WORK_DIR/verify\" --format info > \"$BOOT_WORK_DIR/verify.txt\"" || return 1
    cmp -s "$KERNEL_IMAGE" "$BOOT_WORK_DIR/verify/kernel" ||
        ABORT "Repacked boot image does not contain the freshly built kernel"

    cp -f -- "$NEW_BOOT" "$STOCK_BOOT_IMAGE"
    LOG "- Installed verified universal9611 kernel into work_dir/kernel/boot.img"
}

VALIDATE_KERNEL_TARGET()
{
    local DEFCONFIG="$KERNEL_TMP_DIR/arch/arm64/configs/exynos9611-${KERNEL_TARGET}_defconfig"
    [ -f "$DEFCONFIG" ] || {
        ABORT "Pinned universal9611 source has no ${KERNEL_TARGET} defconfig: $DEFCONFIG"
        return 1
    }
}

CLONE_KERNEL || return 1
VALIDATE_KERNEL_TARGET || return 1
APPLY_KERNEL_PATCHES || return 1
PREPARE_KERNEL_TOOLCHAIN || return 1
BUILD_KERNEL_IMAGE || return 1
REPACK_BOOT_IMAGE || return 1
