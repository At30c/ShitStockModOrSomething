if $DEBUG; then
    LOG "\033[0;33m! Debug build detected. Skipping\033[0m"
    return 0
fi

# Keep the One UI 9 wallpaper stack (SpriteWallpaper, AiWallpaper and its
# feature catalogues), but restore the target device's own default wallpaper
# catalogue and media. Replacing wallpaper-res.apk wholesale with its One UI
# 5.1 counterpart would discard newer wallpaper features and can break the
# resource contract expected by the current SpriteWallpaper.
TARGET_FIRMWARE_PATH="$(cut -d "/" -f 1 -s <<< "$TARGET_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$TARGET_FIRMWARE")"
TARGET_WALLPAPER_APK="$FW_DIR/$TARGET_FIRMWARE_PATH/system/system/priv-app/wallpaper-res/wallpaper-res.apk"
WALLPAPER_APK_RELATIVE_PATH="system/priv-app/wallpaper-res/wallpaper-res.apk"
WALLPAPER_APK_DIR="$APKTOOL_DIR/$WALLPAPER_APK_RELATIVE_PATH"
TARGET_WALLPAPER_TMP="$(mktemp -d "$TMP_DIR/target-wallpaper.XXXXXX")"

if [ ! -f "$TARGET_WALLPAPER_APK" ]; then
    ABORT "Target wallpaper resources not found: $TARGET_WALLPAPER_APK"
fi

LOG "- Restoring original $TARGET_CODENAME wallpaper catalogue and assets"
DECODE_APK "system" "$WALLPAPER_APK_RELATIVE_PATH"

# Extract the target catalogue and resolve only the assets referenced by its
# phone and DeX lists. Everything else in the One UI 9 package is untouched.
EVAL "unzip -qq \"$TARGET_WALLPAPER_APK\" 'res/drawable*/*' 'res/raw/*' -d \"$TARGET_WALLPAPER_TMP\"" || \
    ABORT "Failed to extract target wallpaper resources"

TARGET_DRAWABLE_DIR="$(find "$TARGET_WALLPAPER_TMP/res" -maxdepth 1 -type d -name 'drawable-nodpi*' -print -quit)"
SOURCE_DRAWABLE_DIR="$(find "$WALLPAPER_APK_DIR/res" -maxdepth 1 -type d -name 'drawable-nodpi*' -print -quit)"
TARGET_RAW_DIR="$TARGET_WALLPAPER_TMP/res/raw"
SOURCE_RAW_DIR="$WALLPAPER_APK_DIR/res/raw"

if [ -z "$TARGET_DRAWABLE_DIR" ] || [ -z "$SOURCE_DRAWABLE_DIR" ] || \
        [ ! -f "$TARGET_RAW_DIR/resources_info.json" ] || [ ! -d "$SOURCE_RAW_DIR" ]; then
    ABORT "Target or source wallpaper resource layout is incomplete"
fi

# A catalogue may name a PNG while the compiled resource is stored as WebP.
# Resolve by the basename, then copy only that normal/DeX wallpaper asset.
# Do not touch target thumbnails, graphics, colors, frames, or source-only
# One UI 9 feature resources.
while IFS= read -r TARGET_WALLPAPER_FILE; do
    TARGET_WALLPAPER_BASE="${TARGET_WALLPAPER_FILE%.*}"
    if [[ "$TARGET_WALLPAPER_FILE" == *.mp4 ]]; then
        TARGET_WALLPAPER_ASSET="$TARGET_RAW_DIR/$TARGET_WALLPAPER_FILE"
        SOURCE_WALLPAPER_DIR="$SOURCE_RAW_DIR"
    else
        TARGET_WALLPAPER_ASSET="$(find "$TARGET_DRAWABLE_DIR" -maxdepth 1 -type f \
            \( -name "$TARGET_WALLPAPER_FILE" -o -name "$TARGET_WALLPAPER_BASE.webp" -o -name "$TARGET_WALLPAPER_BASE.png" \) \
            -print -quit)"
        SOURCE_WALLPAPER_DIR="$SOURCE_DRAWABLE_DIR"
    fi
    if [ -z "$TARGET_WALLPAPER_ASSET" ] || [ ! -f "$TARGET_WALLPAPER_ASSET" ]; then
        ABORT "Target wallpaper asset is missing: $TARGET_WALLPAPER_FILE"
    fi
    EVAL "cp -a \"$TARGET_WALLPAPER_ASSET\" \"$SOURCE_WALLPAPER_DIR/\"" || \
        ABORT "Failed to copy target wallpaper: $TARGET_WALLPAPER_FILE"
