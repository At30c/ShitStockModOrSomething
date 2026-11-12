/* Minimal, read-only Eden SDK viability probe for the Exynos 990 vendor. */
#include <dlfcn.h>
#include <stdio.h>

using EdenNoArgFunction = int (*)();

int main() {
    constexpr char kLibrary[] = "/vendor/lib64/libeden_wrapper_sdk.so";
    void* handle = dlopen(kLibrary, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        fprintf(stderr, "dlopen %s failed: %s\n", kLibrary, dlerror());
        return 2;
    }
    auto initialize = reinterpret_cast<EdenNoArgFunction>(dlsym(handle, "Initialize"));
    auto shutdown = reinterpret_cast<EdenNoArgFunction>(dlsym(handle, "Shutdown"));
    if (initialize == nullptr || shutdown == nullptr) {
        fprintf(stderr, "Eden SDK initialization symbols are missing\n");
        return 3;
    }
    const int init = initialize();
    printf("EdenInitialize=%d\n", init);
    if (init != 0) {
        return 4;
    }
    const int deinit = shutdown();
    printf("EdenShutdown=%d\n", deinit);
    return deinit == 0 ? 0 : 5;
}
