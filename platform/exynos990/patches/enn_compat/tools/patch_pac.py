#!/usr/bin/env python3
"""Adapt AArch64 blobs built for ARMv8.3+ (PAC) to run on the Cortex-A77.

On a CPU without FEAT_PAuth the HINT-space instructions (paciasp, autiasp,
bti, ...) execute as NOPs, so the link register is never signed.  The
combined forms are not in the HINT space and raise SIGILL; since nothing
was signed, an unauthenticated return is equivalent:

    retaa / retab  ->  ret

LRCPC2 accesses (ldapur*/stlur*, FEAT_LRCPC2) are only reported here; they
need a different treatment (see ../README.md).

Only sections with SHF_EXECINSTR are scanned, one aligned word at a time.

Usage: patch_pac.py <input.so> <output.so> [--check]
"""

import struct
import sys

RET = 0xD65F03C0
COMBINED_RETURNS = {0xD65F0BFF: "retaa", 0xD65F0FFF: "retab"}
SHF_EXECINSTR = 0x4


def is_lrcpc2(word):
    # LDAPUR*/STLUR*: size:011001:opc:0:imm9:00:Rn:Rt
    return (word & 0x3F200C00) == 0x19000000


def exec_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not a little-endian ELF64 file")
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    shstr_off = struct.unpack_from("<Q", data, e_shoff + e_shstrndx * e_shentsize + 0x18)[0]
    for i in range(e_shnum):
        base = e_shoff + i * e_shentsize
        name_off, sh_type, sh_flags = struct.unpack_from("<IIQ", data, base)
        sh_offset, sh_size = struct.unpack_from("<QQ", data, base + 0x18)
        if sh_type == 8 or not sh_flags & SHF_EXECINSTR:  # skip NOBITS
            continue
        end = data.index(b"\0", shstr_off + name_off)
        yield data[shstr_off + name_off:end].decode(), sh_offset, sh_size


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    check_only = "--check" in sys.argv[3:]
    data = bytearray(open(src, "rb").read())

    replaced = {name: 0 for name in COMBINED_RETURNS.values()}
    lrcpc2 = []
    for name, off, size in exec_sections(data):
        for pos in range(off - off % 4 + (4 if off % 4 else 0), off + size - 3, 4):
            word, = struct.unpack_from("<I", data, pos)
            if word in COMBINED_RETURNS:
                replaced[COMBINED_RETURNS[word]] += 1
                struct.pack_into("<I", data, pos, RET)
            elif is_lrcpc2(word):
                lrcpc2.append((name, pos, word))

    print(f"{src}: retaa={replaced['retaa']} retab={replaced['retab']} "
          f"lrcpc2_restantes={len(lrcpc2)}")
    for name, pos, word in lrcpc2:
        print(f"  lrcpc2 {name}+0x{pos:x}: 0x{word:08x}")
    if not check_only:
        open(dst, "wb").write(data)


if __name__ == "__main__":
    main()
