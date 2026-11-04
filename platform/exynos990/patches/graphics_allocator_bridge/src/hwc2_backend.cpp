#include "hwc2_backend.h"

#include <hardware/hardware.h>

#include <cstring>
#include <utility>

#include "hardware/hwcomposer_defs.h"
#include "hardware/hwcomposer2_min.h"

namespace {

constexpr char kTag[] = "Exynos990Hwc2Backend";
constexpr int kAndroidLogError = 6;

extern "C" int __android_log_print(int priority, const char* tag, const char* format, ...);

void logError(const char* message, int32_t error) {
    __android_log_print(kAndroidLogError, kTag, "%s: HWC2 error=%d", message, error);
}

template <typename T>
T getFunction(hwc2_device_t* device, hwc2_function_descriptor_t descriptor) {
    if (!device || !device->getFunction) return nullptr;
    return reinterpret_cast<T>(device->getFunction(device, descriptor));
}

int queryAttribute(HWC2_PFN_GET_DISPLAY_ATTRIBUTE get_attribute,
                   hwc2_device_t* device, uint64_t display, uint32_t config,
                   hwc2_attribute_t attribute, int32_t* output) {
    if (!get_attribute || !output) return HWC2_ERROR_BAD_PARAMETER;
    const int32_t error = get_attribute(device, display, config, attribute, output);
    if (error != HWC2_ERROR_NONE) logError("getDisplayAttribute", error);
    return error;
}

}  // namespace

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_query_display(
        uint64_t display, exynos990_hwc2_display_info* out_info) {
    if (!out_info) return HWC2_ERROR_BAD_PARAMETER;
    std::memset(out_info, 0, sizeof(*out_info));
    out_info->display = display;

    const hw_module_t* module = nullptr;
    if (hw_get_module(HWC_HARDWARE_MODULE_ID, &module) != 0 || !module || !module->methods) {
        __android_log_print(kAndroidLogError, kTag, "unable to load the composer module");
        return HWC2_ERROR_NO_RESOURCES;
    }

    hwc2_device_t* device = nullptr;
    if (hwc2_open(module, &device) != 0 || !device || !device->getFunction) {
        __android_log_print(kAndroidLogError, kTag, "unable to open the HWC2 device");
        return HWC2_ERROR_NO_RESOURCES;
    }

    auto close_device = [&]() {
        if (device) {
            (void)hwc2_close(device);
            device = nullptr;
        }
    };

    auto get_active = getFunction<HWC2_PFN_GET_ACTIVE_CONFIG>(
            device, HWC2_FUNCTION_GET_ACTIVE_CONFIG);
    auto get_attribute = getFunction<HWC2_PFN_GET_DISPLAY_ATTRIBUTE>(
            device, HWC2_FUNCTION_GET_DISPLAY_ATTRIBUTE);
    auto get_name = getFunction<HWC2_PFN_GET_DISPLAY_NAME>(
            device, HWC2_FUNCTION_GET_DISPLAY_NAME);
    auto get_type = getFunction<HWC2_PFN_GET_DISPLAY_TYPE>(
            device, HWC2_FUNCTION_GET_DISPLAY_TYPE);
    if (!get_active || !get_attribute) {
        close_device();
        __android_log_print(kAndroidLogError, kTag,
                            "stock HWC2 lacks the display query callbacks");
        return HWC2_ERROR_UNSUPPORTED;
    }

    int32_t error = get_active(device, display, &out_info->active_config);
    if (error != HWC2_ERROR_NONE) {
        logError("getActiveConfig", error);
        close_device();
        return error;
    }

    for (const auto query : {
                 std::pair{HWC2_ATTRIBUTE_WIDTH, &out_info->width},
                 std::pair{HWC2_ATTRIBUTE_HEIGHT, &out_info->height},
                 std::pair{HWC2_ATTRIBUTE_VSYNC_PERIOD, &out_info->vsync_period_ns},
                 std::pair{HWC2_ATTRIBUTE_DPI_X, &out_info->dpi_x},
                 std::pair{HWC2_ATTRIBUTE_DPI_Y, &out_info->dpi_y},
         }) {
        error = queryAttribute(get_attribute, device, display, out_info->active_config,
                               query.first, query.second);
        if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_UNSUPPORTED) {
            close_device();
            return error;
        }
    }

    if (get_type) {
        error = get_type(device, display, &out_info->display_type);
        if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_UNSUPPORTED) {
            close_device();
            return error;
        }
    }

    if (get_name) {
        uint32_t size = sizeof(out_info->name);
        error = get_name(device, display, &size, out_info->name);
        if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_UNSUPPORTED) {
            close_device();
            return error;
        }
        out_info->name[sizeof(out_info->name) - 1] = '\0';
    }

    close_device();
    return HWC2_ERROR_NONE;
}
