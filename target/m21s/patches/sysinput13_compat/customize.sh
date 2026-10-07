#!/usr/bin/env bash
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "m21s" ]]; then
    return 0
fi

# The vendor service, libraries, VINTF manifest and SELinux labels are applied
# by target/m21s/mods/vendor. This module owns the system-side compatibility
# matrix declaration only.
python3 - "$WORK_DIR/system/system/etc/vintf/compatibility_matrix.device.xml" <<'PY'
import re
import sys
from pathlib import Path

matrix = Path(sys.argv[1])
text = matrix.read_text()
pattern = re.compile(
    r'    <hal format="hidl" optional="true">\s*'
    r'<name>vendor\.samsung\.hardware\.sysinput</name>.*?'
    r'    </hal>\n', re.S)
block = '''    <hal format="hidl" optional="true">
        <name>vendor.samsung.hardware.sysinput</name>
        <version>1.3</version>
        <interface>
            <name>ISehSysInputCallback</name>
        </interface>
        <interface>
            <name>ISehSysInputDev</name>
            <instance>default</instance>
        </interface>
    </hal>
'''
matches = list(pattern.finditer(text))
if matches:
    matrix.write_text(text[:matches[0].start()] + block + text[matches[-1].end():])
elif '</compatibility-matrix>' in text:
    matrix.write_text(text.replace('</compatibility-matrix>', block + '</compatibility-matrix>', 1))
else:
    raise SystemExit("M21s device compatibility matrix is malformed")
PY
