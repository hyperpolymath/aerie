#!/usr/bin/env python3
from pathlib import Path

BANNER = """// GENERATED FILE - DO NOT EDIT
// Source: specs/components/*.k9.ncl
// Regenerate: specs/tools/update_manifest.sh
"""

ROOT = Path(__file__).resolve().parents[1]
OUTPUTS = ROOT / "outputs"

for path in sorted(OUTPUTS.glob("*.adoc")):
    text = path.read_text()
    if text.startswith("// GENERATED FILE - DO NOT EDIT"):
        continue
    path.write_text(BANNER + text)
