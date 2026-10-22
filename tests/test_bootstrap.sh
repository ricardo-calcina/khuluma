#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_ROOT"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT

# Build a local archive that mirrors GitHub codeload structure: khuluma-<ref>/
ARCHIVE_ROOT="$TMP_ROOT/archive-root"
SNAPSHOT_DIR="$ARCHIVE_ROOT/khuluma-main"
mkdir -p "$SNAPSHOT_DIR"

(
  cd "$ROOT"
  COPYFILE_DISABLE=1 tar --exclude='.git' --exclude='native/.build' -cf "$TMP_ROOT/src.tar" .
)
tar -xf "$TMP_ROOT/src.tar" -C "$SNAPSHOT_DIR"
COPYFILE_DISABLE=1 tar -czf "$TMP_ROOT/khuluma-main.tar.gz" -C "$ARCHIVE_ROOT" khuluma-main

HOME="$TMP_ROOT/home"
export HOME
# Isolate XDG data too, or the installer writes into the real user's
# ~/.local/share (native daemon sources, models) and may refresh their daemon.
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export KHULUMA_INSTALL_WARMUP=0
mkdir -p "$HOME"

ARCHIVE_URL="file://$TMP_ROOT/khuluma-main.tar.gz"

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "Missing file: $path" >&2
    exit 1
  }
}

assert_not_file() {
  local path="$1"
  [[ ! -f "$path" ]] || {
    echo "Unexpected file present: $path" >&2
    exit 1
  }
}

bootstrap_help="$("$ROOT/bootstrap.sh" --help)"
if [[ "$bootstrap_help" != *"Installs Khuluma from a GitHub source archive."* ]]; then
  echo "Expected bootstrap help to describe Khuluma branding" >&2
  exit 1
fi
if [[ "$bootstrap_help" != *"--ref REF"* ]]; then
  echo "Expected bootstrap help to document pinned refs" >&2
  exit 1
fi
if [[ "$bootstrap_help" != *"ricardo-nth/khuluma/main/bootstrap.sh"* ]]; then
  echo "Expected bootstrap help to reference the canonical source" >&2
  exit 1
fi

# Pass-through args should reach install.sh.
bootstrap_output="$(KHULUMA_BOOTSTRAP_ARCHIVE_URL="$ARCHIVE_URL" "$ROOT/bootstrap.sh" --no-sounds)"
if [[ "$bootstrap_output" != *"Bootstrap source: ricardo-nth/khuluma@main"* ]]; then
  echo "Expected bootstrap output to report source repo/ref" >&2
  exit 1
fi
if [[ "$bootstrap_output" != *"Bootstrap archive: $ARCHIVE_URL"* ]]; then
  echo "Expected bootstrap output to report archive URL" >&2
  exit 1
fi

assert_file "$HOME/.local/bin/khuluma"
assert_file "$HOME/.config/khuluma/config.toml"
assert_file "$HOME/.config/khuluma/install-receipt.env"
assert_not_file "$HOME/.local/share/sounds/khuluma/start.wav"
if ! rg -q '^install_source=bootstrap:ricardo-nth/khuluma@main$' "$HOME/.config/khuluma/install-receipt.env"; then
  echo "Expected bootstrap install receipt source" >&2
  exit 1
fi

KHULUMA_BOOTSTRAP_REF=ignored "$ROOT/bootstrap.sh" --archive-url "$ARCHIVE_URL" --ref test-ref --with-sounds
assert_file "$HOME/.local/share/sounds/khuluma/start.wav"
if ! rg -q '^install_source=bootstrap:ricardo-nth/khuluma@test-ref$' "$HOME/.config/khuluma/install-receipt.env"; then
  echo "Expected --ref to be reflected in bootstrap install receipt" >&2
  exit 1
fi

echo "Bootstrap smoke tests passed."
