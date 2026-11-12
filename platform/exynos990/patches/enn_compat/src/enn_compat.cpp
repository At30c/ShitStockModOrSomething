/*
 * ENN compatibility bridge for Exynos 990.
 *
 * New Samsung apps request libenn_user_lib.so.  Exynos 990 stock exposes the
 * compatible baseline through libenn_sys_user.samsung_slsi.so.  Keep the
 * bridge deliberately small for the first on-device probe: it proves the
 * loader contract and calls the actual stock implementation; it never
 * fabricates a successful inference result.
 */
#include <android/log.h>
#include <dlfcn.h>

namespace {
constexpr char kTag[] = "Exynos990EnnCompat";
constexpr char kLegacyLibrary[] = "libenn_sys_user.samsung_slsi.so";

using EnnNoArgFunction = int (*)();

void* legacy_handle() {
    static void* handle = []() -> void* {
        void* result = dlopen(kLegacyLibrary, RTLD_NOW | RTLD_LOCAL);
        if (result == nullptr) {
            __android_log_print(ANDROID_LOG_ERROR, kTag,
                                "Cannot load %s: %s", kLegacyLibrary, dlerror());
        }
        return result;
    }();
    return handle;
}

int invoke_no_arg(const char* name) {
    void* handle = legacy_handle();
    if (handle == nullptr) {
        return -1;
    }
    dlerror();
    auto function = reinterpret_cast<EnnNoArgFunction>(dlsym(handle, name));
    const char* error = dlerror();
    if (error != nullptr || function == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kTag,
                            "Legacy ENN symbol %s unavailable: %s", name,
                            error == nullptr ? "unknown error" : error);
        return -1;
    }
    const int result = function();
    __android_log_print(ANDROID_LOG_INFO, kTag, "%s returned %d", name, result);
    return result;
}
}  // namespace

extern "C" int EnnInitialize() {
    return invoke_no_arg("EnnInitialize");
}

extern "C" int EnnDeinitialize() {
    return invoke_no_arg("EnnDeinitialize");
}

/* A distinct probe symbol avoids pretending that unsupported modern entry
 * points work.  The test program uses this only to identify the bridge. */
extern "C" const char* exynos990_enn_compat_version() {
    return "0.1-legacy-eden-probe";
}
