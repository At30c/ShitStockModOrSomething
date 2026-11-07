#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rebuild a raw partition image from a full block OTA payload.

    sdat2img.py <transfer.list> <new.dat or -> <output.img>
    sdat2img.py --check <transfer.list or ->

--check only validates the transfer list and prints the image size in bytes.

Only full payloads are accepted: "new", "zero" and "erase" commands. An
incremental payload ("move", "bsdiff", "imgdiff", "stash", ...) describes a
change to a source image and cannot be rebuilt alone. new.dat is read
sequentially, so a brotli payload can be streamed through stdin:

    brotli -d -c system.new.dat.br | sdat2img.py system.transfer.list - system.img

Blocks the payload does not write ("erase", "zero", or unused) are left as
holes, which read back as zeros like the erased blocks on the device.
"""

import sys

BLOCK_SIZE = 4096
FULL_COMMANDS = {"new", "zero", "erase"}


def parse_ranges(text):
    values = [int(v) for v in text.split(",")]
    if values[0] != len(values) - 1 or values[0] % 2:
        raise ValueError(f"bad range set: {text}")
    return [(values[i], values[i + 1]) for i in range(1, len(values), 2)]


def parse_transfer_list(path):
    if path == "-":
        lines = [line.rstrip("\n") for line in sys.stdin]
    else:
        with open(path, encoding="ascii") as f:
            lines = [line.rstrip("\n") for line in f]

    version = int(lines[0])
    if version < 1 or version > 4:
        raise ValueError(f"unsupported transfer list version {version}")
    # v1: version, total blocks; v2+: plus stash entries and max stash.
    body = lines[2:] if version == 1 else lines[4:]

    commands = []
    for line in body:
        if not line:
            continue
        op, _, args = line.partition(" ")
        if op not in FULL_COMMANDS:
            raise ValueError(
                f'"{op}" found: this is an incremental payload, not a full one')
        commands.append((op, parse_ranges(args)))
    return commands


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        try:
            commands = parse_transfer_list(sys.argv[2])
        except (OSError, ValueError, IndexError) as e:
            sys.exit(f"{sys.argv[2]}: {e}")
        if not commands:
            sys.exit(f"{sys.argv[2]}: no commands")
        print(max(stop for _, r in commands for _, stop in r) * BLOCK_SIZE)
        return

    if len(sys.argv) != 4:
        sys.exit("usage: sdat2img.py <transfer.list> <new.dat or -> <output.img>")

    try:
        commands = parse_transfer_list(sys.argv[1])
    except (OSError, ValueError, IndexError) as e:
        sys.exit(f"{sys.argv[1]}: {e}")
    src = sys.stdin.buffer if sys.argv[2] == "-" else open(sys.argv[2], "rb")

    end = max(stop for _, ranges in commands for _, stop in ranges)
    with open(sys.argv[3], "wb") as out:
        out.truncate(end * BLOCK_SIZE)
        for op, ranges in commands:
            if op != "new":
                continue
            for start, stop in ranges:
                out.seek(start * BLOCK_SIZE)
                remaining = (stop - start) * BLOCK_SIZE
                while remaining:
                    chunk = src.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        sys.exit("new.dat ended before the transfer list")
                    out.write(chunk)
                    remaining -= len(chunk)

    if src.read(1):
        sys.exit("new.dat is longer than the transfer list")


if __name__ == "__main__":
    main()
