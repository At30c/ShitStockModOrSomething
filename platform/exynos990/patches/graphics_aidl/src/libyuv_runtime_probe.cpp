// Test-only probe for the camera preview conversion path.  It is deliberately
// kept out of the production Composer library: run it from a vendor linker
// namespace before deciding whether libyuv can be a production dependency.
#include <dlfcn.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

using Nv21Converter = int (*)(const uint8_t*, int, const uint8_t*, int,
                              uint8_t*, int, int, int);

static uint64_t monotonicNs() {
    timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<uint64_t>(now.tv_sec) * 1000000000ULL + now.tv_nsec;
}

static uint64_t fnv1a(const uint8_t* data, size_t size) {
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < size; ++i) {
        hash ^= data[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static void printPixel(const char* label, const uint8_t* pixel) {
    printf("%s=%u/%u/%u/%u\n", label, pixel[0], pixel[1], pixel[2], pixel[3]);
}

// Exact hot loop from CameraRgbConverter, isolated so the benchmark compares
// the current production route with libyuv on identical NV21 bytes.
static void currentComposerNv21ToRgba(const uint8_t* y_base, const uint8_t* cr_base,
                                      uint8_t* destination, int width, int height) {
    for (int y = 0; y < height; ++y) {
        const uint8_t* y_row = y_base + static_cast<size_t>(y) * width;
        const uint8_t* cr_row = cr_base + static_cast<size_t>(y / 2) * width;
        uint8_t* row = destination + static_cast<size_t>(y) * width * 4;
        int x = 0;
#if defined(__aarch64__)
        for (; x + 8 <= width; x += 8) {
            const uint8x8_t luma = vld1_u8(y_row + x);
            const uint8x8x2_t chroma = vld2_u8(cr_row + x);
            const uint8x8_t cb4 = chroma.val[1];
            const uint8x8_t cr4 = chroma.val[0];
            const uint8x8_t cb = vzip_u8(cb4, cb4).val[0];
            const uint8x8_t cr = vzip_u8(cr4, cr4).val[0];
            const int16x8_t y16 = vreinterpretq_s16_u16(vmovl_u8(luma));
            const int16x8_t cb16 = vsubq_s16(
                    vreinterpretq_s16_u16(vmovl_u8(cb)), vdupq_n_s16(128));
            const int16x8_t cr16 = vsubq_s16(
                    vreinterpretq_s16_u16(vmovl_u8(cr)), vdupq_n_s16(128));
            const int16x8_t red = vaddq_s16(y16, vshrq_n_s16(vmulq_n_s16(cr16, 179), 7));
            const int16x8_t green = vsubq_s16(y16, vshrq_n_s16(vaddq_s16(
                    vmulq_n_s16(cb16, 44), vmulq_n_s16(cr16, 91)), 7));
            const int16x8_t blue = vaddq_s16(y16, vshrq_n_s16(vmulq_n_s16(cb16, 227), 7));
            const uint8x8x4_t rgba{{vqmovun_s16(red), vqmovun_s16(green),
                                    vqmovun_s16(blue), vdup_n_u8(255)}};
            vst4_u8(row + static_cast<size_t>(x) * 4, rgba);
        }
#endif
        for (; x < width; ++x) {
            const int luma = y_row[x];
            const int cr = cr_row[(x / 2) * 2] - 128;
            const int cb = cr_row[(x / 2) * 2 + 1] - 128;
            const int red = luma + (179 * cr) / 128;
            const int green = luma - (44 * cb + 91 * cr) / 128;
            const int blue = luma + (227 * cb) / 128;
            uint8_t* pixel = row + static_cast<size_t>(x) * 4;
            pixel[0] = static_cast<uint8_t>(red < 0 ? 0 : red > 255 ? 255 : red);
            pixel[1] = static_cast<uint8_t>(green < 0 ? 0 : green > 255 ? 255 : green);
            pixel[2] = static_cast<uint8_t>(blue < 0 ? 0 : blue > 255 ? 255 : blue);
            pixel[3] = 255;
        }
    }
}

// Candidate correction: load precisely the four VU pairs required for eight
// luma samples.  It removes the current vld2 16-byte over-read while keeping
// the same coefficients and RGBA byte contract.
static void safeComposerNv21ToRgba(const uint8_t* y_base, const uint8_t* cr_base,
                                   uint8_t* destination, int width, int height) {
    for (int y = 0; y < height; ++y) {
        const uint8_t* y_row = y_base + static_cast<size_t>(y) * width;
        const uint8_t* cr_row = cr_base + static_cast<size_t>(y / 2) * width;
        uint8_t* row = destination + static_cast<size_t>(y) * width * 4;
        int x = 0;
#if defined(__aarch64__)
        for (; x + 8 <= width; x += 8) {
            const uint8x8_t luma = vld1_u8(y_row + x);
            const uint8x8_t vu = vld1_u8(cr_row + x);
            const uint8x8x2_t deinterleaved = vuzp_u8(vu, vu);
            const uint8x8_t cr = vzip_u8(deinterleaved.val[0], deinterleaved.val[0]).val[0];
            const uint8x8_t cb = vzip_u8(deinterleaved.val[1], deinterleaved.val[1]).val[0];
            const int16x8_t y16 = vreinterpretq_s16_u16(vmovl_u8(luma));
            const int16x8_t cb16 = vsubq_s16(
                    vreinterpretq_s16_u16(vmovl_u8(cb)), vdupq_n_s16(128));
            const int16x8_t cr16 = vsubq_s16(
                    vreinterpretq_s16_u16(vmovl_u8(cr)), vdupq_n_s16(128));
            const int16x8_t red = vaddq_s16(y16, vshrq_n_s16(vmulq_n_s16(cr16, 179), 7));
            const int16x8_t green = vsubq_s16(y16, vshrq_n_s16(vaddq_s16(
                    vmulq_n_s16(cb16, 44), vmulq_n_s16(cr16, 91)), 7));
            const int16x8_t blue = vaddq_s16(y16, vshrq_n_s16(vmulq_n_s16(cb16, 227), 7));
            const uint8x8x4_t rgba{{vqmovun_s16(red), vqmovun_s16(green),
                                    vqmovun_s16(blue), vdup_n_u8(255)}};
            vst4_u8(row + static_cast<size_t>(x) * 4, rgba);
        }
#endif
        for (; x < width; ++x) {
            const int luma = y_row[x];
            const int cr = cr_row[(x / 2) * 2] - 128;
            const int cb = cr_row[(x / 2) * 2 + 1] - 128;
            const int red = luma + (179 * cr) / 128;
            const int green = luma - (44 * cb + 91 * cr) / 128;
            const int blue = luma + (227 * cb) / 128;
            uint8_t* pixel = row + static_cast<size_t>(x) * 4;
            pixel[0] = static_cast<uint8_t>(red < 0 ? 0 : red > 255 ? 255 : red);
            pixel[1] = static_cast<uint8_t>(green < 0 ? 0 : green > 255 ? 255 : green);
            pixel[2] = static_cast<uint8_t>(blue < 0 ? 0 : blue > 255 ? 255 : blue);
            pixel[3] = 255;
        }
    }
}

int main() {
    constexpr int kWidth = 1440;
    constexpr int kHeight = 1080;
    constexpr int kYStride = 1440;
    constexpr int kVuStride = 1440;
    const size_t y_size = static_cast<size_t>(kYStride) * kHeight;
    const size_t vu_size = static_cast<size_t>(kVuStride) * (kHeight / 2);
    // CameraRgbConverter's current vld2 loop speculatively reads eight bytes
    // beyond the final chroma row.  Preserve a guard tail in this diagnostic
    // so it can quantify that implementation without turning the benchmark
    // into an allocator-dependent crash; production must not rely on this.
    constexpr size_t kCurrentConverterGuardTail = 16;
    uint8_t* nv21 = static_cast<uint8_t*>(malloc(y_size + vu_size +
                                                  kCurrentConverterGuardTail));
    uint8_t* rgba = static_cast<uint8_t*>(malloc(static_cast<size_t>(kWidth) * kHeight * 4));
    if (!nv21 || !rgba) {
        fprintf(stderr, "allocation failed\n");
        return 2;
    }
    // A deterministic, non-neutral image makes R/B ordering observable.  VU
    // (not UV) is intentional: this exactly matches the y2s LOCK_FLEX NV21
    // layout where Cr points at byte zero and Cb at byte one.
    for (int y = 0; y < kHeight; ++y) {
        for (int x = 0; x < kWidth; ++x) nv21[y * kYStride + x] = (x + y) & 0xff;
    }
    uint8_t* vu = nv21 + y_size;
    for (int y = 0; y < kHeight / 2; ++y) {
        for (int x = 0; x < kWidth; x += 2) {
            vu[y * kVuStride + x] = static_cast<uint8_t>(240 - ((x / 2 + y) & 31));
            vu[y * kVuStride + x + 1] = static_cast<uint8_t>(90 + ((x / 2 + y) & 31));
        }
    }
    memset(nv21 + y_size + vu_size, 0, kCurrentConverterGuardTail);

    constexpr int kIterations = 40;
    const uint64_t current_start = monotonicNs();
    for (int iteration = 0; iteration < kIterations; ++iteration) {
        currentComposerNv21ToRgba(nv21, vu, rgba, kWidth, kHeight);
    }
    const uint64_t current_elapsed = monotonicNs() - current_start;
    printf("CURRENT_COMPOSER hash=%016" PRIx64
           " total_ms=%.3f ms_per_frame=%.3f fps=%.2f\n",
           fnv1a(rgba, static_cast<size_t>(kWidth) * kHeight * 4),
           current_elapsed / 1000000.0, current_elapsed / 1000000.0 / kIterations,
           static_cast<double>(kIterations) * 1000000000.0 / current_elapsed);
    const uint64_t safe_start = monotonicNs();
    for (int iteration = 0; iteration < kIterations; ++iteration) {
        safeComposerNv21ToRgba(nv21, vu, rgba, kWidth, kHeight);
    }
    const uint64_t safe_elapsed = monotonicNs() - safe_start;
    printf("SAFE_COMPOSER hash=%016" PRIx64
           " equal_current=%s total_ms=%.3f ms_per_frame=%.3f fps=%.2f\n",
           fnv1a(rgba, static_cast<size_t>(kWidth) * kHeight * 4),
           fnv1a(rgba, static_cast<size_t>(kWidth) * kHeight * 4) ==
                           0x4db2ea6a105e1369ULL ? "yes" : "no",
           safe_elapsed / 1000000.0, safe_elapsed / 1000000.0 / kIterations,
           static_cast<double>(kIterations) * 1000000000.0 / safe_elapsed);

    const char* paths[] = {"/system/lib64/libyuv.so", "libyuv.so"};
    void* library = nullptr;
    for (const char* path : paths) {
        dlerror();
        library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (library) {
            printf("DLOPEN_OK path=%s\n", path);
            break;
        }
        const char* error = dlerror();
        printf("DLOPEN_FAIL path=%s error=%s\n", path, error ? error : "unknown");
    }
    if (!library) return 3;

    const char* symbols[] = {"NV21ToABGR", "NV21ToARGB"};
    for (const char* symbol : symbols) {
        auto convert = reinterpret_cast<Nv21Converter>(dlsym(library, symbol));
        if (!convert) {
            printf("SYMBOL_FAIL name=%s\n", symbol);
            continue;
        }
        memset(rgba, 0, static_cast<size_t>(kWidth) * kHeight * 4);
        const int result = convert(nv21, kYStride, vu, kVuStride, rgba, kWidth * 4,
                                   kWidth, kHeight);
        printf("CONVERT name=%s result=%d hash=%016" PRIx64 "\n", symbol, result,
               fnv1a(rgba, static_cast<size_t>(kWidth) * kHeight * 4));
        printPixel("PIXEL_0", rgba);
        printPixel("PIXEL_MID", rgba +
                (static_cast<size_t>(kHeight / 2) * kWidth + kWidth / 2) * 4);

        const uint64_t start = monotonicNs();
        for (int iteration = 0; iteration < kIterations; ++iteration) {
            if (convert(nv21, kYStride, vu, kVuStride, rgba, kWidth * 4,
                        kWidth, kHeight) != 0) {
                fprintf(stderr, "benchmark conversion failed\n");
                dlclose(library);
                return 4;
            }
        }
        const uint64_t elapsed = monotonicNs() - start;
        printf("BENCH name=%s frames=%d total_ms=%.3f ms_per_frame=%.3f fps=%.2f\n",
               symbol, kIterations, elapsed / 1000000.0,
               elapsed / 1000000.0 / kIterations,
               static_cast<double>(kIterations) * 1000000000.0 / elapsed);
    }
    dlclose(library);
    free(rgba);
    free(nv21);
    return 0;
}
