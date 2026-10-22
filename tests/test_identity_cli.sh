#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_ROOT"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export KHULUMA_TMPDIR="$TMP_ROOT/tmp"
export KHULUMA_DAEMON_BACKGROUND_REFRESH=0
unset KHULUMA_CONFIG_DIR KHULUMA_CONFIG_FILE DICTATE_CONFIG_DIR DICTATE_CONFIG_FILE
unset KHULUMA_LIB_PATH KHULUMA_INTERNAL_LIB_DIR DICTATE_LIB_PATH DICTATE_INTERNAL_LIB_DIR
mkdir -p "$HOME/.local/bin" "$KHULUMA_TMPDIR"
BIN="$HOME/.local/bin"
cp "$ROOT/bin/khuluma" "$ROOT/bin/tmux-whisper" "$ROOT/bin/khuluma-lib.sh" "$BIN/"
cp -R "$ROOT/bin/khuluma-lib" "$BIN/khuluma-lib"
export PATH="$BIN:/usr/bin:/bin"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

khuluma --help >"$TMP_ROOT/help.txt"
khuluma version --json >"$TMP_ROOT/version.json"
khuluma config defaults >"$TMP_ROOT/defaults.toml"
[[ ! -e "$XDG_CONFIG_HOME" && ! -e "$XDG_DATA_HOME" ]] || fail "identity_probes_wrote_profile"
python3 - "$TMP_ROOT/version.json" "$BIN/khuluma" "$XDG_CONFIG_HOME/khuluma" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["identity"]["product"] == "khuluma"
assert p["identity"]["identity_version"] == 1
assert p["identity"]["canonical_binary"] == sys.argv[2]
assert p["identity"]["config_dir"] == sys.argv[3]
assert p["identity"]["migration_required"] is False
PY
pass "identity_probes_are_canonical_and_side_effect_free"

DICTATE_CONFIG_DIR="$TMP_ROOT/legacy-profile" khuluma version --json >"$TMP_ROOT/legacy.json"
KHULUMA_CONFIG_DIR="$TMP_ROOT/canonical-profile" DICTATE_CONFIG_DIR="$TMP_ROOT/legacy-profile" \
  khuluma version --json >"$TMP_ROOT/precedence.json"
KHULUMA_CONFIG_DIR= DICTATE_CONFIG_DIR="$TMP_ROOT/legacy-profile" \
  khuluma version --json >"$TMP_ROOT/empty.json"
python3 - "$TMP_ROOT" <<'PY'
import json, pathlib, sys
r = pathlib.Path(sys.argv[1])
for file, expected in [("legacy.json", "legacy-profile"), ("precedence.json", "canonical-profile"), ("empty.json", "legacy-profile")]:
    p = json.loads((r / file).read_text())
    assert p["receipt"]["path"] == str(r / expected / "install-receipt.env"), p
    assert not (r / expected).exists()
PY
pass "identity_config_alias_precedence"

printf 'printf sourced >"%s"\n' "$TMP_ROOT/invalid-library-ran" >"$TMP_ROOT/old-library.sh"
rc=0
KHULUMA_LIB_PATH="$TMP_ROOT/old-library.sh" khuluma version --json >"$TMP_ROOT/invalid.out" 2>"$TMP_ROOT/invalid.err" || rc=$?
[[ "$rc" -ne 0 && ! -e "$TMP_ROOT/invalid-library-ran" ]] || fail "incompatible_library_was_sourced"
pass "identity_rejects_incompatible_library_before_source"

tmux-whisper version --json >"$TMP_ROOT/shim-version.json"
cmp "$TMP_ROOT/version.json" "$TMP_ROOT/shim-version.json" || fail "shim_version_not_canonical"
pass "legacy_shim_version_is_canonical"

canonical_rc=0
legacy_rc=0
khuluma doctor --json >"$TMP_ROOT/doctor.json" 2>"$TMP_ROOT/doctor.err" || canonical_rc=$?
tmux-whisper doctor --json >"$TMP_ROOT/legacy-doctor.json" 2>"$TMP_ROOT/legacy-doctor.err" || legacy_rc=$?
[[ "$canonical_rc" == "$legacy_rc" ]] || fail "shim_doctor_exit_status"
python3 - "$TMP_ROOT/doctor.json" "$TMP_ROOT/legacy-doctor.json" <<'PY'
import json, sys
new, old = (json.load(open(path)) for path in sys.argv[1:])
assert new["schema_version"] == 2
assert "schema_version" not in old
expected = dict(new)
expected.pop("schema_version")
expected["install_sanity"] = dict(new["install_sanity"])
for canonical, legacy in [
    ("cli_binary", "tmux_whisper_binary"),
    ("daemon_source", "tmux_whisperd_source"),
    ("daemon_binary", "tmux_whisperd_binary"),
    ("daemon_socket", "tmux_whisperd_socket"),
]:
    expected["install_sanity"][legacy] = expected["install_sanity"].pop(canonical)
assert old == expected, (old, expected)
PY
cmp "$TMP_ROOT/doctor.err" "$TMP_ROOT/legacy-doctor.err" || fail "shim_doctor_stderr"
pass "legacy_shim_doctor_adapter_preserves_contract"

echo "CLI identity tests passed."
