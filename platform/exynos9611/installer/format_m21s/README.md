# Experimental M21s/F41 filesystem formatter

Run this standalone ZIP **after** the repartitioner has completed and after
rebooting recovery so that the new by-name links are visible. It formats:

- `prism`, `optics`, `omr` and `cache` as legacy-compatible ext4;
- `userdata` as Android F2FS using the recovery's `make_f2fs -g android` profile.

It intentionally does not format `super`: `super` is a dynamic-partition
container and must receive the ROM's `super.img` contents. It also does not
format `nad_fw`, which is a raw firmware/NAD partition rather than a mounted
filesystem. `metadata` is untouched because the repartitioner does not recreate
it.

The ZIP is restricted to the F415F/f41 bootloader identity on Exynos 9611. It
uses `mke2fs` and `make_f2fs` supplied by recovery and aborts if either tool or
any expected by-name partition is missing. The result is logged to
`/tmp/m21s-format.log` and the status marker is `/tmp/m21s-format.status`.
Formatting `userdata` is destructive; keep stock firmware/PIT available.

Build it with:

```sh
./build.sh
```

The output is written to `out/target/m21s/m21s-filesystem-formatter-experimental.zip`.
