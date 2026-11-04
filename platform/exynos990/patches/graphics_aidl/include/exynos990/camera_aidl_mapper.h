// Copyright (c) 2026 At30c
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// Private ABI between the y2s Camera3 compatibility facade and the Stable-C
// mapper.  It deliberately contains only the legacy Camera3 value objects:
// the proprietary camera blob keeps its existing C++ ABI while all gralloc
// work is owned by mapper.exynos990_compat.so.

#include <cutils/native_handle.h>

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct exynos990_camera_rect {
    int32_t left;
    int32_t top;
    int32_t width;
    int32_t height;
} exynos990_camera_rect_t;

typedef struct exynos990_camera_ycbcr {
    void* y;
    void* cb;
    void* cr;
    uint32_t yStride;
    uint32_t cStride;
    uint32_t chromaStep;
} exynos990_camera_ycbcr_t;

// These return the legacy gralloc mapper error numbers expected by
// libexynoscamera3.so.  They are exported from the Stable-C mapper, not from
// the HIDL facade.  The combined usage mask and null private_module_t probe
// are intentionally preserved because they are part of the y2s Camera3 ABI.
int exynos990_aidl_camera_lock(const native_handle_t* buffer, uint64_t usage,
                               const exynos990_camera_rect_t* rect, int fence,
                               void** output);
int exynos990_aidl_camera_lock_ycbcr(const native_handle_t* buffer, uint64_t usage,
                                     const exynos990_camera_rect_t* rect, int fence,
                                     exynos990_camera_ycbcr_t* output);
int exynos990_aidl_camera_unlock(const native_handle_t* buffer);

#ifdef __cplusplus
}
#endif
