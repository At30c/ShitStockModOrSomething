// Copyright (c) 2026 At30c
// SPDX-License-Identifier: GPL-3.0-or-later
#include "exynos990/graphics_backend.h"

#include <hardware/hardware.h>

#include <cstdlib>
#include <dlfcn.h>
#include <pthread.h>

extern "C" int __android_log_print(int priority, const char* tag, const char* format, ...);

namespace {

#define ALOGI(...) __android_log_print(4, "Exynos990GraphicsCompat", __VA_ARGS__)
#define ALOGE(...) __android_log_print(6, "Exynos990GraphicsCompat", __VA_ARGS__)

template <typename T>
T load(gralloc1_device_t* device, gralloc1_function_descriptor_t descriptor) {
    return reinterpret_cast<T>(device->getFunction(device, descriptor));
}

exynos990_gralloc_backend_t backend{};
pthread_once_t backendOnce = PTHREAD_ONCE_INIT;

void initializeBackend() {
    const hw_module_t* module = nullptr;
    if (hw_get_module(GRALLOC_HARDWARE_MODULE_ID, &module) != 0 || !module ||
        gralloc1_open(module, &backend.device) != 0 || !backend.device) {
        ALOGE("Unable to open stock Exynos 990 gralloc1 module");
        return;
    }

    // Keep the real module as a fallback context.  The stock camera mapper
    // tries a null private_module_t first, but a few y2s camera paths are
    // reached through the loaded gralloc module and only accept this context.
    // The camera facade performs the ordered null-then-module probe.
    backend.cameraModule = const_cast<hw_module_t*>(module);

    // These symbols are exported by the stock Exynos 990 gralloc module.  We
    // resolve them from the already loaded module instead of dlopen'ing a
    // second copy, which would create a second private allocator state.
    if (module->dso) {
        backend.cameraLockAsync = reinterpret_cast<decltype(backend.cameraLockAsync)>(
                dlsym(module->dso,
                      "_Z23mali_gralloc_lock_asyncPK16private_module_tPK13native_handlemiiiiPPvi"));
        backend.cameraGetNumFlexPlanes = reinterpret_cast<decltype(backend.cameraGetNumFlexPlanes)>(
                dlsym(module->dso,
                      "_Z32mali_gralloc_get_num_flex_planesPK16private_module_tPK13native_handlePj"));
        backend.cameraLockFlexAsync = reinterpret_cast<decltype(backend.cameraLockFlexAsync)>(
                dlsym(module->dso,
                      "_Z28mali_gralloc_lock_flex_asyncPK16private_module_tPK13native_handlemiiiiP19android_flex_layouti"));
        backend.cameraUnlock = reinterpret_cast<decltype(backend.cameraUnlock)>(
                dlsym(module->dso,
                      "_Z19mali_gralloc_unlockPK16private_module_tPK13native_handle"));
        backend.getFrameworkFormat = reinterpret_cast<decltype(backend.getFrameworkFormat)>(
                dlsym(module->dso,
                      "_Z32mali_gralloc_get_format_internalPK13native_handlePi"));
    }
    backend.cameraReady = backend.cameraLockAsync && backend.cameraGetNumFlexPlanes &&
            backend.cameraLockFlexAsync && backend.cameraUnlock;
    if (!backend.cameraReady) {
        ALOGE("Stock gralloc1 module has no complete legacy camera callback set");
    } else {
        ALOGI("Legacy Exynos camera lock callbacks resolved from stock gralloc module");
    }

    backend.createDescriptor = load<GRALLOC1_PFN_CREATE_DESCRIPTOR>(
            backend.device, GRALLOC1_FUNCTION_CREATE_DESCRIPTOR);
    backend.destroyDescriptor = load<GRALLOC1_PFN_DESTROY_DESCRIPTOR>(
            backend.device, GRALLOC1_FUNCTION_DESTROY_DESCRIPTOR);
    backend.setDimensions = load<GRALLOC1_PFN_SET_DIMENSIONS>(
            backend.device, GRALLOC1_FUNCTION_SET_DIMENSIONS);
    backend.setFormat = load<GRALLOC1_PFN_SET_FORMAT>(
            backend.device, GRALLOC1_FUNCTION_SET_FORMAT);
    backend.setLayerCount = load<GRALLOC1_PFN_SET_LAYER_COUNT>(
            backend.device, GRALLOC1_FUNCTION_SET_LAYER_COUNT);
    backend.setProducerUsage = load<GRALLOC1_PFN_SET_PRODUCER_USAGE>(
            backend.device, GRALLOC1_FUNCTION_SET_PRODUCER_USAGE);
    backend.setConsumerUsage = load<GRALLOC1_PFN_SET_CONSUMER_USAGE>(
            backend.device, GRALLOC1_FUNCTION_SET_CONSUMER_USAGE);
    backend.allocate = load<GRALLOC1_PFN_ALLOCATE>(backend.device,
                                                   GRALLOC1_FUNCTION_ALLOCATE);

    backend.retain = load<GRALLOC1_PFN_RETAIN>(backend.device, GRALLOC1_FUNCTION_RETAIN);
    backend.release = load<GRALLOC1_PFN_RELEASE>(backend.device, GRALLOC1_FUNCTION_RELEASE);
    backend.transportSize = load<GRALLOC1_PFN_GET_TRANSPORT_SIZE>(
            backend.device, GRALLOC1_FUNCTION_GET_TRANSPORT_SIZE);
    backend.getNumFlexPlanes = load<GRALLOC1_PFN_GET_NUM_FLEX_PLANES>(
            backend.device, GRALLOC1_FUNCTION_GET_NUM_FLEX_PLANES);
    backend.lock = load<GRALLOC1_PFN_LOCK>(backend.device, GRALLOC1_FUNCTION_LOCK);
    backend.lockFlex = load<GRALLOC1_PFN_LOCK_FLEX>(backend.device,
                                                    GRALLOC1_FUNCTION_LOCK_FLEX);
    backend.unlock = load<GRALLOC1_PFN_UNLOCK>(backend.device, GRALLOC1_FUNCTION_UNLOCK);
    backend.backingStore = load<GRALLOC1_PFN_GET_BACKING_STORE>(
            backend.device, GRALLOC1_FUNCTION_GET_BACKING_STORE);
    backend.getDimensions = load<GRALLOC1_PFN_GET_DIMENSIONS>(
            backend.device, GRALLOC1_FUNCTION_GET_DIMENSIONS);
    backend.getFormat = load<GRALLOC1_PFN_GET_FORMAT>(backend.device,
                                                      GRALLOC1_FUNCTION_GET_FORMAT);
    backend.getLayerCount = load<GRALLOC1_PFN_GET_LAYER_COUNT>(
            backend.device, GRALLOC1_FUNCTION_GET_LAYER_COUNT);
    backend.getConsumerUsage = load<GRALLOC1_PFN_GET_CONSUMER_USAGE>(
            backend.device, GRALLOC1_FUNCTION_GET_CONSUMER_USAGE);
    backend.getProducerUsage = load<GRALLOC1_PFN_GET_PRODUCER_USAGE>(
            backend.device, GRALLOC1_FUNCTION_GET_PRODUCER_USAGE);
    backend.getStride = load<GRALLOC1_PFN_GET_STRIDE>(backend.device,
                                                      GRALLOC1_FUNCTION_GET_STRIDE);

    uint32_t capabilityCount = 0;
    backend.device->getCapabilities(backend.device, &capabilityCount, nullptr);
    if (capabilityCount != 0) {
        int32_t* capabilities = static_cast<int32_t*>(
                std::calloc(capabilityCount, sizeof(int32_t)));
        if (capabilities) {
            backend.device->getCapabilities(backend.device, &capabilityCount, capabilities);
            for (uint32_t index = 0; index < capabilityCount; ++index) {
                if (capabilities[index] == GRALLOC1_CAPABILITY_RELEASE_IMPLY_DELETE) {
                    backend.releaseImpliesDelete = 1;
                    break;
                }
            }
            std::free(capabilities);
        }
    }

    backend.ready = backend.createDescriptor && backend.destroyDescriptor &&
            backend.setDimensions && backend.setFormat && backend.setLayerCount &&
            backend.setProducerUsage && backend.setConsumerUsage && backend.allocate &&
            backend.retain && backend.release && backend.transportSize &&
            backend.getNumFlexPlanes && backend.lock && backend.lockFlex && backend.unlock &&
            backend.backingStore && backend.getDimensions && backend.getFormat &&
            backend.getLayerCount && backend.getConsumerUsage && backend.getProducerUsage &&
            backend.getStride;

    if (!backend.ready) {
        ALOGE("Stock gralloc1 is missing a callback required by the bridge");
    } else {
        ALOGI("Stock gralloc1 backend ready; releaseImpliesDelete=%u",
              backend.releaseImpliesDelete);
    }
    if (backend.getFrameworkFormat) {
        ALOGI("y2s Mali framework-format accessor resolved (private handle +0x30)");
    } else {
        ALOGE("y2s Mali framework-format accessor unavailable; modifier metadata disabled");
    }
}

}  // namespace

extern "C" __attribute__((visibility("default")))
const exynos990_gralloc_backend_t* exynos990_gralloc_backend(void) {
    pthread_once(&backendOnce, initializeBackend);
    return &backend;
}
