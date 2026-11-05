#!/usr/bin/env bash
# Regenerates tests/fixtures/settings/*.app-config.json: what the repo CLI's
# `khuluma app-config --json` reports for each fixture config, the parity
# target for the app's settings.json (native/Tests/KhulumaCoreTests/SettingsTests).
# Runs in a temp root only (never the real ~/.config); paths in the output
# are rewritten to @ROOT@. Run once by hand; commit the output.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/tests/fixtures/settings"

run() { # name config-file-or-empty
  local name="$1" src="$2" root
  root="$(mktemp -d "${TMPDIR:-/tmp}/khuluma-settings-fixture.XXXXXX")"
  root="$(cd "$root" && pwd -P)"
  mkdir -p "$root/config" "$root/home" "$root/data/sounds/khuluma" "$root/sounds" "$root/models/parakeet-custom-v2" "$root/tmp"
  # Files the full fixture points at, and one default-dir sound.
  : >"$root/sounds/start.wav"; : >"$root/sounds/process.wav"; : >"$root/data/sounds/khuluma/error.wav"
  [[ -z "$src" ]] || sed "s|@ROOT@|$root|g" "$src" >"$root/config/config.toml"
  env -i PATH="$PATH" HOME="$root/home" TMPDIR="$root/tmp" \
    XDG_CONFIG_HOME="$root/home/.config" XDG_DATA_HOME="$root/data" KHULUMA_CONFIG_DIR="$root/config" \
    KHULUMA_PROCESSING_DIR=/tmp/khuluma-processing \
    "$repo/bin/khuluma" app-config --json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, indent=2, sort_keys=True).replace(sys.argv[1], "@ROOT@"))' "$root" \
    >"$out/$name.app-config.json"
  rm -rf "$root"
}

run defaults ""
for dir in "$repo"/tests/fixtures/cleanup/configs/*/; do
  run "cleanup-$(basename "$dir")" "$dir/config.toml"
done
run full "$out/full/config.toml"
run cloud "$out/cloud/config.toml"
echo "wrote $out"