done < <(jq -r '.phone[].filename?, .dex[].filename? | select(type == "string" and length > 0)' \
    "$TARGET_RAW_DIR/resources_info.json" | sort -u)

# resources_info.json has compatible phone/dex lists in One UI 5.1 and One UI
# 9. Replace those lists and their matching default-type table. Keeping the
# source `types` table while importing a static target lock wallpaper leaves
# `which=2` advertised as video (type 8) without a video filename; SystemUI
# then tries to open com.samsung.android.wallpaper.res/null and never reaches
# the decoder. Keep the package version and all unrelated One UI 9 sidecars.
jq --slurpfile target "$TARGET_RAW_DIR/resources_info.json" \
    '.phone = $target[0].phone |
     .dex = $target[0].dex |
     .types = ($target[0].types // [])' \
    "$SOURCE_RAW_DIR/resources_info.json" > "$SOURCE_RAW_DIR/resources_info.json.new" || \
    ABORT "Failed to merge target wallpaper catalogue"

# Every explicit default type must resolve to a default catalogue entry of the
# same kind with a real asset name. Reject a broken catalogue at build time
# instead of leaving ImageWallpaper permanently in RELEASED state at runtime.
jq -e '
    . as $catalogue |
    all($catalogue.types[]?; . as $type |
        any($catalogue.phone[]?;
            .isDefault == true and
            .which == $type.which and
            .screen == $type.screen and
            .type == $type.type and
            ((.filename // "") | length > 0)))
' "$SOURCE_RAW_DIR/resources_info.json.new" > /dev/null || \
    ABORT "Merged wallpaper catalogue has a default type without a matching asset"

EVAL "mv -f \"$SOURCE_RAW_DIR/resources_info.json.new\" \"$SOURCE_RAW_DIR/resources_info.json\"" || \
    ABORT "Failed to install merged wallpaper catalogue"

# Android resource filenames must use the lowercase resource-name alphabet.
# The One UI 9 source APK keeps these legacy assets with uppercase names; the
# decoded tree is usable for inspection but aapt2 rejects those names while
# rebuilding the APK. Keep the public resource IDs stable and normalize only
# the affected filenames/public.xml entries.
for WALLPAPER_RESOURCE in \
    Wallpaper_001 Wallpaper_002 Wallpaper_003 Wallpaper_004 \
    Wallpaper_005 Wallpaper_006 Wallpaper_007 Wallpaper_008 \
    Default_Video_Wallpaper_ZALG Default_Video_Wallpaper_ZK \
    Default_Video_Wallpaper_ZVLB Default_Video_Wallpaper_ZYZO; do
    WALLPAPER_RESOURCE_LOWER="${WALLPAPER_RESOURCE,,}"
    if [ -f "$SOURCE_DRAWABLE_DIR/$WALLPAPER_RESOURCE.webp" ]; then
        EVAL "mv -f \"$SOURCE_DRAWABLE_DIR/$WALLPAPER_RESOURCE.webp\" \"$SOURCE_DRAWABLE_DIR/$WALLPAPER_RESOURCE_LOWER.webp\"" || \
            ABORT "Failed to normalize wallpaper resource: $WALLPAPER_RESOURCE"
    elif [ -f "$SOURCE_RAW_DIR/$WALLPAPER_RESOURCE.mp4" ]; then
        EVAL "mv -f \"$SOURCE_RAW_DIR/$WALLPAPER_RESOURCE.mp4\" \"$SOURCE_RAW_DIR/$WALLPAPER_RESOURCE_LOWER.mp4\"" || \
            ABORT "Failed to normalize video wallpaper resource: $WALLPAPER_RESOURCE"
    fi
    if grep -q "name=\"$WALLPAPER_RESOURCE\"" "$WALLPAPER_APK_DIR/res/values/public.xml"; then
        sed -i "s/name=\"$WALLPAPER_RESOURCE\"/name=\"$WALLPAPER_RESOURCE_LOWER\"/" \
            "$WALLPAPER_APK_DIR/res/values/public.xml"
    fi
done

EVAL "rm -rf \"$TARGET_WALLPAPER_TMP\""
unset TARGET_FIRMWARE_PATH TARGET_WALLPAPER_APK WALLPAPER_APK_RELATIVE_PATH \
    WALLPAPER_APK_DIR TARGET_WALLPAPER_TMP TARGET_DRAWABLE_DIR SOURCE_DRAWABLE_DIR \
    TARGET_RAW_DIR SOURCE_RAW_DIR TARGET_WALLPAPER_FILE TARGET_WALLPAPER_BASE \
    TARGET_WALLPAPER_ASSET SOURCE_WALLPAPER_DIR
