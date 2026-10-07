# F41/M21s M31 sensorhub firmware test

This TWRP ZIP changes only `/vendor/firmware/sensorhub/shub_ramen_m31.fw`.
The retained stock F41 DTBO requests that filename. It does not alter boot,
DTBO, super metadata, data, or the kernel image. The test requires the ext4
vendor test image to be mounted writable in TWRP.
