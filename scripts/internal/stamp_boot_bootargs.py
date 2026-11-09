#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""stamp_boot_bootargs.py <boot.img> <name>=<value>

Sets an androidboot.<name>=<value> argument in the /chosen/bootargs of every
device tree in the dtb section of a boot image (header v2), then repacks the
image with mkbootimg using the original arguments.

Samsung's bootloader ignores the command line of the boot image header: the
kernel command line starts from /chosen/bootargs of the SoC device tree that
the boot image carries, and init turns androidboot.* arguments into ro.boot.*
properties. make_rom.sh -k stores the kernel-only build timestamp this way.

The dtb section may be a single FDT or a DT table (mkdtimg). Needs
unpack_bootimg and mkbootimg in PATH.
"""

import os
import re
import shlex
import struct
import subprocess
import sys
import tempfile

FDT_MAGIC = 0xD00DFEED
DT_TABLE_MAGIC = 0xD7B7AB1E
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def align4(n):
    return (n + 3) & ~3


def set_bootarg(fdt, key, value):
    """Returns the FDT with key=value set in /chosen/bootargs."""
    (magic, totalsize, off_struct, off_strings, off_rsvmap, version,
     last_comp, boot_cpuid, size_strings, size_struct) = struct.unpack_from(">10I", fdt)
    if magic != FDT_MAGIC:
        raise ValueError("not an FDT")
    if off_strings < off_struct:
        raise ValueError("unsupported FDT layout (strings before struct)")
    strings = fdt[off_strings:off_strings + size_strings]

    def name_at(off):
        return strings[off:strings.index(b"\0", off)].decode()

    pos, end, path = off_struct, off_struct + size_struct, []
    while pos < end:
        token = struct.unpack_from(">I", fdt, pos)[0]
        if token == FDT_BEGIN_NODE:
            name_end = fdt.index(b"\0", pos + 4)
            path.append(fdt[pos + 4:name_end].decode())
            pos = align4(name_end + 1)
        elif token == FDT_END_NODE:
            path.pop()
            pos += 4
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", fdt, pos + 4)
            value_off = pos + 12
            if path == ["", "chosen"] and name_at(nameoff) == "bootargs":
                old = fdt[value_off:value_off + length].rstrip(b"\0").decode()
                args = [a for a in old.split() if not a.startswith(key + "=")]
                args.append(f"{key}={value}")
                new = " ".join(args).encode() + b"\0"
                old_span = align4(length)
                new_span = align4(len(new))
                delta = new_span - old_span
                out = bytearray(fdt[:pos + 4])
                out += struct.pack(">II", len(new), nameoff)
                out += new.ljust(new_span, b"\0")
                out += fdt[value_off + old_span:]
                struct.pack_into(">10I", out, 0, magic, totalsize + delta, off_struct,
                                 off_strings + delta, off_rsvmap, version, last_comp,
                                 boot_cpuid, size_strings, size_struct + delta)
                return bytes(out[:totalsize + delta]), " ".join(args)
            pos = align4(value_off + length)
        elif token == FDT_NOP:
            pos += 4
        elif token == FDT_END:
            break
        else:
            raise ValueError(f"bad FDT token {token:#x} at {pos:#x}")
    raise ValueError("no /chosen/bootargs")


def stamp_dtb_section(data, key, value):
    magic = struct.unpack_from(">I", data)[0]
    if magic == FDT_MAGIC:
        return set_bootarg(data, key, value)
    if magic != DT_TABLE_MAGIC:
        raise ValueError("dtb section is neither an FDT nor a DT table")
    (_, total, header_size, entry_size, count, entries_off,
     page_size, version) = struct.unpack_from(">8I", data)
    entries = [list(struct.unpack_from(">8I", data, entries_off + i * entry_size))
               for i in range(count)]
    blobs, bootargs = [], None
    for e in entries:
        blob, bootargs = set_bootarg(data[e[1]:e[1] + e[0]], key, value)
        blobs.append(blob)
    out = bytearray(data[:entries_off + count * entry_size])
    offset = len(out)
    for i, (e, blob) in enumerate(zip(entries, blobs)):
        e[0], e[1] = len(blob), offset
        struct.pack_into(">8I", out, entries_off + i * entry_size, *e)
        out += blob
        offset += len(blob)
    struct.pack_into(">8I", out, 0, DT_TABLE_MAGIC, len(out), header_size,
                     entry_size, count, entries_off, page_size, version)
    return bytes(out), bootargs


def main():
    if len(sys.argv) != 3 or "=" not in sys.argv[2]:
        sys.exit(__doc__)
    image, (name, value) = sys.argv[1], sys.argv[2].split("=", 1)
    if not re.fullmatch(r"[a-z0-9_.]+", name) or not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
        sys.exit(f"invalid argument {sys.argv[2]!r}")
    key = f"androidboot.{name}"

    with tempfile.TemporaryDirectory(dir=os.path.dirname(os.path.abspath(image))) as tmp:
        args = subprocess.run(
            ["unpack_bootimg", "--boot_img", image, "--out", tmp, "--format=mkbootimg"],
            check=True, capture_output=True, text=True).stdout
        args = shlex.split(args)
        if "--dtb" not in args:
            sys.exit(f"{image}: no dtb section (boot header v2 needed)")
        dtb = args[args.index("--dtb") + 1]
        with open(dtb, "rb") as f:
            data, bootargs = stamp_dtb_section(f.read(), key, value)
        with open(dtb, "wb") as f:
            f.write(data)
        out = os.path.join(tmp, "boot.img")
        subprocess.run(["mkbootimg", *args, "--output", out], check=True)
        os.replace(out, image)
    print(f"  bootargs: {bootargs}")


if __name__ == "__main__":
    main()
