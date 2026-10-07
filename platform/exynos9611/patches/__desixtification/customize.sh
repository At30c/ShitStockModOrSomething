#!/usr/bin/env bash
# The implementation is shared with the audited Exynos 990 stack. Its target
# branch preserves the F415F 32-bit ABI properties instead of forcing the
# Exynos 990 zygote64-only contract. Always use the merged mode here: the
# standalone diagnostic mode materializes a regular ARM32 linker in
# /system/bin, which conflicts with the Runtime APEX links needed by M21s.
EXYNOS990_RUNTIME32_APEX_MODE=merged
source "$SRC_DIR/platform/exynos990/patches/__desixtification/customize.sh"
unset EXYNOS990_RUNTIME32_APEX_MODE
