// Copyright (c) 2026 At30c
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// Common backend ABI shared by the Stable-C mapper and the AIDL allocator.
// The implementation deliberately exposes only Android Gralloc1 callback
// types.  It does not expose private Exynos/Mali handle fields or any S26+
// interface.

#include <hardware/gralloc1.h>
#include <system/graphics.h>

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct exynos990_gralloc_backend {
    gralloc1_device_t* device;

    // Context fallback for the exported Mali helpers.  The camera facade
    // first uses the stock null private_module_t contract and retries with
    // this loaded module only when the vendor helper rejects null.
    void* cameraModule;

    // The legacy camera ABI does not call the Gralloc1 lock callbacks.  It
    // calls these exported Mali helpers from gralloc.exynos990.so directly,
    // with one combined usage value.  Keep those entry points in the same
    // umbrella backend so the camera shim can preserve the original contract
    // without copying the old mapper implementation.
    int (*cameraLockAsync)(const void* module, const native_handle_t* buffer,
                           uint64_t usage, int left, int top, int width, int height,
                           void** output, int fence);
    int (*cameraGetNumFlexPlanes)(const void* module, const native_handle_t* buffer,
                                  uint32_t* outCount);
    int (*cameraLockFlexAsync)(const void* module, const native_handle_t* buffer,
                               uint64_t usage, int left, int top, int width, int height,
                               android_flex_layout_t* layout, int fence);
    int (*cameraUnlock)(const void* module, const native_handle_t* buffer);

    GRALLOC1_PFN_CREATE_DESCRIPTOR createDescriptor;
    GRALLOC1_PFN_DESTROY_DESCRIPTOR destroyDescriptor;
    GRALLOC1_PFN_SET_DIMENSIONS setDimensions;
    GRALLOC1_PFN_SET_FORMAT setFormat;
    GRALLOC1_PFN_SET_LAYER_COUNT setLayerCount;
    GRALLOC1_PFN_SET_PRODUCER_USAGE setProducerUsage;
    GRALLOC1_PFN_SET_CONSUMER_USAGE setConsumerUsage;
    GRALLOC1_PFN_ALLOCATE allocate;

    GRALLOC1_PFN_RETAIN retain;
    GRALLOC1_PFN_RELEASE release;
    GRALLOC1_PFN_GET_TRANSPORT_SIZE transportSize;
    GRALLOC1_PFN_GET_NUM_FLEX_PLANES getNumFlexPlanes;
    GRALLOC1_PFN_LOCK lock;
    GRALLOC1_PFN_LOCK_FLEX lockFlex;
    GRALLOC1_PFN_UNLOCK unlock;
    GRALLOC1_PFN_GET_BACKING_STORE backingStore;
    GRALLOC1_PFN_GET_DIMENSIONS getDimensions;
    GRALLOC1_PFN_GET_FORMAT getFormat;
    GRALLOC1_PFN_GET_LAYER_COUNT getLayerCount;
    GRALLOC1_PFN_GET_CONSUMER_USAGE getConsumerUsage;
    GRALLOC1_PFN_GET_PRODUCER_USAGE getProducerUsage;
    GRALLOC1_PFN_GET_STRIDE getStride;

    // Optional y2s symbol named mali_gralloc_get_format_internal(). Static
    // audit shows that this symbol returns private_handle_t +0x30
    // (frameworkFormat), not the vendor metadata class' +0x48 internal_format.
    // It is kept for compatibility and diagnostics; it is not a proven DRM
    // modifier source.
    int (*getFrameworkFormat)(const native_handle_t* buffer, int* outFormat);

    uint8_t releaseImpliesDelete;
    uint8_t ready;
    uint8_t cameraReady;
} exynos990_gralloc_backend_t;

// The returned object is process-local and remains valid for the lifetime of
// the process.  The stock gralloc1 module is opened through hw_get_module;
// no donor implementation is copied into this library.
const exynos990_gralloc_backend_t* exynos990_gralloc_backend(void);

#ifdef __cplusplus
}
#endif
