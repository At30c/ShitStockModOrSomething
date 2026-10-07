# READ_AND_APPLY_PROPS treats an empty value in *.prop as a delete request.
# Restore the deliberate empty ABI-32 properties after those files are read;
# the M21s contract requires the keys to exist with an empty value in vendor
# and odm, while system remains source-only/only-64.
if [[ "$TARGET_PLATFORM" == "exynos9611" ]]; then
    SET_PROP "vendor" "ro.vendor.product.cpu.abilist" "arm64-v8a"
    SET_PROP "vendor" "ro.vendor.product.cpu.abilist32" ""
    SET_PROP "vendor" "ro.vendor.product.cpu.abilist64" "arm64-v8a"
    SET_PROP "odm" "ro.odm.product.cpu.abilist" "arm64-v8a"
    SET_PROP "odm" "ro.odm.product.cpu.abilist32" ""
    SET_PROP "odm" "ro.odm.product.cpu.abilist64" "arm64-v8a"
fi
