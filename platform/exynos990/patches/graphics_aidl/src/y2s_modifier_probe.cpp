#include "exynos990/y2s_modifier.h"

#include <cstdio>

namespace {

bool expect(uint32_t internal, bool rgb, bool expectedValid, uint64_t expectedModifier,
            const char* name) {
    uint64_t modifier = 0;
    const bool valid = exynos990::decodeY2sDrmModifier(internal, rgb, &modifier);
    if (valid != expectedValid || (valid && modifier != expectedModifier)) {
        std::fprintf(stderr, "FAIL %s: internal=0x%08x valid=%d modifier=0x%016llx\n",
                     name, internal, valid, static_cast<unsigned long long>(modifier));
        return false;
    }
    std::printf("PASS %s: internal=0x%08x modifier=0x%016llx\n", name, internal,
                static_cast<unsigned long long>(modifier));
    return true;
}

}  // namespace

int main() {
    const uint64_t linear = 0;
    const uint64_t basicRgb = DRM_FORMAT_MOD_ARM_AFBC(
            AFBC_FORMAT_MOD_BLOCK_SIZE_16x16 | AFBC_FORMAT_MOD_YTR);
    const uint64_t basicYuv = DRM_FORMAT_MOD_ARM_AFBC(AFBC_FORMAT_MOD_BLOCK_SIZE_16x16);
    const uint64_t splitWideTiled = DRM_FORMAT_MOD_ARM_AFBC(
            AFBC_FORMAT_MOD_BLOCK_SIZE_32x8 | AFBC_FORMAT_MOD_SPLIT |
            AFBC_FORMAT_MOD_SPARSE | AFBC_FORMAT_MOD_TILED);

    bool ok = true;
    ok &= expect(0x00000001U, true, true, linear, "linear-rgba");
    ok &= expect(0x00000023U, false, true, linear, "linear-yuv");
    ok &= expect(exynos990::kY2sAfbcBasic | 0x00000001U, true, true, basicRgb,
                 "basic-rgba");
    ok &= expect(exynos990::kY2sAfbcBasic | 0x00000023U, false, true, basicYuv,
                 "basic-yuv");
    ok &= expect(exynos990::kY2sAfbcWide | exynos990::kY2sAfbcSplit |
                         exynos990::kY2sAfbcTiledHeaders | 0x00000001U,
                 false, true, splitWideTiled, "split-wide-tiled");
    ok &= expect(0x00040001U, true, false, 0, "unknown-modifier");
    ok &= expect(exynos990::kY2sAfbcTiledHeaders | 0x00000001U, true, false, 0,
                 "tiled-without-afbc");
    return ok ? 0 : 1;
}
