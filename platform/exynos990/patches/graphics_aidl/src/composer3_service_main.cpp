#include <android/binder_ibinder.h>
#include <android/log.h>

// The standalone NDK installed on the build host only ships binder_ibinder.h;
// these stable NDK entry points are exported by libbinder_ndk on the target.
extern "C" binder_status_t AServiceManager_addService(AIBinder* binder,
                                                       const char* instance);
extern "C" void ABinderProcess_setThreadPoolMaxThreadCount(uint32_t num_threads);
extern "C" void ABinderProcess_startThreadPool();
extern "C" void ABinderProcess_joinThreadPool();

extern "C" AIBinder* exynos990_composer3_service_binder();

int main() {
    constexpr const char* kInstance =
            "android.hardware.graphics.composer3.IComposer/default";

    __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                        "starting Composer3 service instance %s", kInstance);
    ABinderProcess_setThreadPoolMaxThreadCount(4);
    AIBinder* binder = exynos990_composer3_service_binder();
    if (!binder) {
        __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                            "service binder factory returned null");
        return 1;
    }

    const binder_status_t status = AServiceManager_addService(binder, kInstance);
    if (status != STATUS_OK) {
        __android_log_print(ANDROID_LOG_ERROR, "Composer3Bridge",
                            "AServiceManager_addService failed: %d", status);
        return 2;
    }
    __android_log_print(ANDROID_LOG_INFO, "Composer3Bridge",
                        "Composer3 service registered");

    ABinderProcess_startThreadPool();
    ABinderProcess_joinThreadPool();
    return 0;
}
