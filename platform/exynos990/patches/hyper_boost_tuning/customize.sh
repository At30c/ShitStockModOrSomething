SKIPUNZIP=1

# The S20 hyper-service (config_chipset.json from the G986B vendor) holds CPU
# frequency floors much longer than the S26+ one does for the same hints:
# app launch 2 s at the top frequency, list/smooth scroll 10 s, wakeup 1 s.
# The S26+ uses 1 s for launches, no floor for scrolls (the touch level of
# EMS covers them) and 500 ms for wakeup. Keep the floors, shorten them.
# The CPU frequencies are also moved to the exact UFC values (patch 0016).
HYPER_CONFIG="$WORK_DIR/vendor/etc/hyper/config_chipset.json"

if [ ! -f "$HYPER_CONFIG" ]; then
    LOGE "Hyper config not found: ${HYPER_CONFIG//$WORK_DIR/}"
    return 1
fi

LOG "- Shortening hyper-service boost durations"
python3 - "$HYPER_CONFIG" << 'PYEOF' || return 1
import json
import sys

path = sys.argv[1]
durations = {
    "AMS_APP_LAUNCH_M": "1000",
    "AMS_APP_LAUNCH_LM": "1000",
    "LISTVIEW_SCROLL": "2000",
    "SMOOTH_SCROLL": "2000",
    "DEVICE_WAKEUP": "500",
}

with open(path, encoding="utf-8") as f:
    config = json.load(f)

# Kernel patch 0016 replaced the UFC virtual frequencies of the big cluster
# with the exact ones; requests for an old value are rounded by the UFC, but
# keep them exact so nothing depends on that rounding.
ufc_values = {
    "2623359": "2626000", "2519384": "2522000", "2415410": "2418000",
    "2311435": "2314000", "2207460": "2210000", "2103486": "2106000",
    "1999511": "2002000", "1895537": "1898000", "1791562": "1794000",
    "1687587": "1690000", "1583613": "1586000", "1479638": "1482000",
    "1375664": "1378000", "1271689": "1274000", "1167714": "1170000",
    "1063740": "1066000", "959765": "962000", "855791": "858000",
    "751816": "754000", "647841": "650000", "543867": "546000",
}

found = set()
for hint in config["Hints"]:
    for resource in hint.get("ResoureList", []):
        if resource.get("Resource") in ("CPUMinFreq", "CPUMaxFreq") and \
                resource.get("Value") in ufc_values:
            resource["Value"] = ufc_values[resource["Value"]]
    name = hint.get("Hint")
    if name in durations:
        print(f"  {name}: {hint.get('Duration')} -> {durations[name]} ms")
        hint["Duration"] = durations[name]
        found.add(name)

missing = set(durations) - found
if missing:
    sys.exit(f"hints not found: {', '.join(sorted(missing))}")

with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
    f.write("\n")
PYEOF
