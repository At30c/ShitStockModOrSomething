# M21s sensorhub DTBO test ZIP

Build with:

```sh
platform/exynos9611/installer/dtbo_sensorhub_m21s/build.sh
```

The ZIP contains only `dtbo.img`. It refuses an image that references the M31
sensorhub firmware, writes directly to `/dev/block/by-name/dtbo`, and verifies
the exact written byte range using SHA-256. It does not modify boot, system,
vendor, data, or dynamic-partition metadata.

It also accepts only the Samsung DT-table container (`d7b7ab1e`). Kernel build
outputs such as `exynos9611-m21_swa_open_00.dtbo` are bare FDT overlays
(`d00dfeed`), not complete Samsung `dtbo` partitions. They must never be
flashed directly: the bootloader rejects them with `DT LOAD Fail`. A future
sensorhub solution must merge the M21 overlay into the stock DT-table image.
