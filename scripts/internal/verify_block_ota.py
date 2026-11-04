#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Replays a block OTA transfer list on the host and checks the result.

    verify_block_ota.py --lib-dir <img2sdat dir> --work-dir <dir>
        --target <img> [--source <img>] --prefix <dir/partition>

Emulates the recovery's block_image_update (transfer list version 4) over
the source image, which is only read; written blocks go to a sparse overlay
(see Device).  Every stash, move and bsdiff source hash is checked, every
patch is applied with bspatch and its target hash checked, and the final
image must match the target image over its care map, with the extended
blocks zeroed.  Blocks the device may hold arbitrary data in (source
don't-care blocks, grown space, erased blocks) read as a pattern, so a
transfer list that relies on them fails here instead of on the device.

On success writes <prefix>.tgt_ranges/.tgt_sha1 (care map) and, when the
target has extended blocks, <prefix>.ext_ranges/.ext_sha1, which the
updater-script uses to verify the partition after it is written.
"""

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile

BLOCK = 4096
FILL = bytes([0x5A, 0xA5]) * (BLOCK // 2)
CHUNK_BLOCKS = 256


def fail(msg):
    sys.exit("verify_block_ota: " + msg)


def load_image(path, sparse_img, images):
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic == b"\x3a\xff\x26\xed":
        return sparse_img.SparseImage(path, None, clobbered_blocks="0")
    return images.FileImage(path)


class Device:
    """The partition as the recovery sees it while the update runs.

    The source image is only read.  Blocks the transfer list writes go to a
    sparse overlay file, so disk use follows the size of the update, not of
    the partition.  Blocks that were erased, or that hold no defined data on
    the device (source don't-care blocks, grown space), read as a pattern.
    """

    def __init__(self, path, blocks, src, RangeSet):
        self.blocks = blocks
        self.src = src
        self.RangeSet = RangeSet
        self.written = RangeSet()
        self.erased = RangeSet()
        self.src_care = src.care_map if src else RangeSet()
        self.fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
        os.ftruncate(self.fd, blocks * BLOCK)

    def _check(self, ranges):
        for _, end in ranges:
            if end > self.blocks:
                fail("access past the end of the partition (%d > %d)" % (end, self.blocks))

    def read(self, ranges):
        self._check(ranges)
        out = bytearray()
        for start, end in ranges:
            r = self.RangeSet(data=(start, end))
            pieces = [(a, b, "overlay") for a, b in r.intersect(self.written)]
            rest = r.subtract(self.written)
            pieces += [(a, b, "fill") for a, b in rest.intersect(self.erased)]
            rest = rest.subtract(self.erased)
            pieces += [(a, b, "source") for a, b in rest.intersect(self.src_care)]
            pieces += [(a, b, "fill") for a, b in rest.subtract(self.src_care)]
            for a, b, kind in sorted(pieces):
                if kind == "overlay":
                    out += os.pread(self.fd, (b - a) * BLOCK, a * BLOCK)
                elif kind == "source":
                    out += b"".join(self.src.ReadRangeSet(self.RangeSet(data=(a, b))))
                else:
                    out += FILL * (b - a)
        return bytes(out)

    def write(self, ranges, data):
        self._check(ranges)
        pos = 0
        for start, end in ranges:
            size = (end - start) * BLOCK
            os.pwrite(self.fd, data[pos:pos + size], start * BLOCK)
            pos += size
        if pos != len(data):
            fail("write size mismatch (%d != %d)" % (pos, len(data)))
        self.written = self.written.union(ranges)
        self.erased = self.erased.subtract(ranges)

    def erase(self, ranges):
        self._check(ranges)
        self.written = self.written.subtract(ranges)
        self.erased = self.erased.union(ranges)

    def sha1(self, ranges):
        h = hashlib.sha1()
        for start, end in ranges:
            for b in range(start, end, CHUNK_BLOCKS):
                h.update(self.read(self.RangeSet(data=(b, min(end, b + CHUNK_BLOCKS)))))
        return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib-dir", required=True)
    ap.add_argument("--work-dir", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--source")
    ap.add_argument("--prefix", required=True)
    args = ap.parse_args()

    sys.path.insert(0, args.lib_dir)
    import images
    import rangelib
    import sparse_img
    RangeSet = rangelib.RangeSet

    prefix = args.prefix
    with open(prefix + ".transfer.list") as f:
        lines = f.read().splitlines()
    if len(lines) < 4 or lines[0] != "4":
        fail("%s.transfer.list: expected version 4 header" % prefix)
    declared_total = int(lines[1])

    tgt = load_image(args.target, sparse_img, images)
    src = load_image(args.source, sparse_img, images) if args.source else None
    if tgt.blocksize != BLOCK or (src and src.blocksize != BLOCK):
        fail("unsupported block size")

    blocks = max(tgt.total_blocks, src.total_blocks if src else 0)
    work = tempfile.NamedTemporaryFile(dir=args.work_dir, delete=False)
    work.close()
    dev = Device(work.name, blocks, src, RangeSet)
    try:
        touched = prefix + ".touched_src_ranges"
        if src and os.path.exists(touched):
            with open(touched) as f:
                ranges = RangeSet.parse_raw(f.read().strip())
            with open(prefix + ".touched_src_sha1") as f:
                expected = f.read().strip()
            if dev.sha1(ranges) != expected:
                fail("touched source ranges do not hash to the recorded sha1")

        new_path = prefix + ".new.dat"
        new_f = open(new_path, "rb") if os.path.exists(new_path) else None
        patch_path = prefix + ".patch.dat"
        patch_f = open(patch_path, "rb") if os.path.exists(patch_path) else None
        stash = {}
        written = 0

        def load_src(tokens):
            count = int(tokens[0])
            buf = bytearray(count * BLOCK)
            rest = tokens[1:]
            if rest[0] == "-":
                rest = rest[1:]
            else:
                ranges = RangeSet.parse_raw(rest[0])
                data = dev.read(ranges)
                if len(rest) > 1 and ":" not in rest[1]:
                    locs = RangeSet.parse_raw(rest[1])
                    rest = rest[2:]
                else:
                    locs = RangeSet(data=(0, count))
                    rest = rest[1:]
                if locs.size() != ranges.size():
                    fail("source locations do not match the source ranges")
                pos = 0
                for start, end in locs:
                    size = (end - start) * BLOCK
                    buf[start * BLOCK:end * BLOCK] = data[pos:pos + size]
                    pos += size
            for ref in rest:
                sid, raw = ref.split(":", 1)
                if sid not in stash:
                    fail("reference to missing stash %s" % sid)
                data = stash[sid]
                pos = 0
                for start, end in RangeSet.parse_raw(raw):
                    size = (end - start) * BLOCK
                    buf[start * BLOCK:end * BLOCK] = data[pos:pos + size]
                    pos += size
            return bytes(buf)

        for n, line in enumerate(lines[4:], start=5):
            t = line.split()
            if not t:
                continue
            cmd = t[0]
            if cmd == "new":
                ranges = RangeSet.parse_raw(t[1])
                if new_f is None:
                    fail("line %d: new command without %s" % (n, new_path))
                data = new_f.read(ranges.size() * BLOCK)
                if len(data) != ranges.size() * BLOCK:
                    fail("line %d: new.dat is truncated" % n)
                dev.write(ranges, data)
                written += ranges.size()
            elif cmd == "zero":
                ranges = RangeSet.parse_raw(t[1])
                dev.write(ranges, bytes(ranges.size() * BLOCK))
                written += ranges.size()
            elif cmd == "erase":
                dev.erase(RangeSet.parse_raw(t[1]))
            elif cmd == "stash":
                ranges = RangeSet.parse_raw(t[2])
                data = dev.read(ranges)
                if hashlib.sha1(data).hexdigest() != t[1]:
                    fail("line %d: stash source does not match %s" % (n, t[1]))
                stash[t[1]] = data
            elif cmd == "free":
                stash.pop(t[1], None)
            elif cmd == "move":
                ranges = RangeSet.parse_raw(t[2])
                data = load_src(t[3:])
                if hashlib.sha1(data).hexdigest() != t[1]:
                    fail("line %d: move source does not match %s" % (n, t[1]))
                dev.write(ranges, data)
                written += ranges.size()
            elif cmd == "bsdiff":
                offset, length, src_hash, tgt_hash = int(t[1]), int(t[2]), t[3], t[4]
                ranges = RangeSet.parse_raw(t[5])
                data = load_src(t[6:])
                if hashlib.sha1(data).hexdigest() != src_hash:
                    fail("line %d: bsdiff source does not match %s" % (n, src_hash))
                if patch_f is None:
                    fail("line %d: bsdiff command without %s" % (n, patch_path))
                patch_f.seek(offset)
                patch = patch_f.read(length)
                if len(patch) != length:
                    fail("line %d: patch.dat is truncated" % n)
                with tempfile.TemporaryDirectory(dir=args.work_dir) as tmp:
                    old, new, pat = (os.path.join(tmp, x) for x in ("old", "new", "patch"))
                    with open(old, "wb") as f:
                        f.write(data)
                    with open(pat, "wb") as f:
                        f.write(patch)
                    r = subprocess.run(["bspatch", old, new, pat], capture_output=True)
                    if r.returncode != 0:
                        fail("line %d: bspatch failed: %s" % (n, r.stderr.decode(errors="replace")))
                    with open(new, "rb") as f:
                        out = f.read()
                if len(out) != ranges.size() * BLOCK or hashlib.sha1(out).hexdigest() != tgt_hash:
                    fail("line %d: bsdiff result does not match %s" % (n, tgt_hash))
                dev.write(ranges, out)
                written += ranges.size()
            elif cmd == "imgdiff":
                fail("line %d: imgdiff transfers are not supported by this verifier" % n)
            else:
                fail("line %d: unknown command %r" % (n, cmd))

        if new_f is not None:
            if new_f.read(1):
                fail("new.dat has trailing data")
            new_f.close()
        if patch_f is not None:
            patch_f.close()
        if stash:
            fail("%d stash slot(s) were never freed" % len(stash))
        if written != declared_total:
            fail("transfer list declares %d blocks, %d written" % (declared_total, written))

        care = tgt.care_map
        expected = tgt.TotalSha1(include_clobbered_blocks=True)
        result = dev.sha1(care)
        if result != expected:
            fail("replayed image does not match the target (%s != %s)" % (result, expected))
        with open(prefix + ".tgt_ranges", "w") as f:
            f.write(care.to_string_raw())
        with open(prefix + ".tgt_sha1", "w") as f:
            f.write(expected)
        ext = tgt.extended
        if ext.size():
            zero = hashlib.sha1(bytes(ext.size() * BLOCK)).hexdigest()
            if dev.sha1(ext) != zero:
                fail("extended blocks are not zero after the update")
            with open(prefix + ".ext_ranges", "w") as f:
                f.write(ext.to_string_raw())
            with open(prefix + ".ext_sha1", "w") as f:
                f.write(zero)
        print("verified %s: %d care blocks, sha1 %s" % (os.path.basename(prefix), care.size(), expected))
    finally:
        os.close(dev.fd)
        os.unlink(work.name)


if __name__ == "__main__":
    main()
