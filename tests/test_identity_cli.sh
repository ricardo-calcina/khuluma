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
unset LOWKEY_KEYCHAIN LOWKEY_SIGNING_IDENTITY
mkdir -p "$HOME/.local/bin" "$KHULUMA_TMPDIR"
BIN="$HOME/.local/bin"
cp "$ROOT/bin/khuluma" "$ROOT/bin/khuluma-lib.sh" "$BIN/"
cp -R "$ROOT/bin/khuluma-lib" "$BIN/khuluma-lib"
export PATH="$BIN:/usr/bin:/bin"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected_path: $1"; }

for path in "$ROOT/bin/tmux-whisper" "$ROOT/bin/khuluma-lib/doctor_compat.py" \
  "$BIN/tmux-whisper" "$BIN/khuluma-lib/doctor_compat.py"; do
  absent "$path"
done
pass "identity_has_no_legacy_command_or_adapter"

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

KHULUMA_CONFIG_DIR="$TMP_ROOT/canonical-profile" KHULUMA_CONFIG_FILE="$TMP_ROOT/canonical-profile/settings.toml" \
  khuluma version --json >"$TMP_ROOT/custom.json"
KHULUMA_CONFIG_DIR="$TMP_ROOT/canonical-profile" KHULUMA_CONFIG_FILE="$TMP_ROOT/canonical-profile/settings.toml" \
  khuluma config path --json >"$TMP_ROOT/custom-path.json"
python3 - "$TMP_ROOT" <<'PY'
import json, pathlib, sys
r = pathlib.Path(sys.argv[1])
p = json.loads((r / "custom.json").read_text())
assert p["identity"]["config_dir"] == str(r / "canonical-profile")
assert p["receipt"]["path"] == str(r / "canonical-profile/install-receipt.env")
assert json.loads((r / "custom-path.json").read_text())["config_path"] == str(r / "canonical-profile/settings.toml")
assert not (r / "canonical-profile").exists()
PY
pass "identity_canonical_custom_config_paths_are_pure"

printf 'printf sourced >"%s"\n' "$TMP_ROOT/invalid-library-ran" >"$TMP_ROOT/old-library.sh"
# Pure probes ignore obsolete inputs, including empty names and an executable
# legacy library payload. None may become a profile route or source import.
for probe in help version defaults; do
  case "$probe" in
    help) arguments=(--help); expected=help.txt ;;
    version) arguments=(version --json); expected=version.json ;;
    defaults) arguments=(config defaults); expected=defaults.toml ;;
  esac
  DICTATE_CONFIG_DIR="$TMP_ROOT/legacy-profile" DICTATE_LIB_PATH="$TMP_ROOT/old-library.sh" \
    DICTATE_UNKNOWN_INPUT= LOWKEY_KEYCHAIN= LOWKEY_SIGNING_IDENTITY= \
    khuluma "${arguments[@]}" >"$TMP_ROOT/pure-$probe.out"
  cmp "$TMP_ROOT/$expected" "$TMP_ROOT/pure-$probe.out" || fail "legacy_input_changed_pure_$probe"
done
absent "$TMP_ROOT/legacy-profile"
absent "$TMP_ROOT/invalid-library-ran"
absent "$XDG_CONFIG_HOME"
absent "$XDG_DATA_HOME"
pass "identity_pure_probes_ignore_legacy_inputs_without_writes"

# Ordinary paths reject presence, not truthiness. A canonical route alongside
# an obsolete route must still refuse before config repair can create files.
for variable in DICTATE_CONFIG_DIR DICTATE_UNKNOWN_INPUT LOWKEY_KEYCHAIN LOWKEY_SIGNING_IDENTITY; do
  for value in '' legacy-secret-value; do
    rc=0
    KHULUMA_CONFIG_DIR="$TMP_ROOT/guard-profile" \
      env "$variable=$value" khuluma config repair >"$TMP_ROOT/guard.out" 2>"$TMP_ROOT/guard.err" || rc=$?
    [[ "$rc" == 2 ]] || fail "legacy_input_not_refused: $variable"
    grep -Fq "$variable" "$TMP_ROOT/guard.err" || fail "legacy_input_name_missing: $variable"
    if grep -Fq 'legacy-secret-value' "$TMP_ROOT/guard.err" "$TMP_ROOT/guard.out"; then
      fail "legacy_input_value_disclosed: $variable"
    fi
    absent "$TMP_ROOT/guard-profile"
    absent "$XDG_CONFIG_HOME"
    absent "$XDG_DATA_HOME"
  done
done
pass "identity_rejects_present_legacy_inputs_before_writes"

rc=0
KHULUMA_LIB_PATH="$TMP_ROOT/old-library.sh" khuluma version --json >"$TMP_ROOT/invalid.out" 2>"$TMP_ROOT/invalid.err" || rc=$?
[[ "$rc" -ne 0 && ! -e "$TMP_ROOT/invalid-library-ran" ]] || fail "incompatible_library_was_sourced"
pass "identity_rejects_incompatible_library_before_source"

canonical_rc=0
khuluma doctor --json >"$TMP_ROOT/doctor.json" 2>"$TMP_ROOT/doctor.err" || canonical_rc=$?
[[ "$canonical_rc" == 0 ]] || fail "canonical_doctor_failed"
python3 - "$TMP_ROOT/doctor.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["schema_version"] == 2
assert {"cli_binary", "daemon_source", "daemon_binary", "daemon_socket"} <= p["install_sanity"].keys()
assert not any(key.startswith("tmux_whisper") for key in p["install_sanity"])
PY
absent "$XDG_CONFIG_HOME"
absent "$XDG_DATA_HOME"
pass "identity_doctor_is_canonical_schema_two_and_read_only"

echo "CLI identity tests passed."
