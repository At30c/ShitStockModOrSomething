// Reproduz o lock YUV feito por clientes do framework (Motion Photo, ImageReader):
// AHardwareBuffer_lockPlanes -> GraphicBufferMapper::lockYCbCr -> Gralloc5 ->
// mapper.exynos990_compat.so. O Gralloc5 monta android_ycbcr a partir de
// PLANE_LAYOUTS e do endereço devolvido por lock(); se os dois não descreverem
// a mesma memória, o cliente recebe planos nulos ou deslocados.
//
// Uso: ahb_ycbcr_probe <format> <usage> [width height]

#include <android/hardware_buffer.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>

int main(int argc, char** argv) {
    if (argc != 3 && argc != 5) {
        std::fprintf(stderr, "usage: %s <format> <usage> [width height]\n", argv[0]);
        return 2;
    }
    // Sem buffer: se um plano inválido derrubar o processo, o layout já saiu.
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    AHardwareBuffer_Desc desc{};
    desc.format = static_cast<uint32_t>(std::strtoul(argv[1], nullptr, 0));
    desc.usage = std::strtoull(argv[2], nullptr, 0);
    desc.width = argc == 5 ? static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 0)) : 1440;
    desc.height = argc == 5 ? static_cast<uint32_t>(std::strtoul(argv[4], nullptr, 0)) : 1080;
    desc.layers = 1;

    AHardwareBuffer* buffer = nullptr;
    int result = AHardwareBuffer_allocate(&desc, &buffer);
    if (result != 0 || !buffer) {
        std::printf("allocate format=0x%x usage=0x%llx failed=%d\n", desc.format,
                    static_cast<unsigned long long>(desc.usage), result);
        return 1;
    }
    AHardwareBuffer_describe(buffer, &desc);
    std::printf("allocated %ux%u format=0x%x stride=%u\n", desc.width, desc.height,
                desc.format, desc.stride);

    bool ok = true;
    for (int round = 0; round < 3; ++round) {
        AHardwareBuffer_Planes planes{};
        result = AHardwareBuffer_lockPlanes(buffer, AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN |
                                                            AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN,
                                            -1, nullptr, &planes);
        std::printf("round=%d lockPlanes=%d planes=%u", round, result, planes.planeCount);
        for (uint32_t index = 0; result == 0 && index < planes.planeCount; ++index) {
            std::printf(" [%u] data=%p pixel=%u row=%u", index, planes.planes[index].data,
                        planes.planes[index].pixelStride, planes.planes[index].rowStride);
        }
        std::printf("\n");
        if (result != 0 || planes.planeCount != 3) {
            ok = false;
            break;
        }
        for (uint32_t index = 0; index < 3; ++index) {
            if (!planes.planes[index].data || planes.planes[index].rowStride == 0) ok = false;
        }
        if (ok) {
            // Escreve a primeira e a última linha de cada plano: um layout
            // incoerente com a memória mapeada falha aqui em vez de no app.
            const uint32_t heights[3] = {desc.height, (desc.height + 1) / 2,
                                         (desc.height + 1) / 2};
            const uint32_t widths[3] = {desc.width, (desc.width + 1) / 2, (desc.width + 1) / 2};
            for (uint32_t index = 0; index < 3; ++index) {
                auto* base = static_cast<uint8_t*>(planes.planes[index].data);
                const uint32_t row = planes.planes[index].rowStride;
                const uint32_t pixel = planes.planes[index].pixelStride;
                const uint32_t value = static_cast<uint32_t>(0x40 + index * 0x30 + round);
                for (uint32_t y : {0u, heights[index] - 1}) {
                    for (uint32_t x = 0; x < widths[index]; ++x) {
                        base[static_cast<size_t>(y) * row + static_cast<size_t>(x) * pixel] =
                                static_cast<uint8_t>(value);
                    }
                }
            }
        }
        AHardwareBuffer_unlock(buffer, nullptr);
        if (!ok) break;

        // A cópia de volta (scratch -> planos nativos) precisa preservar os
        // valores escritos: relê sem escrita e confere o primeiro pixel.
        AHardwareBuffer_Planes readBack{};
        result = AHardwareBuffer_lockPlanes(buffer, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, -1,
                                            nullptr, &readBack);
        if (result != 0 || readBack.planeCount != 3) {
            std::printf("round=%d readback lock=%d\n", round, result);
            ok = false;
            break;
        }
        for (uint32_t index = 0; index < 3; ++index) {
            const uint8_t expected = static_cast<uint8_t>(0x40 + index * 0x30 + round);
            const uint8_t actual = *static_cast<const uint8_t*>(readBack.planes[index].data);
            if (actual != expected) {
                std::printf("round=%d plane=%u readback=0x%02x expected=0x%02x\n", round,
                            index, actual, expected);
                ok = false;
            }
        }
        AHardwareBuffer_unlock(buffer, nullptr);
        if (!ok) break;
    }
    AHardwareBuffer_release(buffer);
    std::printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
