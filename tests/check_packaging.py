#!/usr/bin/env python3
"""The real inputs tools/build-khuluma-app.sh packages exist, and native/VERSION is valid.

test_app_build_helpers.py runs the script against fabricated assets, so this
checks the repo's own: every "$ROOT/..." resource variable in the script, the
bundled sounds it copies, the entitlements it signs with.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
script = (ROOT / "tools/build-khuluma-app.sh").read_text()
problems = []

# File resources only (PKG="$ROOT/native" is the package folder).
resources = [r for r in re.findall(r'^[A-Z_]+="\$ROOT/([^"$]+)"$', script, re.M) if Path(r).suffix]
if len(resources) < 2:
    problems.append("found no resource variables in build-khuluma-app.sh; update this check")
for rel in resources:
    path = ROOT / rel
    if not (path.is_file() and path.stat().st_size > 0):
        problems.append(f"missing or empty: {rel}")

for pattern in re.findall(r'cp "\$SRC"/(\S+) ', script):
    if not list(ROOT.glob(pattern)):
        problems.append(f"nothing matches: {pattern}")
if "assets/sounds/khuluma/*.wav" not in re.findall(r'cp "\$SRC"/(\S+) ', script):
    problems.append("build script no longer copies assets/sounds/khuluma/*.wav; update this check")

for rel in re.findall(r'"\$PKG/([^"$]+)"', script):
    if not (ROOT / "native" / rel).is_file():
        problems.append(f"missing: native/{rel}")

version = (ROOT / "native/VERSION").read_text().strip() if (ROOT / "native/VERSION").is_file() else ""
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    problems.append(f"native/VERSION is not MAJOR.MINOR.PATCH: {version!r}")

for p in problems:
    print("packaging:", p, file=sys.stderr)
if problems:
    sys.exit(1)
print(f"Packaging inputs present ({len(resources)} resources, version {version}).")
