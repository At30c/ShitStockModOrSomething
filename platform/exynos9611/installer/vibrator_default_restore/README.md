# Restore the M21s vibrator.default.so

Creates a TWRP ZIP containing the original M21s
`vendor/lib64/hw/vibrator.default.so`. The installer remounts `/vendor`,
releases the ext4 reserved clusters used by this full vendor image, restores
the file label and verifies the payload after writing.
