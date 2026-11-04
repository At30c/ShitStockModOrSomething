#pragma once

#include <stdint.h>

struct exynos990_hwc2_display_info {
    uint64_t display;
    uint32_t active_config;
    int32_t width;
    int32_t height;
    int32_t vsync_period_ns;
    int32_t dpi_x;
    int32_t dpi_y;
    int32_t display_type;
    char name[128];
};

#ifdef __cplusplus
extern "C" {
#endif

int exynos990_hwc2_query_display(uint64_t display,
                                  exynos990_hwc2_display_info* out_info);

#ifdef __cplusplus
}
#endif
