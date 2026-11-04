#include "hwc2_backend_state.h"

#include <hardware/hardware.h>
#include <hardware/hwcomposer2.h>

#include <algorithm>
#include <dlfcn.h>
#include <new>

#include "hardware/hwcomposer_defs.h"

struct exynos990_hwc2_session {
    hwc2_device_t* device = nullptr;
    hwc2_display_t display = 0;
    HWC2_PFN_SET_POWER_MODE set_power_mode = nullptr;
    HWC2_PFN_SET_VSYNC_ENABLED set_vsync_enabled = nullptr;
    HWC2_PFN_GET_ACTIVE_CONFIG get_active_config = nullptr;
    HWC2_PFN_GET_DISPLAY_CONFIGS get_display_configs = nullptr;
    HWC2_PFN_GET_DISPLAY_ATTRIBUTE get_display_attribute = nullptr;
    HWC2_PFN_SET_ACTIVE_CONFIG set_active_config = nullptr;
    HWC2_PFN_SET_ACTIVE_CONFIG_WITH_CONSTRAINTS set_active_config_with_constraints = nullptr;
    HWC2_PFN_CREATE_LAYER create_layer = nullptr;
    HWC2_PFN_DESTROY_LAYER destroy_layer = nullptr;
    HWC2_PFN_SET_LAYER_COMPOSITION_TYPE set_layer_composition = nullptr;
    HWC2_PFN_SET_LAYER_BUFFER set_layer_buffer = nullptr;
    HWC2_PFN_SET_LAYER_DISPLAY_FRAME set_layer_display_frame = nullptr;
    HWC2_PFN_SET_LAYER_SOURCE_CROP set_layer_source_crop = nullptr;
    HWC2_PFN_SET_LAYER_TRANSFORM set_layer_transform = nullptr;
    HWC2_PFN_SET_LAYER_BLEND_MODE set_layer_blend_mode = nullptr;
    HWC2_PFN_SET_LAYER_PLANE_ALPHA set_layer_plane_alpha = nullptr;
    HWC2_PFN_SET_LAYER_COLOR set_layer_color = nullptr;
    HWC2_PFN_SET_LAYER_DATASPACE set_layer_dataspace = nullptr;
    HWC2_PFN_SET_LAYER_SURFACE_DAMAGE set_layer_surface_damage = nullptr;
    HWC2_PFN_SET_LAYER_VISIBLE_REGION set_layer_visible_region = nullptr;
    HWC2_PFN_SET_LAYER_Z_ORDER set_layer_z_order = nullptr;
    HWC2_PFN_SET_LAYER_COLOR_TRANSFORM set_layer_color_transform = nullptr;
    HWC2_PFN_SET_CLIENT_TARGET set_client_target = nullptr;
    HWC2_PFN_VALIDATE_DISPLAY validate_display = nullptr;
    HWC2_PFN_ACCEPT_DISPLAY_CHANGES accept_display_changes = nullptr;
    HWC2_PFN_PRESENT_DISPLAY present_display = nullptr;
    HWC2_PFN_REGISTER_CALLBACK register_callback = nullptr;
    HWC2_PFN_GET_CHANGED_COMPOSITION_TYPES get_changed_composition_types = nullptr;
    HWC2_PFN_GET_RELEASE_FENCES get_release_fences = nullptr;
    HWC2_PFN_GET_DISPLAY_REQUESTS get_display_requests = nullptr;
    // Optional HDR entry points (HWC2 2.2+).  The Exynos 990 HWC exports them;
    // a missing one only disables the corresponding HDR feature.
    HWC2_PFN_GET_HDR_CAPABILITIES get_hdr_capabilities = nullptr;
    HWC2_PFN_GET_PER_FRAME_METADATA_KEYS get_per_frame_metadata_keys = nullptr;
    HWC2_PFN_SET_LAYER_PER_FRAME_METADATA set_layer_per_frame_metadata = nullptr;
    HWC2_PFN_SET_LAYER_PER_FRAME_METADATA_BLOBS set_layer_per_frame_metadata_blobs = nullptr;
    exynos990_hwc2_callbacks callbacks{};
};

