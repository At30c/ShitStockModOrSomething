/*
 * Android 17's generated Composer3 NDK runtime references this libc++ helper,
 * while the y2s vendor namespace uses the older VNDK 30 libc++.  The helper is
 * only reached when libc++ has to report a fatal programming error; aborting
 * is the same terminal behavior without replacing the vendor-wide libc++.
 */
#include <stdarg.h>

__attribute__((noreturn, visibility("default")))
void composer3_cxx_verbose_abort(const char *format, ...) __asm__(
    "_ZNSt3__122__libcpp_verbose_abortEPKcz");

void composer3_cxx_verbose_abort(const char *format, ...) {
    (void)format;
    __builtin_trap();
    __builtin_unreachable();
}
