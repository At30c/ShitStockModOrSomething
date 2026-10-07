# Experimental M21s repartitioner

This package is for the 64-GB Galaxy M21s/Galaxy F41 (`SM-F415F`, `f41`) and
is a boot-test aid for the M21s ext4 target. It enlarges the physical `super`
to **11305 MiB**, based on the current M21s ext4 build images (about 11045 MiB)
plus a 256-MiB build margin and metadata space. It recreates `prism` (1024 MiB), `optics` (33 MiB),
`cache` (200 MiB), optional `omr` (3 MiB), and `userdata` with the remaining
sectors.

The recovery model string may say `SM-M215F/m21` because the unified M21/F41
TWRP uses that product identity; the script therefore also requires the
bootloader to report `ro.boot.em.model=SM-F415F` and `ro.boot.hardware=exynos9611`.
A real M215F without that bootloader identity is refused. The layout is
deliberately not applied by the normal ROM build. Flash this
standalone ZIP from a compatible custom recovery, reboot recovery when it
finishes, format data/cache, and only then flash the ROM. Keep a complete
stock F415F ZTO firmware/PIT available: a wrong model or an interrupted GPT
rewrite can require Odin/PIT recovery and can erase all user data.

The repartition script is adapted from the downloaded
`repartitioner_A21s_Exinos850-v2024.05.zip`. Credits from that work are
preserved: the original universal repartitioner was written by **@Astrako**
for Exynos 7870 and later modified for the A217F/A21s family. The `update-
binary` and `sgdisk` executables are retained from those donor packages.

To make an installable ZIP from this directory:

```sh
./build.sh
```

The output is written to `out/target/m21s/m21s-repartitioner-experimental.zip`.

The builder also accepts a custom output path and physical `super` size in
MiB. This is used when the ext4 image set needs a larger temporary layout:

```sh
./build.sh /absolute/path/m21s-repartitioner-ext4-experimental.zip 12275
```

The source `repartition.sh` is not modified; the requested size is injected
only into the packaged copy.