namespace {

template <typename T>
T getFunction(hwc2_device_t* device, hwc2_function_descriptor_t descriptor) {
    if (!device || !device->getFunction) return nullptr;
    return reinterpret_cast<T>(device->getFunction(device, descriptor));
}

void closeDevice(exynos990_hwc2_session* session) {
    if (session && session->device) {
        (void)hwc2_close(session->device);
        session->device = nullptr;
    }
}

void hotplugCallback(hwc2_callback_data_t data, hwc2_display_t display, int32_t connected) {
    auto* session = static_cast<exynos990_hwc2_session*>(data);
    if (session && session->callbacks.hotplug) {
        session->callbacks.hotplug(session->callbacks.context, display, connected);
    }
}

void refreshCallback(hwc2_callback_data_t data, hwc2_display_t display) {
    auto* session = static_cast<exynos990_hwc2_session*>(data);
    if (session && session->callbacks.refresh) {
        session->callbacks.refresh(session->callbacks.context, display);
    }
}

void vsyncCallback(hwc2_callback_data_t data, hwc2_display_t display, int64_t timestamp) {
    auto* session = static_cast<exynos990_hwc2_session*>(data);
    if (session && session->callbacks.vsync) {
        session->callbacks.vsync(session->callbacks.context, display, timestamp, 0);
    }
}

void vsync24Callback(hwc2_callback_data_t data, hwc2_display_t display, int64_t timestamp,
                     hwc2_vsync_period_t period) {
    auto* session = static_cast<exynos990_hwc2_session*>(data);
    if (session && session->callbacks.vsync) {
        session->callbacks.vsync(session->callbacks.context, display, timestamp,
                                 static_cast<int64_t>(period));
    }
}

void vsyncPeriodTimingChangedCallback(hwc2_callback_data_t data, hwc2_display_t display,
                                      hwc_vsync_period_change_timeline_t* timeline) {
    auto* session = static_cast<exynos990_hwc2_session*>(data);
    if (session && session->callbacks.vsync_period_timing_changed && timeline) {
        session->callbacks.vsync_period_timing_changed(
                session->callbacks.context, display,
                timeline->newVsyncAppliedTimeNanos, timeline->refreshTimeNanos,
                timeline->refreshRequired);
    }
}

void seamlessPossibleCallback(hwc2_callback_data_t data, hwc2_display_t display) {
    auto* session = static_cast<exynos990_hwc2_session*>(data);
    if (session && session->callbacks.seamless_possible) {
        session->callbacks.seamless_possible(session->callbacks.context, display);
    }
}

}  // namespace

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_open(
        uint64_t display, exynos990_hwc2_session** out_session) {
    if (!out_session) return HWC2_ERROR_BAD_PARAMETER;
    *out_session = nullptr;
    const hw_module_t* module = nullptr;
    if (hw_get_module(HWC_HARDWARE_MODULE_ID, &module) != 0 || !module || !module->methods) {
        return HWC2_ERROR_NO_RESOURCES;
    }

    auto* session = new (std::nothrow) exynos990_hwc2_session();
    if (!session || hwc2_open(module, &session->device) != 0 || !session->device) {
        delete session;
        return HWC2_ERROR_NO_RESOURCES;
    }
    session->display = display;
    session->set_power_mode = getFunction<HWC2_PFN_SET_POWER_MODE>(
            session->device, HWC2_FUNCTION_SET_POWER_MODE);
    session->set_vsync_enabled = getFunction<HWC2_PFN_SET_VSYNC_ENABLED>(
            session->device, HWC2_FUNCTION_SET_VSYNC_ENABLED);
    session->get_active_config = getFunction<HWC2_PFN_GET_ACTIVE_CONFIG>(
            session->device, HWC2_FUNCTION_GET_ACTIVE_CONFIG);
    session->get_display_configs = getFunction<HWC2_PFN_GET_DISPLAY_CONFIGS>(
            session->device, HWC2_FUNCTION_GET_DISPLAY_CONFIGS);
    session->get_display_attribute = getFunction<HWC2_PFN_GET_DISPLAY_ATTRIBUTE>(
            session->device, HWC2_FUNCTION_GET_DISPLAY_ATTRIBUTE);
    session->set_active_config = getFunction<HWC2_PFN_SET_ACTIVE_CONFIG>(
            session->device, HWC2_FUNCTION_SET_ACTIVE_CONFIG);
    session->set_active_config_with_constraints =
            getFunction<HWC2_PFN_SET_ACTIVE_CONFIG_WITH_CONSTRAINTS>(
                    session->device, HWC2_FUNCTION_SET_ACTIVE_CONFIG_WITH_CONSTRAINTS);
    session->create_layer = getFunction<HWC2_PFN_CREATE_LAYER>(
            session->device, HWC2_FUNCTION_CREATE_LAYER);
    session->destroy_layer = getFunction<HWC2_PFN_DESTROY_LAYER>(
            session->device, HWC2_FUNCTION_DESTROY_LAYER);
    session->set_layer_composition = getFunction<HWC2_PFN_SET_LAYER_COMPOSITION_TYPE>(
            session->device, HWC2_FUNCTION_SET_LAYER_COMPOSITION_TYPE);
    session->set_layer_buffer = getFunction<HWC2_PFN_SET_LAYER_BUFFER>(
            session->device, HWC2_FUNCTION_SET_LAYER_BUFFER);
    session->set_layer_display_frame = getFunction<HWC2_PFN_SET_LAYER_DISPLAY_FRAME>(
            session->device, HWC2_FUNCTION_SET_LAYER_DISPLAY_FRAME);
    session->set_layer_source_crop = getFunction<HWC2_PFN_SET_LAYER_SOURCE_CROP>(
            session->device, HWC2_FUNCTION_SET_LAYER_SOURCE_CROP);
    session->set_layer_transform = getFunction<HWC2_PFN_SET_LAYER_TRANSFORM>(
            session->device, HWC2_FUNCTION_SET_LAYER_TRANSFORM);
    session->set_layer_blend_mode = getFunction<HWC2_PFN_SET_LAYER_BLEND_MODE>(
            session->device, HWC2_FUNCTION_SET_LAYER_BLEND_MODE);
    session->set_layer_plane_alpha = getFunction<HWC2_PFN_SET_LAYER_PLANE_ALPHA>(
            session->device, HWC2_FUNCTION_SET_LAYER_PLANE_ALPHA);
    session->set_layer_color = getFunction<HWC2_PFN_SET_LAYER_COLOR>(
            session->device, HWC2_FUNCTION_SET_LAYER_COLOR);
    session->set_layer_dataspace = getFunction<HWC2_PFN_SET_LAYER_DATASPACE>(
            session->device, HWC2_FUNCTION_SET_LAYER_DATASPACE);
    session->set_layer_surface_damage = getFunction<HWC2_PFN_SET_LAYER_SURFACE_DAMAGE>(
            session->device, HWC2_FUNCTION_SET_LAYER_SURFACE_DAMAGE);
    session->set_layer_visible_region = getFunction<HWC2_PFN_SET_LAYER_VISIBLE_REGION>(
            session->device, HWC2_FUNCTION_SET_LAYER_VISIBLE_REGION);
    session->set_layer_z_order = getFunction<HWC2_PFN_SET_LAYER_Z_ORDER>(
            session->device, HWC2_FUNCTION_SET_LAYER_Z_ORDER);
    session->set_layer_color_transform = getFunction<HWC2_PFN_SET_LAYER_COLOR_TRANSFORM>(
            session->device, HWC2_FUNCTION_SET_LAYER_COLOR_TRANSFORM);
    session->set_client_target = getFunction<HWC2_PFN_SET_CLIENT_TARGET>(
            session->device, HWC2_FUNCTION_SET_CLIENT_TARGET);
    session->validate_display = getFunction<HWC2_PFN_VALIDATE_DISPLAY>(
            session->device, HWC2_FUNCTION_VALIDATE_DISPLAY);
    session->accept_display_changes = getFunction<HWC2_PFN_ACCEPT_DISPLAY_CHANGES>(
            session->device, HWC2_FUNCTION_ACCEPT_DISPLAY_CHANGES);
    session->present_display = getFunction<HWC2_PFN_PRESENT_DISPLAY>(
            session->device, HWC2_FUNCTION_PRESENT_DISPLAY);
    session->register_callback = getFunction<HWC2_PFN_REGISTER_CALLBACK>(
            session->device, HWC2_FUNCTION_REGISTER_CALLBACK);
    session->get_changed_composition_types = getFunction<HWC2_PFN_GET_CHANGED_COMPOSITION_TYPES>(
            session->device, HWC2_FUNCTION_GET_CHANGED_COMPOSITION_TYPES);
    session->get_release_fences = getFunction<HWC2_PFN_GET_RELEASE_FENCES>(
            session->device, HWC2_FUNCTION_GET_RELEASE_FENCES);
    session->get_display_requests = getFunction<HWC2_PFN_GET_DISPLAY_REQUESTS>(
            session->device, HWC2_FUNCTION_GET_DISPLAY_REQUESTS);
    session->get_hdr_capabilities = getFunction<HWC2_PFN_GET_HDR_CAPABILITIES>(
            session->device, HWC2_FUNCTION_GET_HDR_CAPABILITIES);
    session->get_per_frame_metadata_keys = getFunction<HWC2_PFN_GET_PER_FRAME_METADATA_KEYS>(
            session->device, HWC2_FUNCTION_GET_PER_FRAME_METADATA_KEYS);
    session->set_layer_per_frame_metadata = getFunction<HWC2_PFN_SET_LAYER_PER_FRAME_METADATA>(
            session->device, HWC2_FUNCTION_SET_LAYER_PER_FRAME_METADATA);
    session->set_layer_per_frame_metadata_blobs =
            getFunction<HWC2_PFN_SET_LAYER_PER_FRAME_METADATA_BLOBS>(
                    session->device, HWC2_FUNCTION_SET_LAYER_PER_FRAME_METADATA_BLOBS);
    if (!session->set_power_mode || !session->set_vsync_enabled ||
        !session->get_active_config || !session->get_display_configs ||
        !session->get_display_attribute || !session->set_active_config ||
        !session->create_layer || !session->destroy_layer || !session->set_layer_composition ||
        !session->set_layer_buffer || !session->set_layer_display_frame ||
        !session->set_layer_source_crop || !session->set_layer_transform ||
        !session->set_layer_blend_mode || !session->set_layer_plane_alpha ||
        !session->set_client_target || !session->validate_display ||
        !session->accept_display_changes || !session->present_display) {
        closeDevice(session);
        delete session;
        return HWC2_ERROR_UNSUPPORTED;
    }
    *out_session = session;
    return HWC2_ERROR_NONE;
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_register_callbacks(exynos990_hwc2_session* session,
                                          const exynos990_hwc2_callbacks* callbacks) {
    if (!session || !session->device || !session->register_callback || !callbacks) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    session->callbacks = *callbacks;
    const auto registerCallback = [&](int32_t descriptor, hwc2_function_pointer_t pointer) {
        return session->register_callback(session->device, descriptor, session, pointer);
    };
    int error = registerCallback(HWC2_CALLBACK_HOTPLUG,
                                 reinterpret_cast<hwc2_function_pointer_t>(hotplugCallback));
    if (error != HWC2_ERROR_NONE) return error;
    error = registerCallback(HWC2_CALLBACK_REFRESH,
                             reinterpret_cast<hwc2_function_pointer_t>(refreshCallback));
    if (error != HWC2_ERROR_NONE) return error;
    error = registerCallback(HWC2_CALLBACK_VSYNC_2_4,
                             reinterpret_cast<hwc2_function_pointer_t>(vsync24Callback));
    if (error == HWC2_ERROR_BAD_PARAMETER || error == HWC2_ERROR_UNSUPPORTED) {
        error = registerCallback(HWC2_CALLBACK_VSYNC,
                                 reinterpret_cast<hwc2_function_pointer_t>(vsyncCallback));
    }
    if (error != HWC2_ERROR_NONE) return error;
    if (callbacks->vsync_period_timing_changed) {
        error = registerCallback(
                HWC2_CALLBACK_VSYNC_PERIOD_TIMING_CHANGED,
                reinterpret_cast<hwc2_function_pointer_t>(vsyncPeriodTimingChangedCallback));
        if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_BAD_PARAMETER &&
            error != HWC2_ERROR_UNSUPPORTED) {
            return error;
        }
    }
    if (callbacks->seamless_possible) {
        error = registerCallback(HWC2_CALLBACK_SEAMLESS_POSSIBLE,
                                 reinterpret_cast<hwc2_function_pointer_t>(seamlessPossibleCallback));
        if (error != HWC2_ERROR_NONE && error != HWC2_ERROR_BAD_PARAMETER &&
            error != HWC2_ERROR_UNSUPPORTED) {
            return error;
        }
    }
    return HWC2_ERROR_NONE;
}

