/*
 * Subconjunto do contrato HWC2 usado pelo backend de inspeção do Exynos 990.
 * A definição segue hardware/libhardware/include/hardware/hwcomposer2.h;
 * ela não implementa o HAL nem altera a ABI do hwcomposer proprietário.
 */
#pragma once

#include <stdint.h>

#include <hardware/hardware.h>

#define HWC_HARDWARE_COMPOSER "composer"

typedef uint32_t hwc2_config_t;
typedef uint64_t hwc2_display_t;

typedef struct hwc2_device hwc2_device_t;
typedef void (*hwc2_function_pointer_t)();

typedef enum {
    HWC2_ERROR_NONE = 0,
    HWC2_ERROR_BAD_CONFIG = 1,
    HWC2_ERROR_BAD_DISPLAY = 2,
    HWC2_ERROR_BAD_PARAMETER = 4,
    HWC2_ERROR_NO_RESOURCES = 6,
    HWC2_ERROR_UNSUPPORTED = 8,
} hwc2_error_t;

typedef enum {
    HWC2_ATTRIBUTE_WIDTH = 1,
    HWC2_ATTRIBUTE_HEIGHT = 2,
    HWC2_ATTRIBUTE_VSYNC_PERIOD = 3,
    HWC2_ATTRIBUTE_DPI_X = 4,
    HWC2_ATTRIBUTE_DPI_Y = 5,
} hwc2_attribute_t;

typedef enum {
    HWC2_FUNCTION_GET_ACTIVE_CONFIG = 7,
    HWC2_FUNCTION_GET_DISPLAY_ATTRIBUTE = 11,
    HWC2_FUNCTION_GET_DISPLAY_CONFIGS = 12,
    HWC2_FUNCTION_GET_DISPLAY_NAME = 13,
    HWC2_FUNCTION_GET_DISPLAY_TYPE = 15,
} hwc2_function_descriptor_t;

struct hwc2_device {
    struct hw_device_t common;
    void (*getCapabilities)(hwc2_device_t*, uint32_t*, int32_t*);
    hwc2_function_pointer_t (*getFunction)(hwc2_device_t*, int32_t);
};

typedef int32_t (*HWC2_PFN_GET_ACTIVE_CONFIG)(hwc2_device_t*, hwc2_display_t,
                                                hwc2_config_t*);
typedef int32_t (*HWC2_PFN_GET_DISPLAY_ATTRIBUTE)(hwc2_device_t*, hwc2_display_t,
                                                   hwc2_config_t, int32_t, int32_t*);
typedef int32_t (*HWC2_PFN_GET_DISPLAY_CONFIGS)(hwc2_device_t*, hwc2_display_t,
                                                 uint32_t*, hwc2_config_t*);
typedef int32_t (*HWC2_PFN_GET_DISPLAY_NAME)(hwc2_device_t*, hwc2_display_t,
                                              uint32_t*, char*);
typedef int32_t (*HWC2_PFN_GET_DISPLAY_TYPE)(hwc2_device_t*, hwc2_display_t, int32_t*);

static inline int hwc2_open(const struct hw_module_t* module, hwc2_device_t** device) {
    return module->methods->open(module, HWC_HARDWARE_COMPOSER,
                                  TO_HW_DEVICE_T_OPEN(device));
}

static inline int hwc2_close(hwc2_device_t* device) {
    return device->common.close(&device->common);
}
