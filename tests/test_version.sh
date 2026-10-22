#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_ROOT"
source "$ROOT/tests/fixture_helpers.sh"
# Never read or write the real user's ~/.local/share (daemon build, models).
export XDG_DATA_HOME="$TMP_ROOT/xdg-data"
export KHULUMA_DAEMON_BACKGROUND_REFRESH=0
trap report_fixture_root EXIT

BIN_DIR="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
CONFIG_DIR="$HOME_DIR/.config/khuluma"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$CONFIG_DIR"
BIN_REAL="$(cd "$BIN_DIR" && pwd -P)/khuluma"

cp "$ROOT/bin/khuluma" "$BIN_DIR/khuluma"
cp "$ROOT/bin/khuluma-lib.sh" "$BIN_DIR/khuluma-lib.sh"
cp -R "$ROOT/bin/khuluma-lib" "$BIN_DIR/khuluma-lib"
chmod +x "$BIN_DIR/khuluma" "$BIN_DIR/khuluma-lib.sh"

run_version() {
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:/usr/bin:/bin" \
  KHULUMA_LIB_PATH= \
  KHULUMA_CONFIG_DIR="$CONFIG_DIR" \
  KHULUMA_CONFIG_FILE="$CONFIG_DIR/config.toml" \
  "$BIN_DIR/khuluma" "$@"
}

assert_contains() {
  local name="$1"
  local value="$2"
  local expected="$3"
  if [[ "$value" != *"$expected"* ]]; then
    echo "Expected $name to contain: $expected" >&2
    echo "Actual: $value" >&2
    exit 1
  fi
  echo "PASS: $name"
}

# Derive the expected version from source so release bumps touch one line.
EXPECTED_CLI_VERSION="$(sed -n 's/^KHULUMA_CLI_VERSION="\(.*\)"$/\1/p' "$ROOT/bin/khuluma")"
[[ -n "$EXPECTED_CLI_VERSION" ]] || { echo "Could not read KHULUMA_CLI_VERSION" >&2; exit 1; }

missing_text="$(run_version version)"
assert_contains "missing_cli_version" "$missing_text" "CLI version: $EXPECTED_CLI_VERSION"
assert_contains "missing_config_schema" "$missing_text" "Config schema: v1"
assert_contains "missing_running_binary" "$missing_text" "Running binary: $BIN_REAL"
assert_contains "missing_receipt" "$missing_text" "Install receipt: missing ($CONFIG_DIR/install-receipt.env)"

# A source checkout must fall back as a complete runtime when an older local
# library directory exists but cannot provide this newly added module.
mkdir -p "$HOME_DIR/.local/bin/khuluma-lib"
source_text="$(HOME="$HOME_DIR" PATH="/usr/bin:/bin" KHULUMA_CONFIG_DIR="$CONFIG_DIR" KHULUMA_CONFIG_FILE="$CONFIG_DIR/config.toml" "$ROOT/bin/khuluma" version)"
assert_contains "source_checkout_stale_lib_fallback" "$source_text" "Running binary: $ROOT/bin/khuluma"

missing_json="$(run_version version --json)"
VERSION_JSON="$missing_json" EXPECTED_CLI_VERSION="$EXPECTED_CLI_VERSION" python3 - <<'PYEOF'
import json
import os

payload = json.loads(os.environ["VERSION_JSON"])
assert payload["command"] == "version"
assert payload["schema_version"] == 1
assert payload["cli_version"] == os.environ["EXPECTED_CLI_VERSION"]
assert payload["config_schema_version"] == 1
assert payload["running_binary"]["path"].endswith("/bin/khuluma")
assert payload["receipt"]["present"] is False
assert payload["receipt"]["installed_at"] is None
assert payload["receipt"]["source"] is None
assert payload["receipt"]["ref"] is None
assert payload["receipt"]["commit"] is None
PYEOF
echo "PASS: missing_receipt_json"

cat >"$CONFIG_DIR/install-receipt.env" <<'EOF'
installed_at=2026-09-17T10:00:00Z
install_source=bootstrap:ricardo-nth/tmux-whisper@v0.7.0
repo_git_ref=release\ candidate
repo_git_commit=0123456789abcdef
bin_path=/a/source/checkout/bin/tmux-whisper
EOF

present_text="$(run_version version)"
assert_contains "present_receipt" "$present_text" "Install receipt: present ($CONFIG_DIR/install-receipt.env)"
assert_contains "present_installed_at" "$present_text" "installed at: 2026-09-17T10:00:00Z"
assert_contains "present_source" "$present_text" "source: bootstrap:ricardo-nth/tmux-whisper@v0.7.0"
assert_contains "present_ref" "$present_text" "ref: release candidate"
assert_contains "present_commit" "$present_text" "commit: 0123456789abcdef"
assert_contains "receipt_binary_separation" "$present_text" "Receipt provenance records install metadata; the running binary is listed separately."

alias_text="$(run_version --version)"
if [[ "$alias_text" != "$present_text" ]]; then
  echo "Expected --version to match version output" >&2
  exit 1
fi
echo "PASS: version_alias"

present_json="$(run_version version --json)"
VERSION_JSON="$present_json" python3 - <<'PYEOF'
import json
import os

payload = json.loads(os.environ["VERSION_JSON"])
receipt = payload["receipt"]
assert receipt["present"] is True
assert receipt["readable"] is True
assert receipt["installed_at"] == "2026-09-17T10:00:00Z"
assert receipt["source"] == "bootstrap:ricardo-nth/tmux-whisper@v0.7.0"
assert receipt["ref"] == "release candidate"
assert receipt["commit"] == "0123456789abcdef"
PYEOF
echo "PASS: present_receipt_json"

echo "Version command tests passed."
