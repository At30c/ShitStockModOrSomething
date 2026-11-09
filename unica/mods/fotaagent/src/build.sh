#!/usr/bin/env bash
# Rebuilds the io.unica.fota.UpdateChecker and PartProxy smali carried by patch 0018.
# Usage: build.sh <android.jar> <d8> <apktool.jar> <output dir>
# The stubs only exist to compile against FotaAgent classes; they are not
# shipped. Copy <output dir>/io/unica/fota/*.smali into the
# smali_classes2 tree of the patched app and regenerate the patch.
set -e
AJ="$1"; D8="$2"; APKTOOL="$3"; OUT="$4"
[ -f "$AJ" ] && [ -x "$D8" ] && [ -f "$APKTOOL" ] && [ -n "$OUT" ] || {
    echo "Usage: $0 <android.jar> <d8> <apktool.jar> <output dir>" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs" "$TMP/cls" "$TMP/dex"
javac -source 11 -target 11 -nowarn -cp "$AJ" -d "$TMP/stubs" $(find "$SRC/stubs" -name "*.java")
javac -source 11 -target 11 -nowarn -cp "$AJ:$TMP/stubs" -d "$TMP/cls" "$SRC"/io/unica/fota/*.java
"$D8" --min-api 30 --lib "$AJ" --classpath "$TMP/stubs" --output "$TMP/dex" $(find "$TMP/cls" -name "*.class")
java -cp "$APKTOOL" com.android.tools.smali.baksmali.Main d --api 30 "$TMP/dex/classes.dex" -o "$OUT"
