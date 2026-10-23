#!/usr/bin/env bash
# Compile only the macOS 26+ icon catalog. Never build or modify an app bundle.
# Full-bleed derivatives of the approved artwork use explicit default/dark images.
# Reproduce them with tools/make-khuluma-icons.swift: the same source raster crop
# and mask as the legacy exports, without their 100px canvas inset. The native
# catalog supplies that outer container; copying legacy PNGs here nests two tiles.
# Schema references (structure only; no third-party artwork is included):
# https://github.com/OpenSC2K/OpenSC2K/blob/7b38850dc0520279f60023e7ad41fc461c118f0a/game/assets/icons/OpenSC2K.icon/icon.json
# https://github.com/insidegui/AssetCatalogTinkerer/blob/f5208620695b1eec451d6943beeb4ac1bfd37c63/Resources/AppIconV5.icon/icon.json
# Icon-only actool reference:
# https://github.com/jimeh/emacs-liquid-glass-icons/blob/main/Makefile
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT/assets/icons/AppIcon.icon"
OUT=""
usage() { echo "usage: $0 --out NEW_DIRECTORY (requires Xcode 26 or later)" >&2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      shift
      [[ $# -gt 0 && -n "$1" ]] || { usage; exit 2; }
      OUT="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done
[[ -n "$OUT" ]] || { usage; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }
OUT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$OUT")"
[[ ! -e "$OUT" && ! -L "$OUT" && -d "$(dirname "$OUT")" ]] || {
  echo "Output must be a fresh directory beneath an existing parent: $OUT" >&2
  exit 2
}

ACTOOL="$(xcrun --find actool 2>/dev/null)" || {
  echo "The selected developer directory has no actool. Full Xcode 26 or later is required; Command Line Tools cannot compile .icon sources." >&2
  exit 2
}
xcode_version="$(xcodebuild -version)"
xcode_major="$(printf '%s\n' "$xcode_version" | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p')"
[[ -n "$xcode_major" && "$xcode_major" -ge 26 ]] || {
  echo "Xcode 26 or later is required; selected toolchain: $xcode_version" >&2
  exit 2
}

# Check declared layer names and native input dimensions without an image library.
# Artwork remains reproducible from raised-*-preview.png via the native exporter.
python3 - "$SOURCE" <<'PY'
import json, pathlib, struct, sys
source = pathlib.Path(sys.argv[1])
document = json.loads((source / "icon.json").read_text())
layer = document["groups"][0]["layers"][0]
assert layer["image-name-specializations"] == [
    {"value": "Khuluma-Light.png"},
    {"appearance": "dark", "value": "Khuluma-Dark.png"},
], "The icon must retain the explicit approved appearances"
for appearance in ("Light", "Dark"):
    name = f"Khuluma-{appearance}.png"
    artwork = (source / "Assets" / name).read_bytes()
    assert artwork[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {name}"
    assert artwork[12:16] == b"IHDR", f"Missing PNG header: {name}"
    assert struct.unpack(">II", artwork[16:24]) == (1024, 1024), f"Expected 1024px: {name}"
print("Validated declared 1024px light/dark catalog artwork.")
PY

mkdir "$OUT"
printf '%s\n' "$xcode_version"
"$ACTOOL" "$SOURCE" \
  --compile "$OUT" \
  --app-icon AppIcon \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --enable-on-demand-resources NO \
  --development-region en \
  --output-format human-readable-text \
  --notices --warnings --errors \
  --output-partial-info-plist "$OUT/partial-info.plist"

python3 - "$OUT" <<'PY'
import pathlib, plistlib, sys
output = pathlib.Path(sys.argv[1])
catalog = output / "Assets.car"
if not catalog.is_file() or catalog.stat().st_size == 0:
    raise SystemExit("actool did not produce a nonempty Assets.car")
with (output / "partial-info.plist").open("rb") as handle:
    partial = plistlib.load(handle)
if partial.get("CFBundleIconName") != "AppIcon":
    raise SystemExit(f"Unexpected compiled icon name: {partial.get('CFBundleIconName')!r}")
print(f"Verified catalog: {catalog} ({catalog.stat().st_size} bytes)")
print("Verified partial plist: CFBundleIconName=AppIcon")
PY
shasum -a 256 "$OUT/Assets.car" "$OUT/partial-info.plist"
echo "Catalog ready. Inspect its rendered light/dark appearances before app integration."