extern "C" __attribute__((visibility("default"))) void exynos990_hwc2_session_close(
        exynos990_hwc2_session* session) {
    if (!session) return;
    closeDevice(session);
    delete session;
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_power_mode(
        exynos990_hwc2_session* session, int32_t mode) {
    if (!session || !session->device || !session->set_power_mode) return HWC2_ERROR_BAD_PARAMETER;
    return session->set_power_mode(session->device, session->display, mode);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_vsync_enabled(
        exynos990_hwc2_session* session, int32_t enabled) {
    if (!session || !session->device || !session->set_vsync_enabled) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_vsync_enabled(session->device, session->display,
                                      static_cast<hwc2_vsync_t>(enabled));
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_active_config(
        exynos990_hwc2_session* session, uint32_t config) {
    if (!session || !session->device || !session->set_active_config) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_active_config(session->device, session->display, config);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_scaled_resolution(exynos990_hwc2_session* session, uint32_t config) {
    if (!session || !session->device) return HWC2_ERROR_BAD_PARAMETER;
    // The proprietary HWC2 object stores ExynosDevice at this stable offset;
    // its own setActiveConfig callback uses the same layout.  Calling the
    // exported framebuffer helper keeps the transition inside the HWC process
    // and therefore avoids a separate SELinux write to the panel sysfs node.
    void* exynos_device = *reinterpret_cast<void**>(
            reinterpret_cast<uint8_t*>(session->device) + 0x88);
    using GetDisplay = void* (*)(void*, unsigned int);
    using SetDdiScaler = void (*)(void*, int, int);
    using SetScaledResolution = int (*)(void*, unsigned int&, bool, int);
    using SetPanelConfig = int (*)(void*, unsigned int);
    void* display_library = ::dlopen("/vendor/lib64/libexynosdisplay.so",
                                     RTLD_NOW | RTLD_NOLOAD);
    if (!display_library) {
        display_library = ::dlopen("/vendor/lib64/libexynosdisplay.so", RTLD_NOW | RTLD_LOCAL);
    }
    auto get_display = reinterpret_cast<GetDisplay>(::dlsym(
            display_library, "_ZN12ExynosDevice10getDisplayEj"));
    auto set_ddi = reinterpret_cast<SetDdiScaler>(::dlsym(
            display_library, "_ZN20ExynosPrimaryDisplay18setDDIScalerEnableEii"));
    auto set_scaled = reinterpret_cast<SetScaledResolution>(::dlsym(
            display_library, "_ZN31ExynosPrimaryDisplayFbInterface19setScaledResolutionERjbi"));
    auto set_panel_config = reinterpret_cast<SetPanelConfig>(::dlsym(
            display_library, "_ZN24ExynosDisplayFbInterface15setActiveConfigEj"));
    if (!exynos_device || !get_display || !set_ddi || !set_scaled || !set_panel_config) {
        return HWC2_ERROR_UNSUPPORTED;
    }
    void* display = get_display(exynos_device, 0);
    if (!display) return HWC2_ERROR_NO_RESOURCES;
    int32_t width = 0;
    int32_t height = 0;
    if (exynos990_hwc2_session_get_display_attribute(
                session, config, HWC2_ATTRIBUTE_WIDTH, &width) != HWC2_ERROR_NONE ||
        exynos990_hwc2_session_get_display_attribute(
                session, config, HWC2_ATTRIBUTE_HEIGHT, &height) != HWC2_ERROR_NONE) {
        return HWC2_ERROR_BAD_CONFIG;
    }
    set_ddi(display, width, height);

    // The legacy Exynos FB interface owns the actual PANEL_IOC_SET_DISPLAY_MODE
    // ioctl.  ExynosDisplay::setActiveConfig only changes the logical HWC2
    // state, which leaves the panel scanning at QHD and causes the FHD crop.
    // Its object is kept by ExynosDisplay at +0x3cd0 and has the display at +8.
    void* fb_interface = *reinterpret_cast<void**>(
            reinterpret_cast<uint8_t*>(display) + 0x3cd0);
    if (!fb_interface) return HWC2_ERROR_NO_RESOURCES;
    uint32_t requested_config = config;
    const int scaled_error = set_scaled(fb_interface, requested_config, true, 0);
    if (scaled_error != 0) return HWC2_ERROR_BAD_CONFIG;
    const int panel_error = set_panel_config(fb_interface, config);
    return panel_error == 0 ? HWC2_ERROR_NONE : HWC2_ERROR_BAD_CONFIG;
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_active_config_with_constraints(
        exynos990_hwc2_session* session, uint32_t config, int64_t desired_time_nanos,
        int32_t seamless_required, int64_t* out_applied_time_nanos,
        int64_t* out_refresh_time_nanos, int32_t* out_refresh_required) {
    if (!session || !session->device || !out_applied_time_nanos || !out_refresh_time_nanos ||
        !out_refresh_required) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    if (!session->set_active_config_with_constraints) return HWC2_ERROR_UNSUPPORTED;

    hwc_vsync_period_change_constraints_t constraints{};
    constraints.desiredTimeNanos = desired_time_nanos;
    constraints.seamlessRequired = seamless_required != 0;
    hwc_vsync_period_change_timeline_t timeline{};
    const int error = session->set_active_config_with_constraints(
            session->device, session->display, config, &constraints, &timeline);
    if (error != HWC2_ERROR_NONE) return error;

    *out_applied_time_nanos = timeline.newVsyncAppliedTimeNanos;
    *out_refresh_time_nanos = timeline.refreshTimeNanos;
    *out_refresh_required = timeline.refreshRequired != 0;
    return HWC2_ERROR_NONE;
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_get_active_config(
        exynos990_hwc2_session* session, uint32_t* out_config) {
    if (!session || !session->device || !session->get_active_config || !out_config) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->get_active_config(session->device, session->display, out_config);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_get_display_configs(
        exynos990_hwc2_session* session, uint32_t* count, uint32_t* configs) {
    if (!session || !session->device || !session->get_display_configs || !count) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->get_display_configs(session->device, session->display, count, configs);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_get_display_attribute(exynos990_hwc2_session* session, uint32_t config,
                                              int32_t attribute, int32_t* out_value) {
    if (!session || !session->device || !session->get_display_attribute || !out_value) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->get_display_attribute(session->device, session->display, config,
                                           static_cast<hwc2_attribute_t>(attribute), out_value);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_create_layer(
        exynos990_hwc2_session* session, uint64_t* out_layer) {
    if (!session || !session->device || !session->create_layer || !out_layer) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->create_layer(session->device, session->display,
                                 reinterpret_cast<hwc2_layer_t*>(out_layer));
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_destroy_layer(
        exynos990_hwc2_session* session, uint64_t layer) {
    if (!session || !session->device || !session->destroy_layer) return HWC2_ERROR_BAD_PARAMETER;
    return session->destroy_layer(session->device, session->display,
                                  static_cast<hwc2_layer_t>(layer));
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_composition(exynos990_hwc2_session* session, uint64_t layer,
                                              int32_t composition) {
    if (!session || !session->device || !session->set_layer_composition) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_composition(session->device, session->display,
                                          static_cast<hwc2_layer_t>(layer), composition);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_layer_buffer(
        exynos990_hwc2_session* session, uint64_t layer, const void* buffer,
        int32_t acquire_fence) {
    if (!session || !session->device || !session->set_layer_buffer) return HWC2_ERROR_BAD_PARAMETER;
    return session->set_layer_buffer(session->device, session->display,
                                     static_cast<hwc2_layer_t>(layer),
                                     reinterpret_cast<buffer_handle_t>(const_cast<void*>(buffer)),
                                     acquire_fence);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_display_frame(exynos990_hwc2_session* session, uint64_t layer,
                                                int32_t left, int32_t top, int32_t right,
                                                int32_t bottom) {
    if (!session || !session->device || !session->set_layer_display_frame) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    const hwc_rect_t frame{left, top, right, bottom};
    return session->set_layer_display_frame(session->device, session->display,
                                            static_cast<hwc2_layer_t>(layer), frame);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_source_crop(exynos990_hwc2_session* session, uint64_t layer,
                                              float left, float top, float right, float bottom) {
    if (!session || !session->device || !session->set_layer_source_crop) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    const hwc_frect_t crop{left, top, right, bottom};
    return session->set_layer_source_crop(session->device, session->display,
                                          static_cast<hwc2_layer_t>(layer), crop);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_layer_transform(
        exynos990_hwc2_session* session, uint64_t layer, int32_t transform) {
    if (!session || !session->device || !session->set_layer_transform) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_transform(session->device, session->display,
                                        static_cast<hwc2_layer_t>(layer), transform);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_blend_mode(exynos990_hwc2_session* session, uint64_t layer,
                                             int32_t blend_mode) {
    if (!session || !session->device || !session->set_layer_blend_mode) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_blend_mode(session->device, session->display,
                                         static_cast<hwc2_layer_t>(layer), blend_mode);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_plane_alpha(exynos990_hwc2_session* session, uint64_t layer,
                                              float alpha) {
    if (!session || !session->device || !session->set_layer_plane_alpha) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_plane_alpha(session->device, session->display,
                                          static_cast<hwc2_layer_t>(layer), alpha);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_client_target(
        exynos990_hwc2_session* session, const void* buffer, int32_t acquire_fence,
        int32_t dataspace, const void* damage_rects, uint32_t damage_count) {
    if (!session || !session->device || !session->set_client_target) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    const hwc_region_t damage{damage_count,
                              reinterpret_cast<const hwc_rect_t*>(damage_rects)};
    return session->set_client_target(session->device, session->display,
                                      reinterpret_cast<buffer_handle_t>(const_cast<void*>(buffer)),
                                      acquire_fence, dataspace, damage);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_set_layer_color(
        exynos990_hwc2_session* session, uint64_t layer, float r, float g, float b, float a) {
    if (!session || !session->device || !session->set_layer_color) return HWC2_ERROR_BAD_PARAMETER;
    const hwc_color_t color{
            static_cast<uint8_t>(std::clamp(r, 0.0f, 1.0f) * 255.0f),
            static_cast<uint8_t>(std::clamp(g, 0.0f, 1.0f) * 255.0f),
            static_cast<uint8_t>(std::clamp(b, 0.0f, 1.0f) * 255.0f),
            static_cast<uint8_t>(std::clamp(a, 0.0f, 1.0f) * 255.0f)};
    return session->set_layer_color(session->device, session->display,
                                    static_cast<hwc2_layer_t>(layer), color);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_dataspace(exynos990_hwc2_session* session, uint64_t layer,
                                            int32_t dataspace) {
    if (!session || !session->device || !session->set_layer_dataspace) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_dataspace(session->device, session->display,
                                        static_cast<hwc2_layer_t>(layer), dataspace);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_get_display_requests(exynos990_hwc2_session* session,
                                             int32_t* display_requests, uint32_t* count,
                                             uint64_t* layers, int32_t* layer_requests) {
    if (!session || !session->device || !display_requests || !count) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    if (!session->get_display_requests) return HWC2_ERROR_UNSUPPORTED;
    return session->get_display_requests(session->device, session->display, display_requests,
                                         count, reinterpret_cast<hwc2_layer_t*>(layers),
                                         layer_requests);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_get_hdr_capabilities(exynos990_hwc2_session* session, uint32_t* num_types,
                                             int32_t* types, float* max_luminance,
                                             float* max_average_luminance,
                                             float* min_luminance) {
    if (!session || !session->device || !num_types || !max_luminance ||
        !max_average_luminance || !min_luminance) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    if (!session->get_hdr_capabilities) return HWC2_ERROR_UNSUPPORTED;
    return session->get_hdr_capabilities(session->device, session->display, num_types, types,
                                         max_luminance, max_average_luminance, min_luminance);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_get_per_frame_metadata_keys(exynos990_hwc2_session* session,
                                                    uint32_t* count, int32_t* keys) {
    if (!session || !session->device || !count) return HWC2_ERROR_BAD_PARAMETER;
    if (!session->get_per_frame_metadata_keys) return HWC2_ERROR_UNSUPPORTED;
    return session->get_per_frame_metadata_keys(session->device, session->display, count, keys);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_per_frame_metadata(exynos990_hwc2_session* session,
                                                     uint64_t layer, uint32_t count,
                                                     const int32_t* keys, const float* values) {
    if (!session || !session->device || (count && (!keys || !values))) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    if (!session->set_layer_per_frame_metadata) return HWC2_ERROR_UNSUPPORTED;
    return session->set_layer_per_frame_metadata(session->device, session->display,
                                                 static_cast<hwc2_layer_t>(layer), count, keys,
                                                 values);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_per_frame_metadata_blobs(exynos990_hwc2_session* session,
                                                           uint64_t layer, uint32_t count,
                                                           const int32_t* keys,
                                                           const uint32_t* sizes,
                                                           const uint8_t* metadata) {
    if (!session || !session->device || (count && (!keys || !sizes))) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    if (!session->set_layer_per_frame_metadata_blobs) return HWC2_ERROR_UNSUPPORTED;
    return session->set_layer_per_frame_metadata_blobs(session->device, session->display,
                                                       static_cast<hwc2_layer_t>(layer), count,
                                                       keys, sizes, metadata);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_surface_damage(exynos990_hwc2_session* session, uint64_t layer,
                                                 const void* rects, uint32_t count) {
    if (!session || !session->device || !session->set_layer_surface_damage) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    const hwc_region_t region{count, static_cast<const hwc_rect_t*>(rects)};
    return session->set_layer_surface_damage(session->device, session->display,
                                              static_cast<hwc2_layer_t>(layer), region);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_visible_region(exynos990_hwc2_session* session, uint64_t layer,
                                                 const void* rects, uint32_t count) {
    if (!session || !session->device || !session->set_layer_visible_region) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    const hwc_region_t region{count, static_cast<const hwc_rect_t*>(rects)};
    return session->set_layer_visible_region(session->device, session->display,
                                              static_cast<hwc2_layer_t>(layer), region);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_z_order(exynos990_hwc2_session* session, uint64_t layer,
                                          uint32_t z) {
    if (!session || !session->device || !session->set_layer_z_order) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_z_order(session->device, session->display,
                                      static_cast<hwc2_layer_t>(layer), z);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_set_layer_color_transform(exynos990_hwc2_session* session, uint64_t layer,
                                                  const float* matrix) {
    if (!session || !session->device || !session->set_layer_color_transform || !matrix) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->set_layer_color_transform(session->device, session->display,
                                              static_cast<hwc2_layer_t>(layer), matrix);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_validate(
        exynos990_hwc2_session* session, uint32_t* out_num_types, uint32_t* out_num_requests) {
    if (!session || !session->device || !session->validate_display || !out_num_types ||
        !out_num_requests) return HWC2_ERROR_BAD_PARAMETER;
    return session->validate_display(session->device, session->display, out_num_types,
                                     out_num_requests);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_accept_changes(
        exynos990_hwc2_session* session) {
    if (!session || !session->device || !session->accept_display_changes) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->accept_display_changes(session->device, session->display);
}

extern "C" __attribute__((visibility("default"))) int exynos990_hwc2_session_present(
        exynos990_hwc2_session* session, int32_t* out_present_fence) {
    if (!session || !session->device || !session->present_display || !out_present_fence) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->present_display(session->device, session->display, out_present_fence);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_get_changed_composition_types(exynos990_hwc2_session* session,
                                                     uint32_t* count, uint64_t* layers,
                                                     int32_t* types) {
    if (!session || !session->device || !session->get_changed_composition_types || !count) {
        return HWC2_ERROR_BAD_PARAMETER;
    }
    return session->get_changed_composition_types(
            session->device, session->display, count,
            reinterpret_cast<hwc2_layer_t*>(layers), types);
}

extern "C" __attribute__((visibility("default"))) int
exynos990_hwc2_session_get_release_fences(exynos990_hwc2_session* session, uint32_t* count,
                                          uint64_t* layers, int32_t* fences) {
    if (!session || !session->device || !session->get_release_fences || !count) {
        return HWC2_ERROR_UNSUPPORTED;
    }
    return session->get_release_fences(session->device, session->display, count,
                                       reinterpret_cast<hwc2_layer_t*>(layers), fences);
}
