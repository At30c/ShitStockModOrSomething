#!/usr/bin/env bash
# The shared module selects the M21s-safe branch and skips CgroupKill, which is
# not present in the universal9611 4.14 kernel.
source "$SRC_DIR/platform/exynos990/patches/cgroup_legacy/customize.sh"
