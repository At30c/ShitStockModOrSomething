#!/usr/bin/env python3
"""Keep Android 17 media on the M21s primary PCM backend."""

from pathlib import Path
import sys


if len(sys.argv) != 2:
    raise SystemExit("usage: force_m21s_primary_output.py <policy.xml>")

policy = Path(sys.argv[1])
text = policy.read_text()
old = 'flags="AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_DEEP_BUFFER"'
new = 'flags="AUDIO_OUTPUT_FLAG_PRIMARY"'
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one M21s combined primary/deep-buffer port, found {count}")

policy.write_text(text.replace(old, new, 1))
