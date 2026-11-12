#include <dlfcn.h>
#include <stdio.h>

using EnnNoArgFunction = int (*)();
using VersionFunction = const char* (*)();

int main(int argc, char** argv) {
    const char* library = argc > 1 ? argv[1] : "libenn_user_lib.so";
    void* handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        fprintf(stderr, "dlopen %s failed: %s\n", library, dlerror());
        return 2;
    }
    if (argc > 2 && argv[2][0] == 'l') {
        printf("loaded=%s\n", library);
        return 0;
    }
    if (argc > 2 && argv[2][0] == 'i') {
        auto initialize = reinterpret_cast<EnnNoArgFunction>(dlsym(handle, "EnnInitialize"));
        if (initialize == nullptr) {
            fprintf(stderr, "EnnInitialize is missing\n");
            return 3;
        }
        const int init = initialize();
        printf("EnnInitialize=%d\n", init);
        return init == 0 ? 0 : 4;
    }
    auto version = reinterpret_cast<VersionFunction>(dlsym(handle, "exynos990_enn_compat_version"));
    auto initialize = reinterpret_cast<EnnNoArgFunction>(dlsym(handle, "EnnInitialize"));
    auto deinitialize = reinterpret_cast<EnnNoArgFunction>(dlsym(handle, "EnnDeinitialize"));
    if (version == nullptr || initialize == nullptr || deinitialize == nullptr) {
        fprintf(stderr, "bridge symbol is missing\n");
        return 3;
    }
    printf("bridge=%s\n", version());
    const int init = initialize();
    printf("EnnInitialize=%d\n", init);
    if (init == 0) {
        const int deinit = deinitialize();
        printf("EnnDeinitialize=%d\n", deinit);
        return deinit == 0 ? 0 : 5;
    }
    return 4;
}
