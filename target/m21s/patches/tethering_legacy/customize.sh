#!/usr/bin/env bash

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

# Reuse the audited Android 17 Tethering APEX integration from Exynos 990,
# selecting the netd program metadata range that actually covers Linux 4.14.
export TETHERING_LEGACY_KERNEL_VERSION="4.14"
# The M21 kernel identifies itself as 4.14.355, but this Android 17
# NetBpfLoad build receives 6.6.40 while it builds its BPF object-selection
# cache. Keep uname untouched and override only that cache in the shared
# compatibility module so netd.o selects its 4.14/4.9 implementations.
export TETHERING_BPF_PROGRAM_KVER="4.14.355"
# The M21 kernel patch set now verifies dscpPolicy.o (bounded-loops backport),
# so stop the shared module from skipping the Linux 5.15+ DSCP objects. The
# loader must attempt them natively; version gates and the program-selection
# cache below are still applied. The "optional" metadata bit on dscpPolicy.o
# itself remains as a safety net in case the verifier still rejects it.
export TETHERING_BPF_KEEP_DSCP="1"
export TETHERING_SERVICE_PATCH_DIR="$SRC_DIR/platform/exynos990/patches/tethering_legacy/patches/service-connectivity.jar"
export TETHERING_APP_OPT_IN_PATCH="$MODPATH/patches/service-connectivity.jar/0004-disable-satellite-app-routing-on-F415F.patch"

source "$SRC_DIR/platform/exynos990/patches/tethering_legacy/customize.sh"
RESULT=$?

unset TETHERING_LEGACY_KERNEL_VERSION TETHERING_BPF_PROGRAM_KVER TETHERING_BPF_KEEP_DSCP TETHERING_SERVICE_PATCH_DIR TETHERING_APP_OPT_IN_PATCH
return "$RESULT"
