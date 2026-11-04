// SPDX-License-Identifier: Apache-2.0
// The Samsung Camera3 blob performs auxiliary IPC while opening and closing
// devices.  Keep a closed endpoint from terminating the AIDL provider.
#pragma once

#include <pthread.h>
#include <signal.h>

namespace exynos990::camera {

inline void protectNativeIpcFromSigpipe() {
    struct sigaction action {};
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    (void)sigaction(SIGPIPE, &action, nullptr);

    sigset_t blocked {};
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    (void)pthread_sigmask(SIG_BLOCK, &blocked, nullptr);
}

}  // namespace exynos990::camera
