#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct exynos990_hwc2_session;

/* Callbacks are kept as a small C ABI so the Composer3 contract can bridge
 * HWC2 without leaking generated AIDL types into the backend library. */
struct exynos990_hwc2_callbacks {
    void* context;
    void (*hotplug)(void* context, uint64_t display, int32_t connected);
    void (*refresh)(void* context, uint64_t display);
    void (*vsync)(void* context, uint64_t display, int64_t timestamp,
                  int64_t vsync_period_nanos);
    void (*vsync_period_timing_changed)(void* context, uint64_t display,
                                        int64_t new_vsync_applied_time_nanos,
                                        int64_t refresh_time_nanos,
                                        int64_t refresh_required);
    void (*seamless_possible)(void* context, uint64_t display);
};

int exynos990_hwc2_session_open(uint64_t display, exynos990_hwc2_session** out_session);
void exynos990_hwc2_session_close(exynos990_hwc2_session* session);
int exynos990_hwc2_session_set_power_mode(exynos990_hwc2_session* session, int32_t mode);
int exynos990_hwc2_session_set_vsync_enabled(exynos990_hwc2_session* session, int32_t enabled);
int exynos990_hwc2_session_get_active_config(exynos990_hwc2_session* session,
                                              uint32_t* out_config);
int exynos990_hwc2_session_get_display_configs(exynos990_hwc2_session* session,
                                                uint32_t* count, uint32_t* configs);
int exynos990_hwc2_session_get_display_attribute(exynos990_hwc2_session* session,
                                                  uint32_t config, int32_t attribute,
                                                  int32_t* out_value);
int exynos990_hwc2_session_set_active_config(exynos990_hwc2_session* session, uint32_t config);
int exynos990_hwc2_session_set_scaled_resolution(exynos990_hwc2_session* session,
                                                 uint32_t config);
int exynos990_hwc2_session_set_active_config_with_constraints(
        exynos990_hwc2_session* session, uint32_t config, int64_t desired_time_nanos,
        int32_t seamless_required, int64_t* out_applied_time_nanos,
        int64_t* out_refresh_time_nanos, int32_t* out_refresh_required);
int exynos990_hwc2_session_register_callbacks(exynos990_hwc2_session* session,
                                               const exynos990_hwc2_callbacks* callbacks);
int exynos990_hwc2_session_create_layer(exynos990_hwc2_session* session, uint64_t* out_layer);
int exynos990_hwc2_session_destroy_layer(exynos990_hwc2_session* session, uint64_t layer);
int exynos990_hwc2_session_set_layer_composition(exynos990_hwc2_session* session,
                                                  uint64_t layer, int32_t composition);
int exynos990_hwc2_session_set_layer_buffer(exynos990_hwc2_session* session, uint64_t layer,
                                             const void* buffer, int32_t acquire_fence);
int exynos990_hwc2_session_set_layer_display_frame(exynos990_hwc2_session* session,
                                                    uint64_t layer, int32_t left, int32_t top,
                                                    int32_t right, int32_t bottom);
int exynos990_hwc2_session_set_layer_source_crop(exynos990_hwc2_session* session,
                                                  uint64_t layer, float left, float top,
                                                  float right, float bottom);
int exynos990_hwc2_session_set_layer_transform(exynos990_hwc2_session* session,
                                                uint64_t layer, int32_t transform);
int exynos990_hwc2_session_set_layer_blend_mode(exynos990_hwc2_session* session,
                                                 uint64_t layer, int32_t blend_mode);
int exynos990_hwc2_session_set_layer_plane_alpha(exynos990_hwc2_session* session,
                                                  uint64_t layer, float alpha);
int exynos990_hwc2_session_set_layer_color(exynos990_hwc2_session* session, uint64_t layer,
                                            float r, float g, float b, float a);
int exynos990_hwc2_session_set_layer_dataspace(exynos990_hwc2_session* session, uint64_t layer,
                                                int32_t dataspace);
int exynos990_hwc2_session_get_display_requests(exynos990_hwc2_session* session,
                                                 int32_t* display_requests, uint32_t* count,
                                                 uint64_t* layers, int32_t* layer_requests);
int exynos990_hwc2_session_get_hdr_capabilities(exynos990_hwc2_session* session,
                                                 uint32_t* num_types, int32_t* types,
                                                 float* max_luminance,
                                                 float* max_average_luminance,
                                                 float* min_luminance);
int exynos990_hwc2_session_get_per_frame_metadata_keys(exynos990_hwc2_session* session,
                                                        uint32_t* count, int32_t* keys);
int exynos990_hwc2_session_set_layer_per_frame_metadata(exynos990_hwc2_session* session,
                                                         uint64_t layer, uint32_t count,
                                                         const int32_t* keys,
                                                         const float* values);
int exynos990_hwc2_session_set_layer_per_frame_metadata_blobs(exynos990_hwc2_session* session,
                                                               uint64_t layer, uint32_t count,
                                                               const int32_t* keys,
                                                               const uint32_t* sizes,
                                                               const uint8_t* metadata);
int exynos990_hwc2_session_set_layer_surface_damage(exynos990_hwc2_session* session,
                                                     uint64_t layer, const void* rects,
                                                     uint32_t count);
int exynos990_hwc2_session_set_layer_visible_region(exynos990_hwc2_session* session,
                                                     uint64_t layer, const void* rects,
                                                     uint32_t count);
int exynos990_hwc2_session_set_layer_z_order(exynos990_hwc2_session* session, uint64_t layer,
                                              uint32_t z);
int exynos990_hwc2_session_set_layer_color_transform(exynos990_hwc2_session* session,
                                                      uint64_t layer, const float* matrix);
int exynos990_hwc2_session_set_client_target(exynos990_hwc2_session* session, const void* buffer,
                                              int32_t acquire_fence, int32_t dataspace,
                                              const void* damage_rects, uint32_t damage_count);
int exynos990_hwc2_session_validate(exynos990_hwc2_session* session, uint32_t* out_num_types,
                                    uint32_t* out_num_requests);
int exynos990_hwc2_session_accept_changes(exynos990_hwc2_session* session);
int exynos990_hwc2_session_present(exynos990_hwc2_session* session, int32_t* out_present_fence);
int exynos990_hwc2_session_get_release_fences(exynos990_hwc2_session* session, uint32_t* count,
                                               uint64_t* layers, int32_t* fences);
int exynos990_hwc2_session_get_changed_composition_types(
        exynos990_hwc2_session* session, uint32_t* count, uint64_t* layers, int32_t* types);

#ifdef __cplusplus
}
#endif
