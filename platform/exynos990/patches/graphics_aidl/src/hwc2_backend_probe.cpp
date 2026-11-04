#include "hwc2_backend.h"

#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    uint64_t display = 0;
    if (argc > 1) display = std::strtoull(argv[1], nullptr, 0);

    exynos990_hwc2_display_info info{};
    const int error = exynos990_hwc2_query_display(display, &info);
    if (error != 0) {
        std::fprintf(stderr, "HWC2 backend probe failed: %d\n", error);
        return 1;
    }
    std::printf("HWC2 backend probe PASS display=%llu config=%u name=%s width=%d height=%d "
                "vsync_ns=%d dpi=(%d,%d) type=%d\n",
                static_cast<unsigned long long>(info.display), info.active_config, info.name,
                info.width, info.height, info.vsync_period_ns, info.dpi_x, info.dpi_y,
                info.display_type);
    return 0;
}
