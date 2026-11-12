#!/usr/bin/env python3
"""Teach the S24+ ENN 2.2.29 libenn_common_utils.so to accept the Exynos 990.

SocInfo::cache_soc_data() takes the digits of ro.hardware ("exynos990" ->
"990") and looks them up in a static table (8825, 9925, 9935, 8835, 9945,
8845, 9840, exynosauto9, linux).  Unknown SoCs abort the engine with
"Wrong flow".  Each translation unit that includes the table builds the
"9840" (Exynos 2100) key with the same three instructions:

    mov  w9, #0x3839            ; "98"
    mov  w8, #0x8               ; libc++ short string, size 4
    movk w9, #0x3034, lsl #16   ; "40"
    ...
    strb w8, [sp, #0x18]
    stur w9, [sp, #0x19]

Rewrite them to build "990" (size 3, bytes '9','9','0','\\0') so the 990
reuses the Exynos 2100 entry.  ro.hardware itself must stay "exynos990"
because the 990 HALs are loaded by that name.

Usage: patch_enn_soc.py <libenn_common_utils.so> <output>
"""

import struct
import sys

OLD = (0x52870729, 0x52800108, 0x72A60689)
NEW = (0x52872729, 0x528000C8, 0x72A00609)
EXPECTED_SITES = 6


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    data = bytearray(open(sys.argv[1], "rb").read())
    sites = []
    for pos in range(0, len(data) - 11, 4):
        if struct.unpack_from("<III", data, pos) == OLD:
            sites.append(pos)
    if len(sites) != EXPECTED_SITES:
        raise SystemExit(f"expected {EXPECTED_SITES} key sites, found {len(sites)}")
    for pos in sites:
        struct.pack_into("<III", data, pos, *NEW)
    open(sys.argv[2], "wb").write(data)
    print("patched 9840 -> 990 at " + ", ".join(hex(p) for p in sites))


if __name__ == "__main__":
    main()
