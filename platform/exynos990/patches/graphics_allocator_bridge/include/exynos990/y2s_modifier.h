// Copyright (c) 2026 At30c
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// Decoder for the 32-bit packed layout value used by the Exynos 990 private
// handle. This is deliberately independent from the S26+ SGR handle.
//
// Important: the exported symbol named
// mali_gralloc_get_format_internal() reads +0x30 (frameworkFormat) in the
// audited y2s blob. The vendor metadata class reads +0x48 as its actual
// internal_format and +0x50 as alloc_format. The Stable-C mapper now reads
// +0x48 directly only after validating the native-handle header; a high-word
// extension is ignored only for a low32 value proven to be linear. The
// exported symbol is retained for diagnostics and probe compatibility.

#include <drm/drm_fourcc.h>

#include <cstdint>

namespace exynos990 {

constexpr uint32_t kY2sInternalBaseMask = 0x0000ffffU;
constexpr uint32_t kY2sAfbcBasic = 1U << 16;
constexpr uint32_t kY2sAfbcSplit = 1U << 17;
constexpr uint32_t kY2sAfbcWide = 1U << 19;
constexpr uint32_t kY2sAfbcTiledHeaders = 1U << 24;
constexpr uint32_t kY2sKnownInternalModifiers =
        kY2sAfbcBasic | kY2sAfbcSplit | kY2sAfbcWide | kY2sAfbcTiledHeaders;

// Returns false for an unknown/private combination.  Returning false is
// intentional: Stable-C must not expose a guessed DRM modifier to HWC.
inline bool decodeY2sDrmModifier(uint32_t internal, bool rgb, uint64_t* modifier) {
    if (!modifier) return false;
    const uint32_t modifiers = internal & ~kY2sInternalBaseMask;
    if (modifiers == 0) {
        *modifier = 0;
        return true;
    }
    if ((modifiers & ~kY2sKnownInternalModifiers) != 0 ||
        (modifiers & (kY2sAfbcBasic | kY2sAfbcSplit | kY2sAfbcWide)) == 0) {
        return false;
    }

    uint64_t features = modifiers & kY2sAfbcWide
            ? AFBC_FORMAT_MOD_BLOCK_SIZE_32x8
            : AFBC_FORMAT_MOD_BLOCK_SIZE_16x16;
    if (modifiers & kY2sAfbcSplit) {
        features |= AFBC_FORMAT_MOD_SPLIT | AFBC_FORMAT_MOD_SPARSE;
    }
    if (modifiers & kY2sAfbcTiledHeaders) features |= AFBC_FORMAT_MOD_TILED;
    if (rgb) features |= AFBC_FORMAT_MOD_YTR;
    *modifier = DRM_FORMAT_MOD_ARM_AFBC(features);
    return true;
}

}  // namespace exynos990
