#!/usr/bin/env python3
"""Same-length, in-place .dynstr rewrite (no segment/section relayout).

patchelf --rename-dynamic-symbols/--add-needed relocates .dynamic/.dynstr
into new PT_LOAD segments, which corrupted the A26 libcodec2_vndk relocations
at load time.  Undefined symbol names are not part of the library's own hash
tables, so renaming UND names and DT_NEEDED strings in place is safe.

    patch_dynstr.py [--optional] <elf> <old>=<new> [...]

With --optional, entries absent from the library are skipped instead of
failing (used for DT_NEEDED renames applied to every library of the chain).
"""
import sys

from elftools.elf.elffile import ELFFile


def main():
    args = sys.argv[1:]
    optional = args[:1] == ["--optional"]
    if optional:
        args = args[1:]
    path = args[0]
    with open(path, "rb") as fp:
        elf = ELFFile(fp)
        dynstr = elf.get_section_by_name(".dynstr")
        start, size = dynstr["sh_offset"], dynstr["sh_size"]
    data = bytearray(open(path, "rb").read())
    table = data[start:start + size]
    for spec in args[1:]:
        old, new = (s.encode() for s in spec.split("=", 1))
        if len(old) != len(new):
            sys.exit(f"length mismatch: {old!r} -> {new!r}")
        needle = b"\0" + old + b"\0"
        count = table.count(needle)
        if count != 1:
            if table.count(b"\0" + new + b"\0") == 1 or (optional and count == 0):
                continue
            sys.exit(f"{old!r}: expected exactly one .dynstr entry, found {count}")
        table = table.replace(needle, b"\0" + new + b"\0")
    data[start:start + size] = table
    open(path, "wb").write(data)


if __name__ == "__main__":
    main()
