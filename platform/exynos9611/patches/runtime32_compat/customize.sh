#!/usr/bin/env bash
# Reuse the common runtime implementation after the M21s-specific
# desixtification module has preserved the target ABI advertisement.
source "$SRC_DIR/platform/exynos990/patches/runtime32_compat/customize.sh"
