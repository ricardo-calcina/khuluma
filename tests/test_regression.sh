#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
# Never read or write the real user's ~/.local/share (daemon build, models).
export XDG_DATA_HOME="$TMP_ROOT/xdg-data"
export DICTATE_DAEMON_BACKGROUND_REFRESH=0
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_BIN="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_BIN"

cat >"$STUB_BIN/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [[ "$joined" == *"get name of first process whose frontmost is true"* ]]; then
  printf '%s\n' "${DICTATE_TEST_FRONT_APP:-}"
fi
exit 0
EOF
chmod +x "$STUB_BIN/osascript"

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: $name" >&2
    echo "Expected to find: $needle" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "FAIL: $name" >&2
    echo "Expected not to find: $needle" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_equals() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name" >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
  fi
  echo "PASS: $name"
}

json_get() {
  local json_input="$1"
  local path="$2"
  JSON_INPUT="$json_input" JSON_PATH="$path" python3 - <<'PYEOF'
import json
import os

path = os.environ["JSON_PATH"]
data = json.loads(os.environ["JSON_INPUT"])
value = data
for part in path.split("."):
    if not part:
        continue
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True))
elif value is True:
    print("true")
elif value is False:
    print("false")
elif value is None:
    print("null")
else:
    print(value)
PYEOF
}

assert_json_equals() {
  local name="$1"
  local json_input="$2"
  local path="$3"
  local expected="$4"
  local actual
  actual="$(json_get "$json_input" "$path")"
  assert_equals "$name" "$actual" "$expected"
}

assert_file_contains() {
  local name="$1"
  local file="$2"
  local needle="$3"
  if ! rg -q --fixed-strings "$needle" "$file"; then
    echo "FAIL: $name" >&2
    echo "Missing pattern in $file: $needle" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_file_exists() {
  local name="$1"
  local file="$2"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: $name" >&2
    echo "Expected file to exist: $file" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_file_not_exists() {
  local name="$1"
  local file="$2"
  if [[ -e "$file" ]]; then
    echo "FAIL: $name" >&2
    echo "Expected file to be absent: $file" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_not_symlink() {
  local name="$1"
  local file="$2"
  if [[ -L "$file" ]]; then
    echo "FAIL: $name" >&2
    echo "Expected regular file, found symlink: $file" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_file_executable() {
  local name="$1"
  local file="$2"
  if [[ ! -x "$file" ]]; then
    echo "FAIL: $name" >&2
    echo "Expected file to be executable: $file" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_file_not_executable() {
  local name="$1"
  local file="$2"
  if [[ -x "$file" ]]; then
    echo "FAIL: $name" >&2
    echo "Expected file not to be executable: $file" >&2
    exit 1
  fi
  echo "PASS: $name"
}

assert_glob_exists() {
  local name="$1"
  local pattern="$2"
  if ! compgen -G "$pattern" >/dev/null; then
    echo "FAIL: $name" >&2
    echo "Expected match for: $pattern" >&2
    exit 1
  fi
  echo "PASS: $name"
}

install_test_runtime() {
  local dest_bin="$1"
  mkdir -p "$dest_bin"
  cp "$ROOT/bin/tmux-whisper" "$dest_bin/tmux-whisper"
  cp "$ROOT/bin/dictate-lib.sh" "$dest_bin/dictate-lib.sh"
  rm -rf "$dest_bin/tmux-whisper-lib"
  mkdir -p "$dest_bin/tmux-whisper-lib"
  cp -R "$ROOT/bin/tmux-whisper-lib/." "$dest_bin/tmux-whisper-lib/"
  chmod +x "$dest_bin/tmux-whisper" "$dest_bin/dictate-lib.sh"
}

# --- Regression 1: install-channel detection should work for custom paths. ---
CUSTOM_HOME="$TMP_ROOT/home-custom"
CUSTOM_BIN="$TMP_ROOT/custom-bin"
mkdir -p "$CUSTOM_HOME" "$CUSTOM_BIN"
install_test_runtime "$CUSTOM_BIN"
CUSTOM_DICTATE_CONFIG_DIR="$CUSTOM_HOME/.config/dictate"
CUSTOM_DICTATE_CONFIG_FILE="$CUSTOM_DICTATE_CONFIG_DIR/config.toml"

custom_doctor="$(HOME="$CUSTOM_HOME" PATH="$CUSTOM_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CUSTOM_DICTATE_CONFIG_DIR" DICTATE_CONFIG_FILE="$CUSTOM_DICTATE_CONFIG_FILE" "$CUSTOM_BIN/tmux-whisper" doctor)"
assert_contains "doctor_install_sanity_section" "$custom_doctor" "Install sanity:"
assert_contains "doctor_channel_present" "$custom_doctor" "install channel: "
assert_contains "doctor_schema_ok" "$custom_doctor" "config schema: v1 (expected v1, status=ok)"
assert_contains "doctor_backend_declared" "$custom_doctor" "backend: swift_parakeet"
assert_not_contains "doctor_legacy_section_removed" "$custom_doctor" "Legacy compatibility:"
custom_doctor_json="$(HOME="$CUSTOM_HOME" PATH="$CUSTOM_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CUSTOM_DICTATE_CONFIG_DIR" DICTATE_CONFIG_FILE="$CUSTOM_DICTATE_CONFIG_FILE" "$CUSTOM_BIN/tmux-whisper" doctor --json)"
assert_json_equals "doctor_json_command" "$custom_doctor_json" "command" "doctor"
assert_json_equals "doctor_json_install_channel" "$custom_doctor_json" "install_sanity.install_channel" "custom"
assert_json_equals "doctor_json_backend" "$custom_doctor_json" "install_sanity.backend" "swift_parakeet"

# --- Regression 2: install-channel detection should work for local user installs. ---
LOCAL_HOME="$TMP_ROOT/home-local"
LOCAL_BIN="$LOCAL_HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
install_test_runtime "$LOCAL_BIN"
LOCAL_DICTATE_CONFIG_DIR="$LOCAL_HOME/.config/dictate"
LOCAL_DICTATE_CONFIG_FILE="$LOCAL_DICTATE_CONFIG_DIR/config.toml"

local_doctor_json="$(HOME="$LOCAL_HOME" PATH="$LOCAL_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOCAL_DICTATE_CONFIG_DIR" DICTATE_CONFIG_FILE="$LOCAL_DICTATE_CONFIG_FILE" tmux-whisper doctor --json)"
assert_json_equals "doctor_local_user_channel" "$local_doctor_json" "install_sanity.install_channel" "local-user"

# --- Regression 3: backend diagnostics should surface Swift backend state. ---
BACKEND_HOME="$TMP_ROOT/home-backend"
BACKEND_BIN="$BACKEND_HOME/.local/bin"
BACKEND_CFG="$BACKEND_HOME/.config/dictate"
BACKEND_NATIVE="$BACKEND_HOME/.local/share/tmux-whisper/native/tmux-whisperd"
BACKEND_MODEL="$BACKEND_HOME/models/parakeet-tdt-0.6b-v3-coreml"
BACKEND_STATE_FILE="$BACKEND_HOME/backend.state"
BACKEND_INLINE_STATE_FILE="$BACKEND_HOME/backend-inline.state"
BACKEND_PROCESSING_DIR="$BACKEND_HOME/dictate-processing"
BACKEND_TMUX_JOBS_DIR="$BACKEND_HOME/dictate-tmux-jobs"
mkdir -p "$BACKEND_BIN" "$BACKEND_CFG" "$BACKEND_NATIVE" "$BACKEND_MODEL" "$BACKEND_PROCESSING_DIR" "$BACKEND_TMUX_JOBS_DIR"
install_test_runtime "$BACKEND_BIN"
cp -R "$ROOT/tmux-whisperd/." "$BACKEND_NATIVE/"
cat >"$BACKEND_CFG/config.toml" <<EOF
[meta]
config_version = 1

[audio]
source = "auto"

[swift_parakeet]
model_path = "$BACKEND_MODEL"
socket_path = "$BACKEND_CFG/.cache/tmux-whisperd.sock"
EOF

backend_doctor="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" tmux-whisper doctor)"
assert_contains "doctor_backend_requested" "$backend_doctor" "backend: swift_parakeet"
assert_contains "doctor_backend_model_version" "$backend_doctor" "parakeet model version: v3"

backend_status="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" tmux-whisper status)"
assert_contains "status_backend_summary_state" "$backend_status" "state: ready"
assert_contains "status_backend_summary_readiness" "$backend_status" "backend_readiness: cold"
assert_contains "status_backend_summary_next_action" "$backend_status" "run tmux-whisper warmup"
assert_contains "status_backend_swift_model" "$backend_status" "swift_parakeet.model: $BACKEND_MODEL (v3)"
assert_contains "status_backend_swift_socket" "$backend_status" "swift_parakeet.socket: $BACKEND_CFG/.cache/tmux-whisperd.sock"
assert_contains "status_backend_inline_process_sound" "$backend_status" "inline.process_sound: ON"
assert_not_contains "status_backend_hides_inline_model" "$backend_status" "model.inline:"
assert_not_contains "status_backend_hides_whisper_knobs" "$backend_status" "whisper.threads/beam/best_of:"
backend_status_json="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" tmux-whisper status --json)"
assert_json_equals "status_json_command" "$backend_status_json" "command" "status"
assert_json_equals "status_json_summary_state" "$backend_status_json" "summary.state" "ready"
assert_json_equals "status_json_summary_backend_readiness" "$backend_status_json" "summary.backend_readiness" "cold"
assert_json_equals "status_json_backend" "$backend_status_json" "effective_settings.backend" "swift_parakeet"
assert_json_equals "status_json_model_version" "$backend_status_json" "effective_settings.swift_parakeet.model.version" "v3"
assert_json_equals "status_json_inline_process_sound" "$backend_status_json" "effective_settings.inline.process_sound" "true"
backend_status_compact="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" tmux-whisper status --preset compact)"
assert_contains "status_compact_header" "$backend_status_compact" "Tmux Whisper status (compact)"
assert_contains "status_compact_summary" "$backend_status_compact" "Summary: state=ready backend=cold flow=none config=v1/ok"
assert_not_contains "status_compact_no_modes" "$backend_status_compact" "Modes:"
assert_not_contains "status_no_mode_line" "$backend_status" "mode.inline"
assert_contains "status_compact_runtime" "$backend_status_compact" "Runtime: proc=0/0 stale=0"
assert_contains "status_compact_next" "$backend_status_compact" "Next: Use your normal hotkey, or run tmux-whisper warmup to pre-load the daemon."
assert_contains "status_compact_more" "$backend_status_compact" "More: tmux-whisper last | tmux-whisper bench | tmux-whisper history sessions 5"

# --- Regression 4: doctor should fail on schema mismatch. ---
MISMATCH_HOME="$TMP_ROOT/home-mismatch"
MISMATCH_BIN="$MISMATCH_HOME/.local/bin"
MISMATCH_CFG="$MISMATCH_HOME/.config/dictate"
mkdir -p "$MISMATCH_BIN" "$MISMATCH_CFG"
install_test_runtime "$MISMATCH_BIN"
cat >"$MISMATCH_CFG/config.toml" <<'EOF'
[meta]
config_version = 0

[audio]
source = "auto"

[inline]
autosend = false
EOF
mismatch_doctor="$(HOME="$MISMATCH_HOME" PATH="$MISMATCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MISMATCH_CFG" DICTATE_CONFIG_FILE="$MISMATCH_CFG/config.toml" tmux-whisper doctor)"
assert_contains "doctor_schema_mismatch_status" "$mismatch_doctor" "config schema: v0 (expected v1, status=mismatch)"
assert_contains "doctor_schema_mismatch_hint" "$mismatch_doctor" "this build requires config schema v1"
assert_contains "doctor_schema_suggested_fixes" "$mismatch_doctor" "Suggested fixes:"
assert_contains "doctor_schema_suggested_preview" "$mismatch_doctor" "Preview config repair: tmux-whisper config repair --dry-run"
assert_contains "doctor_schema_suggested_repair" "$mismatch_doctor" "Repair config in place: tmux-whisper config repair"

mismatch_repair_dry_run="$(HOME="$MISMATCH_HOME" PATH="$MISMATCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MISMATCH_CFG" DICTATE_CONFIG_FILE="$MISMATCH_CFG/config.toml" tmux-whisper config repair --dry-run)"
assert_contains "config_repair_dry_run_summary" "$mismatch_repair_dry_run" "Config repair dry-run: v0/mismatch -> v1"
assert_contains "config_repair_dry_run_action" "$mismatch_repair_dry_run" "Action: merge missing defaults and normalize schema version"
if rg -q 'paste_target' "$MISMATCH_CFG/config.toml"; then
  echo "FAIL: config_repair_dry_run_no_mutation" >&2
  exit 1
fi
echo "PASS: config_repair_dry_run_no_mutation"

mismatch_repair_out="$(HOME="$MISMATCH_HOME" PATH="$MISMATCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MISMATCH_CFG" DICTATE_CONFIG_FILE="$MISMATCH_CFG/config.toml" tmux-whisper config repair)"
assert_contains "config_repair_summary" "$mismatch_repair_out" "Config repair: v0/mismatch -> v1"
assert_contains "config_repair_backup_line" "$mismatch_repair_out" "Backup: "
mismatch_repair_backup="$(printf "%s\n" "$mismatch_repair_out" | sed -n 's/^Backup: //p' | head -n 1)"
assert_file_exists "config_repair_backup_exists" "$mismatch_repair_backup"
assert_file_contains "config_repair_updated_version" "$MISMATCH_CFG/config.toml" "config_version = 1"
assert_file_contains "config_repair_added_default" "$MISMATCH_CFG/config.toml" "paste_target = \"current\""
assert_file_contains "config_repair_preserved_inline_autosend" "$MISMATCH_CFG/config.toml" "autosend = false"

INVALIDCFG_HOME="$TMP_ROOT/home-invalid-config"
INVALIDCFG_BIN="$INVALIDCFG_HOME/.local/bin"
INVALIDCFG_CFG="$INVALIDCFG_HOME/.config/dictate"
INVALIDCFG_STATE_FILE="$INVALIDCFG_HOME/invalidcfg.state"
INVALIDCFG_INLINE_STATE_FILE="$INVALIDCFG_HOME/invalidcfg-inline.state"
INVALIDCFG_PROCESSING_DIR="$INVALIDCFG_HOME/dictate-processing"
INVALIDCFG_TMUX_JOBS_DIR="$INVALIDCFG_HOME/dictate-tmux-jobs"
mkdir -p "$INVALIDCFG_BIN" "$INVALIDCFG_CFG" "$INVALIDCFG_PROCESSING_DIR" "$INVALIDCFG_TMUX_JOBS_DIR"
install_test_runtime "$INVALIDCFG_BIN"
cat >"$INVALIDCFG_CFG/config.toml" <<'EOF'
[meta]
config_version = 1
[audio
EOF
invalidcfg_doctor="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" tmux-whisper doctor 2>&1)"
assert_contains "doctor_invalidcfg_status" "$invalidcfg_doctor" "config schema: invalid (expected v1, status=invalid)"
assert_contains "doctor_invalidcfg_hint" "$invalidcfg_doctor" "config TOML is invalid"
assert_contains "doctor_invalidcfg_parse_error" "$invalidcfg_doctor" "parse error:"
assert_not_contains "doctor_invalidcfg_no_traceback" "$invalidcfg_doctor" "Traceback (most recent call last)"

invalidcfg_status="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" tmux-whisper status 2>&1)"
assert_contains "status_invalidcfg_headline" "$invalidcfg_status" "headline: Config file is invalid TOML."
assert_contains "status_invalidcfg_schema" "$invalidcfg_status" "config.schema: invalid (status=invalid)"
assert_contains "status_invalidcfg_parse_error" "$invalidcfg_status" "config.parse_error:"
assert_not_contains "status_invalidcfg_no_traceback" "$invalidcfg_status" "Traceback (most recent call last)"

set +e
invalidcfg_keep_logs_out="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" tmux-whisper keep-logs on 2>&1)"
invalidcfg_keep_logs_rc=$?
set -e
assert_equals "config_set_invalid_exit" "$invalidcfg_keep_logs_rc" "2"
assert_contains "config_set_invalid_hint" "$invalidcfg_keep_logs_out" "config TOML is invalid"
assert_contains "config_set_invalid_preview" "$invalidcfg_keep_logs_out" "tmux-whisper config repair --dry-run"
assert_contains "config_set_invalid_parse_error" "$invalidcfg_keep_logs_out" "Parse error: "
assert_not_contains "config_set_invalid_no_traceback" "$invalidcfg_keep_logs_out" "Traceback (most recent call last)"
assert_file_contains "config_set_invalid_no_mutation" "$INVALIDCFG_CFG/config.toml" "[audio"

invalidcfg_repair_dry_run="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" tmux-whisper config repair --dry-run)"
assert_contains "config_repair_invalid_dry_run_summary" "$invalidcfg_repair_dry_run" "Config repair dry-run: invalid/invalid -> v1"
assert_contains "config_repair_invalid_dry_run_action" "$invalidcfg_repair_dry_run" "Action: replace invalid TOML with canonical defaults"
assert_contains "config_repair_invalid_dry_run_parse_error" "$invalidcfg_repair_dry_run" "Parse error: "
assert_not_contains "config_repair_invalid_dry_run_no_backup" "$invalidcfg_repair_dry_run" "Backup: "
assert_file_contains "config_repair_invalid_dry_run_no_mutation" "$INVALIDCFG_CFG/config.toml" "[audio"

invalidcfg_repair_out="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" tmux-whisper config repair)"
assert_contains "config_repair_invalid_summary" "$invalidcfg_repair_out" "Config repair: invalid/invalid -> v1"
assert_contains "config_repair_invalid_action" "$invalidcfg_repair_out" "Action: replace invalid TOML with canonical defaults"
assert_contains "config_repair_invalid_parse_error" "$invalidcfg_repair_out" "Parse error: "
assert_contains "config_repair_invalid_backup_line" "$invalidcfg_repair_out" "Backup: "
invalidcfg_repair_backup="$(printf "%s\n" "$invalidcfg_repair_out" | sed -n 's/^Backup: //p' | head -n 1)"
assert_file_exists "config_repair_invalid_backup_exists" "$invalidcfg_repair_backup"
assert_file_contains "config_repair_invalid_written_version" "$INVALIDCFG_CFG/config.toml" "config_version = 1"
assert_file_contains "config_repair_invalid_written_inline" "$INVALIDCFG_CFG/config.toml" "paste_target = \"current\""

# --- Regression 5: modes are gone. Doctor reports the vocab and flags a
# leftover modes/ dir; `mode` points at migrate-modes, which folds the old
# mode vocab in (a dry run first changes nothing). ---
MODECHECK_HOME="$TMP_ROOT/home-modecheck"
MODECHECK_BIN="$MODECHECK_HOME/.local/bin"
MODECHECK_CFG="$MODECHECK_HOME/.config/dictate"
mkdir -p "$MODECHECK_BIN" "$MODECHECK_CFG/modes/code"
install_test_runtime "$MODECHECK_BIN"
cat >"$MODECHECK_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"
EOF
printf '%s\n' '# comment' 'open ai -> OpenAI' 'get hub::GitHub' 'not a rule' >"$MODECHECK_CFG/vocab"
printf '%s\n' 'ghost tea::Ghostty' >"$MODECHECK_CFG/modes/code/vocab"
printf '%s\n' "code" >"$MODECHECK_CFG/current-mode"
modecheck_env=(HOME="$MODECHECK_HOME" PATH="$MODECHECK_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODECHECK_CFG" DICTATE_CONFIG_FILE="$MODECHECK_CFG/config.toml")
modecheck_doctor="$(env "${modecheck_env[@]}" tmux-whisper doctor || true)"
assert_contains "doctor_vocab_section" "$modecheck_doctor" "Vocab:"
assert_contains "doctor_vocab_rules" "$modecheck_doctor" "vocab: $MODECHECK_CFG/vocab (2 rules)"
assert_contains "doctor_legacy_modes" "$modecheck_doctor" "modes/: found but no longer read"
assert_contains "doctor_legacy_modes_fix" "$modecheck_doctor" "tmux-whisper migrate-modes"
assert_not_contains "doctor_no_mode_config" "$modecheck_doctor" "Mode/config:"
modecheck_json="$(env "${modecheck_env[@]}" tmux-whisper doctor --json || true)"
assert_json_equals "doctor_json_vocab_rules" "$modecheck_json" "vocab.rules" "2"
assert_json_equals "doctor_json_legacy_modes" "$modecheck_json" "vocab.legacy_modes_present" "true"
assert_not_contains "doctor_json_no_mode_config" "$modecheck_json" "mode_config"
set +e
modecheck_mode="$(env "${modecheck_env[@]}" tmux-whisper mode code 2>&1)"
modecheck_mode_rc=$?
set -e
assert_equals "mode_command_fails" "$modecheck_mode_rc" "2"
assert_contains "mode_command_points_at_migrate" "$modecheck_mode" "modes were removed in v0.11"
modecheck_dry="$(env "${modecheck_env[@]}" tmux-whisper migrate-modes --dry-run)"
assert_contains "migrate_dry_run_reports" "$modecheck_dry" "Would add 1 rule(s) from modes/code/vocab"
assert_file_exists "migrate_dry_run_keeps_modes" "$MODECHECK_CFG/modes/code/vocab"
assert_file_exists "migrate_dry_run_keeps_current_mode" "$MODECHECK_CFG/current-mode"
modecheck_migrate="$(env "${modecheck_env[@]}" tmux-whisper migrate-modes)"
assert_contains "migrate_reports" "$modecheck_migrate" "Added 1 rule(s) from modes/code/vocab (0 already in vocab)"
assert_file_contains "migrate_appends_rule" "$MODECHECK_CFG/vocab" "ghost tea::Ghostty"
assert_file_contains "migrate_keeps_comment" "$MODECHECK_CFG/vocab" "# comment"
assert_file_not_exists "migrate_moves_current_mode" "$MODECHECK_CFG/current-mode"
assert_glob_exists "migrate_archives_modes" "$MODECHECK_CFG/modes-archive/*-modes-removed/modes/code/vocab"
modecheck_again="$(env "${modecheck_env[@]}" tmux-whisper migrate-modes)"
assert_contains "migrate_second_run_noop" "$modecheck_again" "Nothing to migrate"
modecheck_doctor_after="$(env "${modecheck_env[@]}" tmux-whisper doctor || true)"
assert_contains "doctor_vocab_rules_after" "$modecheck_doctor_after" "vocab: $MODECHECK_CFG/vocab (3 rules)"
assert_not_contains "doctor_no_legacy_after" "$modecheck_doctor_after" "modes/: found"

# --- Regression 8: a Homebrew install finds the Finder Quick Action handler in
# its pkgshare and ignores a stale local-install receipt. ---
BREW_FINDER_HOME="$TMP_ROOT/home-brew-finder"
BREW_FINDER_PREFIX="$BREW_FINDER_HOME/Cellar/tmux-whisper/0.11.0"
BREW_FINDER_BIN="$BREW_FINDER_HOME/bin"
BREW_FINDER_CFG="$BREW_FINDER_HOME/.config/dictate"
install_test_runtime "$BREW_FINDER_PREFIX/libexec"
mkdir -p "$BREW_FINDER_PREFIX/share/tmux-whisper/integrations" "$BREW_FINDER_BIN" "$BREW_FINDER_CFG"
cp -R "$ROOT/integrations/finder" "$BREW_FINDER_PREFIX/share/tmux-whisper/integrations/finder"
printf '#!/bin/bash\nexec "%s/libexec/tmux-whisper" "$@"\n' "$BREW_FINDER_PREFIX" >"$BREW_FINDER_BIN/tmux-whisper"
chmod +x "$BREW_FINDER_BIN/tmux-whisper"
printf '[meta]\nconfig_version = 1\n' >"$BREW_FINDER_CFG/config.toml"
cat >"$BREW_FINDER_CFG/install-receipt.env" <<EOF
install_source='local'
repo_root='$ROOT'
bin_path='$BREW_FINDER_HOME/.local/bin/tmux-whisper'
EOF
brew_finder_share="$(cd "$BREW_FINDER_PREFIX/share/tmux-whisper" && pwd)"
brew_finder_out="$(HOME="$BREW_FINDER_HOME" PATH="$BREW_FINDER_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= \
  DICTATE_CONFIG_DIR="$BREW_FINDER_CFG" DICTATE_CONFIG_FILE="$BREW_FINDER_CFG/config.toml" \
  DICTATE_SERVICES_DIR="$BREW_FINDER_HOME/Services" tmux-whisper finder install)"
assert_contains "finder_brew_handler_from_pkgshare" "$brew_finder_out" "handler: $brew_finder_share/integrations/finder/tmux-whisper-transcribe.sh"
assert_not_contains "finder_brew_ignores_stale_receipt_root" "$brew_finder_out" "handler: $ROOT/"

# --- Regression 12: history readers summarize entries and ignore the retired
# postprocess fields (the older fixture keeps them, as old history files do). ---
HISTOBS_HOME="$TMP_ROOT/home-histobs"
HISTOBS_BIN="$HISTOBS_HOME/.local/bin"
HISTOBS_CFG="$HISTOBS_HOME/.config/dictate"
HISTOBS_HISTORY="$HISTOBS_CFG/history"
mkdir -p "$HISTOBS_BIN" "$HISTOBS_HISTORY"
install_test_runtime "$HISTOBS_BIN"
cat >"$HISTOBS_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"
EOF
cat >"$HISTOBS_HISTORY/2026-02-22T17-00-00.json" <<'EOF'
{
  "timestamp": "2026-02-22T17:00:00Z",
  "mode": "code",
  "app": "tmux",
  "raw": "one two three four five six seven eight nine ten",
  "processed": "one two three four five six seven eight nine ten",
  "metrics": {"record_ms": 8000, "transcribe_ms": 120, "clean_ms": 15, "postprocess_ms": 240, "paste_ms": 35, "total_ms": 8410},
  "postprocess_budget": {
    "numeric_sizing": "auto_dynamic",
    "profile": "short",
    "threshold_words": 20,
    "word_count": 10,
    "max_tokens": 3888,
    "chunk_words": 850,
    "chunk_count": 1,
    "llm": "gpt-oss-120b"
  }
}
EOF
cat >"$HISTOBS_HISTORY/2026-02-22T17-05-00.json" <<'EOF'
{
  "timestamp": "2026-02-22T17:05:00Z",
  "mode": "code",
  "app": "Ghostty",
  "raw": "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty one two three four five six seven eight nine ten",
  "processed": "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty one two three four five six seven eight nine ten",
  "metrics": {"record_ms": 18000, "transcribe_ms": 220, "clean_ms": 18, "paste_ms": 45, "total_ms": 18940},
  "audio": {
    "capture_wav_ms": 18120,
    "capture_wav_bytes": 580000,
    "capture_gap_to_record_ms": 120,
    "capture_gap_to_record_plus_grace_ms": 1120,
    "archive_wav_ms": 18040,
    "archive_wav_bytes": 577000,
    "wav_retention_days": 2,
    "debug_archive_prefix": "2026-02-22T17-05-00-inline",
    "retention_note": "debug wav retained"
  }
}
EOF
histobs_stats="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" DICTATE_HISTORY_STATS_NOW=2026-02-22T18:00:00Z tmux-whisper history stats)"
assert_not_contains "history_stats_no_postprocess" "$histobs_stats" "postprocess"
assert_not_contains "history_stats_no_budget" "$histobs_stats" "budget"
assert_contains "history_stats_recent_24h" "$histobs_stats" "last_24h: entries=2 raw_words=40 processed_words=40"
assert_contains "history_stats_recent_7d" "$histobs_stats" "last_7d: entries=2 raw_words=40 processed_words=40"
assert_contains "history_stats_typing_equivalent" "$histobs_stats" "typing_equivalent.total: 1m 00s @ 40 wpm"
assert_contains "history_stats_typing_delta" "$histobs_stats" "typing_delta.total: +32.6s vs end-to-end"
assert_contains "history_stats_dictation_overall" "$histobs_stats" "dictation_wpm.overall: 92"
assert_not_contains "history_stats_no_mode_breakdown" "$histobs_stats" "Mode breakdown"
assert_contains "history_stats_app_breakdown" "$histobs_stats" "Ghostty: entries=1 processed_words=30 raw_words=30"
histobs_sessions="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history sessions 2)"
assert_contains "history_sessions_header" "$histobs_sessions" "Recent dictation sessions (newest first):"
assert_contains "history_sessions_latest" "$histobs_sessions" "app=Ghostty words=30 record=18.0s"
assert_contains "history_sessions_audio" "$histobs_sessions" "audio: capture_wav=18.1s archive_wav=18.0s capture_bytes=580000 archive_bytes=577000"
assert_contains "history_sessions_debug" "$histobs_sessions" "debug: debug_archive_prefix=2026-02-22T17-05-00-inline; retention_note=debug wav retained"
assert_contains "history_sessions_next" "$histobs_sessions" "  tmux-whisper bench 10"
histobs_sessions_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history sessions 2 --json)"
assert_not_contains "history_sessions_json_no_postprocess" "$histobs_sessions_json" "postprocess"
assert_json_equals "history_sessions_json_command" "$histobs_sessions_json" "command" "history"
assert_json_equals "history_sessions_json_subcommand" "$histobs_sessions_json" "subcommand" "sessions"
assert_json_equals "history_sessions_json_first_app" "$histobs_sessions_json" "sessions.0.app" "Ghostty"
assert_json_equals "history_sessions_json_first_debug" "$histobs_sessions_json" "sessions.0.audio.debug_archive_prefix" "2026-02-22T17-05-00-inline"
assert_json_equals "history_sessions_json_first_note" "$histobs_sessions_json" "sessions.0.debug_notes.0" "debug_archive_prefix=2026-02-22T17-05-00-inline"
assert_json_equals "history_sessions_json_next" "$histobs_sessions_json" "next_commands.1" "tmux-whisper bench 10"
histobs_show_latest="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history 1)"
assert_contains "history_show_metrics_section" "$histobs_show_latest" "--- Metrics ---"
histobs_show_latest_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history --json 1)"
assert_not_contains "history_show_no_metrics_postprocess" "$histobs_show_latest" "postprocess"
assert_json_equals "history_show_json_index" "$histobs_show_latest_json" "index" "1"
assert_not_contains "history_show_json_no_mode" "$histobs_show_latest_json" "\"mode\""
histobs_list_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history list 2 --json)"
assert_json_equals "history_list_json_first_index" "$histobs_list_json" "0.index" "1"
assert_json_equals "history_list_json_first_filename" "$histobs_list_json" "0.filename" "2026-02-22T17-05-00.json"
assert_not_contains "history_list_json_no_mode" "$histobs_list_json" "\"mode\""
assert_json_equals "history_list_json_first_app" "$histobs_list_json" "0.app" "Ghostty"
assert_json_equals "history_list_json_first_processed_words" "$histobs_list_json" "0.processed_words" "30"
assert_json_equals "history_list_json_second_filename" "$histobs_list_json" "1.filename" "2026-02-22T17-00-00.json"
assert_contains "history_list_json_preview" "$histobs_list_json" "\"preview\": \"one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen"
# The older fixture still has the retired fields on disk; no reader shows them.
histobs_show_legacy_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history --json 2)"
assert_json_equals "history_show_legacy_json_mode" "$histobs_show_legacy_json" "entry.app" "tmux"
assert_not_contains "history_show_legacy_json_no_postprocess" "$histobs_show_legacy_json" "postprocess"
assert_not_contains "history_list_json_no_postprocess" "$histobs_list_json" "postprocess"
histobs_search_app="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history search Ghostty)"
assert_contains "history_search_header" "$histobs_search_app" "History search: \"Ghostty\""
assert_contains "history_search_app_match" "$histobs_search_app" "(Ghostty) [app]"
histobs_search_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history search tmux 5 --json)"
assert_not_contains "history_search_json_no_postprocess" "$histobs_search_json" "postprocess"
assert_json_equals "history_search_json_index" "$histobs_search_json" "0.index" "2"
assert_json_equals "history_search_json_filename" "$histobs_search_json" "0.filename" "2026-02-22T17-00-00.json"
assert_json_equals "history_search_json_app" "$histobs_search_json" "0.app" "tmux"
assert_json_equals "history_search_json_match_field" "$histobs_search_json" "0.match_fields.0" "app"
histobs_search_none="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history search nope)"
assert_contains "history_search_none" "$histobs_search_none" "No history entries matched: nope"
histobs_export="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history export 2)"
assert_contains "history_export_entry_one" "$histobs_export" "=== Entry 1 ==="
assert_contains "history_export_entry_one_file" "$histobs_export" "File: 2026-02-22T17-05-00.json"
assert_contains "history_export_entry_two" "$histobs_export" "=== Entry 2 ==="
assert_contains "history_export_entry_two_file" "$histobs_export" "File: 2026-02-22T17-00-00.json"
assert_contains "history_export_processed_block" "$histobs_export" "--- Processed ---"
histobs_export_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history export all --json)"
assert_not_contains "history_export_json_no_postprocess" "$histobs_export_json" "postprocess"
assert_json_equals "history_export_json_first_index" "$histobs_export_json" "0.index" "1"
assert_json_equals "history_export_json_first_filename" "$histobs_export_json" "0.filename" "2026-02-22T17-05-00.json"
assert_json_equals "history_export_json_first_app" "$histobs_export_json" "0.app" "Ghostty"
assert_json_equals "history_export_json_first_processed_words" "$histobs_export_json" "0.processed_words" "30"
assert_json_equals "history_export_json_second_filename" "$histobs_export_json" "1.filename" "2026-02-22T17-00-00.json"
assert_not_contains "history_export_json_no_mode" "$histobs_export_json" "\"mode\""
histobs_stats_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" DICTATE_HISTORY_STATS_NOW=2026-02-22T18:00:00Z tmux-whisper history stats --json)"
assert_json_equals "history_stats_json_entries" "$histobs_stats_json" "entries" "2"
assert_not_contains "history_stats_json_no_budget" "$histobs_stats_json" "postprocess_budget"
assert_json_equals "history_stats_json_recent_24h" "$histobs_stats_json" "recent.last_24h.entries" "2"
assert_not_contains "history_stats_json_no_modes" "$histobs_stats_json" "\"modes\""
assert_json_equals "history_stats_json_app_processed_words" "$histobs_stats_json" "breakdowns.apps.Ghostty.processed_words" "30"
assert_json_equals "history_stats_json_typing_wpm_assumed" "$histobs_stats_json" "estimates.typing_wpm_assumed" "40"
assert_json_equals "history_stats_json_typing_delta" "$histobs_stats_json" "estimates.delta_vs_end_to_end_ms" "32650"
histobs_last="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper last)"
assert_contains "history_last_header" "$histobs_last" "Latest dictation"
assert_contains "history_last_capture_time" "$histobs_last" "capture_time: 18.0s"
assert_contains "history_last_end_to_end" "$histobs_last" "end_to_end: 18.9s"
assert_contains "history_last_pace" "$histobs_last" "dictation_pace: 100 wpm (raw)"
assert_contains "history_last_typing_equivalent" "$histobs_last" "typing_equivalent: 45.0s @ 40 wpm"
assert_contains "history_last_typing_delta" "$histobs_last" "typing_delta: +26.1s vs end-to-end"
histobs_last_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper last --json)"
assert_json_equals "history_last_json_app" "$histobs_last_json" "entry.app" "Ghostty"
assert_not_contains "history_last_json_no_budget" "$histobs_last_json" "postprocess_budget"

# --- Regression 12a: durable usage only records delivered inline/tmux summaries. ---
USAGE_HOME="$TMP_ROOT/home-usage"
USAGE_BIN="$USAGE_HOME/.local/bin"
USAGE_CFG="$USAGE_HOME/.config/dictate"
USAGE_FILE="$USAGE_CFG/usage.json"
mkdir -p "$USAGE_BIN" "$USAGE_CFG"
install_test_runtime "$USAGE_BIN"
cat >"$USAGE_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"
EOF

usage_record() {
  local flow="$1"
  local text="$2"
  local record_ms="$3"
  local full_elapsed_ms="$4"
  local ledger_file="${5:-$USAGE_FILE}"
  HOME="$USAGE_HOME" PATH="$USAGE_BIN:/usr/bin:/bin" DICTATE_USAGE_NOW=2026-09-17T12:00:00Z \
    DICTATE_CONFIG_DIR="$USAGE_CFG" DICTATE_USAGE_SUMMARY_FILE="$ledger_file" \
    bash -c 'need() { command -v "$1" >/dev/null 2>&1; }; source "$1"; usage_record_delivery "$2" "$3" "$4" "$5"' bash \
      "$USAGE_BIN/tmux-whisper-lib/history.sh" "$flow" "$text" "$record_ms" "$full_elapsed_ms"
}

# These direct helper calls model the two production call sites after delivery;
# cancelled, failed and no-speech paths do not call it.
usage_record inline "private inline words" 2000 5000
usage_record tmux "private tmux words" 3000 4000
usage_record inline "extra private" 1000 7000

usage_text="$(HOME="$USAGE_HOME" PATH="$USAGE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$USAGE_CFG" DICTATE_CONFIG_FILE="$USAGE_CFG/config.toml" DICTATE_USAGE_SUMMARY_FILE="$USAGE_FILE" tmux-whisper usage)"
assert_contains "usage_text_header" "$usage_text" "Dictation usage (tracked deliveries only)"
assert_contains "usage_text_flow_counts" "$usage_text" "delivered_dictations: 3 (inline=2, tmux=1)"
assert_contains "usage_text_wpm" "$usage_text" "typing_equivalent: 12.0s @ 40 wpm assumed"
assert_contains "usage_text_negative_estimate" "$usage_text" "estimated_time_difference: -4.0s"
assert_contains "usage_text_coverage" "$usage_text" "transcript history is not backfilled"
usage_json="$(HOME="$USAGE_HOME" PATH="$USAGE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$USAGE_CFG" DICTATE_CONFIG_FILE="$USAGE_CFG/config.toml" DICTATE_USAGE_SUMMARY_FILE="$USAGE_FILE" tmux-whisper usage --json)"
assert_json_equals "usage_json_command" "$usage_json" "command" "usage"
assert_json_equals "usage_json_count" "$usage_json" "delivered_dictations.count" "3"
assert_json_equals "usage_json_inline_count" "$usage_json" "delivered_dictations.by_flow.inline" "2"
assert_json_equals "usage_json_tmux_count" "$usage_json" "delivered_dictations.by_flow.tmux" "1"
assert_json_equals "usage_json_words" "$usage_json" "processed_words" "8"
assert_json_equals "usage_json_recording" "$usage_json" "recording_duration_ms" "6000"
assert_json_equals "usage_json_full_elapsed" "$usage_json" "full_elapsed_duration_ms" "16000"
assert_json_equals "usage_json_typing_wpm" "$usage_json" "typing_assumption.wpm" "40"
assert_json_equals "usage_json_typing_equivalent" "$usage_json" "typing_assumption.typing_equivalent_duration_ms" "12000"
assert_json_equals "usage_json_signed_difference" "$usage_json" "estimated_time_difference_ms" "-4000"
assert_json_equals "usage_json_coverage_start" "$usage_json" "coverage.tracking_started_at" "2026-09-17T12:00:00Z"
assert_json_equals "usage_json_no_backfill" "$usage_json" "coverage.history_backfill" "false"
if rg -q 'private inline|private tmux|extra private' "$USAGE_FILE"; then
  echo "Expected usage ledger to remain transcript-free" >&2
  exit 1
fi

# A fresh ledger exercises the positive side of the signed estimate.
USAGE_POSITIVE_FILE="$USAGE_CFG/usage-positive.json"
usage_record inline "one two three four five six seven eight nine ten" 1000 5000 "$USAGE_POSITIVE_FILE"
usage_positive_json="$(HOME="$USAGE_HOME" PATH="$USAGE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$USAGE_CFG" DICTATE_CONFIG_FILE="$USAGE_CFG/config.toml" DICTATE_USAGE_SUMMARY_FILE="$USAGE_POSITIVE_FILE" tmux-whisper usage --json)"
assert_json_equals "usage_positive_signed_difference" "$usage_positive_json" "estimated_time_difference_ms" "10000"

# Independent delivery workers must not lose updates, and an abandoned temporary
# write must never change what readers see.
USAGE_CONCURRENT_FILE="$USAGE_CFG/usage-concurrent.json"
usage_record inline "one two three" 1000 3000 "$USAGE_CONCURRENT_FILE" &
usage_left_pid=$!
usage_record tmux "four five six seven" 2000 4000 "$USAGE_CONCURRENT_FILE" &
usage_right_pid=$!
wait "$usage_left_pid"
wait "$usage_right_pid"
printf '%s\n' '{"partial":' >"$USAGE_CONCURRENT_FILE.tmp-interrupted"
usage_concurrent_json="$(HOME="$USAGE_HOME" PATH="$USAGE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$USAGE_CFG" DICTATE_CONFIG_FILE="$USAGE_CFG/config.toml" DICTATE_USAGE_SUMMARY_FILE="$USAGE_CONCURRENT_FILE" tmux-whisper usage --json)"
assert_json_equals "usage_concurrent_count" "$usage_concurrent_json" "delivered_dictations.count" "2"
assert_json_equals "usage_concurrent_inline" "$usage_concurrent_json" "delivered_dictations.by_flow.inline" "1"
assert_json_equals "usage_concurrent_tmux" "$usage_concurrent_json" "delivered_dictations.by_flow.tmux" "1"
assert_json_equals "usage_concurrent_words" "$usage_concurrent_json" "processed_words" "7"

# --- Regression 12d: config inspection should expose JSON and per-key lookup surfaces. ---
CONFIGOBS_HOME="$TMP_ROOT/home-configobs"
CONFIGOBS_BIN="$CONFIGOBS_HOME/.local/bin"
CONFIGOBS_CFG="$CONFIGOBS_HOME/.config/dictate"
CONFIGOBS_MODEL="$TMP_ROOT/configobs-model"
CONFIGOBS_SOCKET="$TMP_ROOT/configobs.sock"
mkdir -p "$CONFIGOBS_BIN" "$CONFIGOBS_CFG" "$CONFIGOBS_MODEL"
install_test_runtime "$CONFIGOBS_BIN"
cat >"$CONFIGOBS_CFG/config.toml" <<EOF
[meta]
config_version = 1

[history]
retention_days = 9

[swift_parakeet]
model_path = "$CONFIGOBS_MODEL"
socket_path = "$CONFIGOBS_SOCKET"

[postprocess]
enabled = true
llm = "qwen-3-32b"

[inline]
autosend = false
process_sound = true

[debug]
keep_logs = true
EOF
configobs_show="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config)"
assert_contains "config_show_path" "$configobs_show" "Config path: $CONFIGOBS_CFG/config.toml (present)"
assert_not_contains "config_show_ignores_postprocess" "$configobs_show" "postprocess"
configobs_show_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config --json)"
assert_json_equals "config_show_json_command" "$configobs_show_json" "command" "config"
assert_json_equals "config_show_json_subcommand" "$configobs_show_json" "subcommand" "show"
assert_json_equals "config_show_json_exists" "$configobs_show_json" "config_exists" "true"
assert_json_equals "config_show_json_schema_status" "$configobs_show_json" "schema.status" "ok"
assert_json_equals "config_show_json_history_retention" "$configobs_show_json" "effective.history.retention_days" "9"
assert_json_equals "config_show_json_inline_autosend" "$configobs_show_json" "effective.inline.autosend" "false"
assert_not_contains "config_show_json_ignores_postprocess" "$configobs_show_json" "postprocess"
assert_json_equals "config_show_json_keep_logs" "$configobs_show_json" "effective.debug.keep_logs" "true"
configobs_path_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config path --json)"
assert_json_equals "config_path_json_subcommand" "$configobs_path_json" "subcommand" "path"
assert_json_equals "config_path_json_path" "$configobs_path_json" "config_path" "$CONFIGOBS_CFG/config.toml"
configobs_get_text="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config get history.retention_days)"
assert_contains "config_get_text_value" "$configobs_get_text" "history.retention_days = 9"
assert_contains "config_get_text_source" "$configobs_get_text" "source: file"
configobs_get_default_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config get inline.paste_target --json)"
assert_json_equals "config_get_default_found" "$configobs_get_default_json" "found" "true"
assert_json_equals "config_get_default_source" "$configobs_get_default_json" "source" "default"
assert_json_equals "config_get_default_value" "$configobs_get_default_json" "value" "current"
configobs_get_unset_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config get made.up.path --json)"
assert_json_equals "config_get_unset_found" "$configobs_get_unset_json" "found" "false"
assert_json_equals "config_get_unset_source" "$configobs_get_unset_json" "source" "unset"
assert_json_equals "config_get_unset_value" "$configobs_get_unset_json" "value" "null"

# --- Regression 13: vocab import/export/dedupe safety behavior remains stable. ---
VOCAB_HOME="$TMP_ROOT/home-vocab"
VOCAB_BIN="$VOCAB_HOME/.local/bin"
VOCAB_CFG="$VOCAB_HOME/.config/dictate"
mkdir -p "$VOCAB_BIN" "$VOCAB_CFG"
install_test_runtime "$VOCAB_BIN"

IMPORT_FILE="$TMP_ROOT/vocab-import.txt"
cat >"$IMPORT_FILE" <<'EOF'
health lag::help flag
my app -> MyApp
codex → Codex
bad line
EOF

import_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab import "$IMPORT_FILE")"
assert_contains "vocab_import_summary" "$import_out" "Vocab import ($IMPORT_FILE): added=3 duplicate=0 invalid=1"
assert_contains "vocab_import_invalid_preview" "$import_out" "line 4: bad line"

DRY_RUN_IMPORT_FILE="$TMP_ROOT/vocab-import-dry-run.txt"
cat >"$DRY_RUN_IMPORT_FILE" <<'EOF'
later fix::LaterFix
EOF
import_dry_run_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab import --dry-run "$DRY_RUN_IMPORT_FILE")"
assert_contains "vocab_import_dry_run_summary" "$import_dry_run_out" "Vocab import dry-run ($DRY_RUN_IMPORT_FILE): added=1 duplicate=0 invalid=0"
assert_not_contains "vocab_import_dry_run_no_backup" "$import_dry_run_out" "Backup: "
if rg -q --fixed-strings "later fix → LaterFix" "$VOCAB_CFG/vocab"; then
  echo "FAIL: vocab_import_dry_run_no_mutation" >&2
  exit 1
fi
echo "PASS: vocab_import_dry_run_no_mutation"

import_backup_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab import "$DRY_RUN_IMPORT_FILE")"
assert_contains "vocab_import_backup_summary" "$import_backup_out" "Vocab import ($DRY_RUN_IMPORT_FILE): added=1 duplicate=0 invalid=0"
assert_contains "vocab_import_backup_line" "$import_backup_out" "Backup: "
import_backup_file="$(printf "%s\n" "$import_backup_out" | sed -n 's/^Backup: //p' | head -n 1)"
assert_file_exists "vocab_import_backup_exists" "$import_backup_file"
assert_file_contains "vocab_import_backup_new_entry" "$VOCAB_CFG/vocab" "later fix → LaterFix"

EXPORT_FILE="$TMP_ROOT/vocab-export.txt"
export_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab export "$EXPORT_FILE")"
assert_contains "vocab_export_summary" "$export_out" "Vocab export ($EXPORT_FILE): entries=4 duplicate_skipped=0 invalid_skipped=0"
assert_file_contains "vocab_export_arrow_normalized" "$EXPORT_FILE" "my app → MyApp"

printf '%s\n' 'health lag::help flag' 'still bad' >>"$VOCAB_CFG/vocab"
dedupe_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab dedupe)"
assert_contains "vocab_dedupe_summary" "$dedupe_out" "duplicate_removed=1 invalid_removed=1"
assert_contains "vocab_dedupe_backup_line" "$dedupe_out" "Backup: "
dedupe_backup="$(printf "%s\n" "$dedupe_out" | sed -n 's/^Backup: //p' | head -n 1)"
assert_file_exists "vocab_dedupe_backup_exists" "$dedupe_backup"

printf '%s\n' 'a.b → Dot entry' 'axb → Regex casualty' >>"$VOCAB_CFG/vocab"
rm_dry_run_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab rm --dry-run "a.b")"
assert_contains "vocab_rm_dry_run_summary" "$rm_dry_run_out" "Vocab rm dry-run: removed=1 match=literal pattern=a.b"
assert_file_contains "vocab_rm_dry_run_keeps_literal_target" "$VOCAB_CFG/vocab" "a.b → Dot entry"
assert_file_contains "vocab_rm_dry_run_keeps_regex_neighbor" "$VOCAB_CFG/vocab" "axb → Regex casualty"

rm_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab rm "a.b")"
assert_contains "vocab_rm_summary" "$rm_out" "Vocab rm: removed=1 match=literal pattern=a.b"
assert_contains "vocab_rm_backup_line" "$rm_out" "Backup: "
rm_backup_file="$(printf "%s\n" "$rm_out" | sed -n 's/^Backup: //p' | head -n 1)"
assert_file_exists "vocab_rm_backup_exists" "$rm_backup_file"
if rg -q --fixed-strings "a.b → Dot entry" "$VOCAB_CFG/vocab"; then
  echo "FAIL: vocab_rm_removed_literal_target" >&2
  exit 1
fi
echo "PASS: vocab_rm_removed_literal_target"
assert_file_contains "vocab_rm_keeps_regex_neighbor" "$VOCAB_CFG/vocab" "axb → Regex casualty"

regex_invalid_out="$(HOME="$VOCAB_HOME" PATH="$VOCAB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$VOCAB_CFG" DICTATE_CONFIG_FILE="$VOCAB_CFG/config.toml" tmux-whisper vocab rm --regex "[" 2>&1 || true)"
assert_contains "vocab_rm_regex_invalid_message" "$regex_invalid_out" "invalid regex pattern: ["
assert_file_contains "vocab_rm_regex_invalid_no_mutation" "$VOCAB_CFG/vocab" "axb → Regex casualty"

# --- Regression 14: bench summary/export surfaces are stable. ---
BENCH_HOME="$TMP_ROOT/home-bench"
BENCH_BIN="$BENCH_HOME/.local/bin"
BENCH_CFG="$BENCH_HOME/.config/dictate"
BENCH_HISTORY="$BENCH_CFG/history"
mkdir -p "$BENCH_BIN" "$BENCH_CFG" "$BENCH_HISTORY"
install_test_runtime "$BENCH_BIN"
cat >"$BENCH_HISTORY/bench.tsv" <<'EOF'
2026-04-22T09:00:00Z	inline	ok	gpt-oss-120b	chat	1	100	120	1800	220	15	620	45	2700	150	35	20	10	detect:source(external)
2026-04-22T09:01:00Z	tmux	no_speech	swift_parakeet	code	0	0	0	900	110	10	0	0	1020	0	0	0	0
2026-04-22T09:02:00Z	inline	ok	gpt-oss-120b	email	1	80	90	1500	200	12	500	30	2242	120	30	15	5	detect:source(mac)
EOF

bench_summary_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench 2)"
assert_contains "bench_summary_header" "$bench_summary_out" "Tmux Whisper bench (last 2 of 3 runs)"
assert_contains "bench_summary_flow_counts" "$bench_summary_out" "by flow: inline=1, tmux=1"
assert_contains "bench_summary_status_counts" "$bench_summary_out" "by status: no_speech=1, ok=1"
assert_contains "bench_summary_startup_section" "$bench_summary_out" "Startup readiness:"
assert_contains "bench_summary_latest_line" "$bench_summary_out" "2026-04-22T09:02:00Z flow=inline status=ok"
assert_contains "bench_summary_next" "$bench_summary_out" "  tmux-whisper history sessions 5"

bench_summary_json="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench 2 --json)"
assert_json_equals "bench_json_command" "$bench_summary_json" "command" "bench"
assert_json_equals "bench_json_subcommand" "$bench_summary_json" "subcommand" "show"
assert_json_equals "bench_json_total_records" "$bench_summary_json" "total_records" "3"
assert_json_equals "bench_json_filtered_records" "$bench_summary_json" "filtered_records" "3"
assert_json_equals "bench_json_subset_records" "$bench_summary_json" "subset_records" "2"
assert_json_equals "bench_json_flow_inline" "$bench_summary_json" "counts.flows.inline" "1"
assert_json_equals "bench_json_status_ok" "$bench_summary_json" "counts.statuses.ok" "1"
assert_json_equals "bench_json_total_stage_n" "$bench_summary_json" "stages.total_ms.n" "2"
assert_json_equals "bench_json_latest_timestamp" "$bench_summary_json" "latest.timestamp" "2026-04-22T09:02:00Z"
# Column 5 (the old cleanup mode) still parses but is no longer reported.
assert_not_contains "bench_json_no_mode" "$bench_summary_json" "\"mode\""
assert_not_contains "bench_json_no_postprocess" "$bench_summary_json" "postprocess"
assert_json_equals "bench_json_next" "$bench_summary_json" "next_commands.0" "tmux-whisper history sessions 5"

bench_filtered_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench all --flow inline)"
assert_contains "bench_filter_header" "$bench_filtered_out" "Tmux Whisper bench (last 2 of 2 matching runs; total 3)"
assert_contains "bench_filter_flow_line" "$bench_filtered_out" "flow: inline"
assert_contains "bench_filter_flow_counts" "$bench_filtered_out" "by flow: inline=2"
assert_contains "bench_filter_latest_line" "$bench_filtered_out" "2026-04-22T09:02:00Z flow=inline status=ok"

bench_filtered_json="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench all --flow inline --slow-total-ms 2500 --json)"
assert_json_equals "bench_filter_json_total_records" "$bench_filtered_json" "total_records" "3"
assert_json_equals "bench_filter_json_filtered_records" "$bench_filtered_json" "filtered_records" "1"
assert_json_equals "bench_filter_json_subset_records" "$bench_filtered_json" "subset_records" "1"
assert_json_equals "bench_filter_json_filter_flow" "$bench_filtered_json" "filters.flow" "inline"
assert_json_equals "bench_filter_json_filter_total_min" "$bench_filtered_json" "filters.minimums.total_ms" "2500"
assert_json_equals "bench_filter_json_latest_timestamp" "$bench_filtered_json" "latest.timestamp" "2026-04-22T09:00:00Z"

bench_filtered_export_json="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench export all --slow-total-ms 2500 --json)"
assert_json_equals "bench_filter_export_json_count" "$bench_filtered_export_json" "0.timestamp" "2026-04-22T09:00:00Z"

bench_export_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench export 2)"
assert_contains "bench_export_first_entry" "$bench_export_out" "=== Bench 1 ==="
assert_contains "bench_export_first_timestamp" "$bench_export_out" "Timestamp: 2026-04-22T09:02:00Z"
assert_contains "bench_export_second_entry" "$bench_export_out" "=== Bench 2 ==="
assert_contains "bench_export_second_timestamp" "$bench_export_out" "Timestamp: 2026-04-22T09:01:00Z"
assert_contains "bench_export_metrics_block" "$bench_export_out" "Metrics:"

bench_export_json="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench export all --json)"
assert_json_equals "bench_export_json_first_index" "$bench_export_json" "0.index" "1"
assert_json_equals "bench_export_json_first_timestamp" "$bench_export_json" "0.timestamp" "2026-04-22T09:02:00Z"
assert_json_equals "bench_export_json_first_flow" "$bench_export_json" "0.flow" "inline"
assert_json_equals "bench_export_json_second_timestamp" "$bench_export_json" "1.timestamp" "2026-04-22T09:01:00Z"
assert_json_equals "bench_export_json_third_timestamp" "$bench_export_json" "2.timestamp" "2026-04-22T09:00:00Z"
assert_json_equals "bench_export_json_third_audio_source" "$bench_export_json" "2.startup_audio_source" "detect:source(external)"

# tools/khuluma-report.sh: app.log summary (transcript-free). The done(native)
# and verify: lines are from retired builds and must be ignored.
REPORT_LOG="$TMP_ROOT/khuluma-app.log"
cat >"$REPORT_LOG" <<'EOF'
[2026-10-10T09:00:00.000Z] done(native): stop→delivered 700ms: queue 2, asr 520, clean 5.0, deliver 170; mode=base, chars=10, target=Claude
[2026-10-10T09:00:01.000Z] verify: take aaa transcript mismatch native="x" cli="y" transcript="SECRET dictated words"
[2026-10-11T09:00:00.000Z] start: engine.start 50.0ms, hotkey→capturing 110.0ms, app=Claude
[2026-10-11T09:00:05.000Z] stop: record 4000ms, hotkey→first audio 210.0ms, samples 64000
[2026-10-11T09:00:05.500Z] take: path=native outcome=delivered state=warm record=4000 total=500 queue=2 prep=3 probe=0 full=310 full_daemon=300 asr=315 clean=5 deliver=170 waits=150 mode=base chars=12 target="Google Chrome"
[2026-10-11T09:01:00.000Z] take: path=native outcome=delivered state=cold record=20000 total=900 queue=2 prep=4 probe=1 full=520 full_daemon=500 tail_window=8000 tail=110 tail_daemon=100 asr=640 clean=8 deliver=160 waits=150 mode=base chars=40 target=Claude
[2026-10-11T09:02:00.000Z] take: path=native outcome=delivered state=warm record=6000 total=460 queue=1 prep=3 probe=0 full=255 full_daemon=250 asr=260 clean=4 deliver=165 waits=150 mode=base chars=20 target=Claude
[2026-10-11T09:03:00.000Z] take: path=fallback reason="daemon unreachable" outcome=delivered record=3000 total=1200 queue=1 cli=1000 transcribe=800 deliver=170 waits=150 mode=base chars=9 target=Claude
[2026-10-11T09:04:00.000Z] take: path=native outcome=timed_out state=unknown record=3000 total=31000 queue=1 asr=30000 kept=1
[2026-10-11T09:05:00.000Z] supervisor: daemon warmed in 1800ms (launch)
[2026-10-11T09:05:01.000Z] verify: take bbb matches the CLI
[2026-10-11T09:06:00.000Z] error: could not start recording: format mismatch
[2026-10-11T09:07:00.000Z] take: path=native outcome=delivered state=warm record=14000 total=2000 queue=1 prep=3 probe=0 full=900 full_daemon=880 tail_window=8000 tail=600 tail_failed=1 asr=1500 clean=4 deliver=165 waits=150 mode=base chars=20 target=Claude
[2026-10-11T09:08:00.000Z] take: path=fallback reason="daemon unreachable" outcome=failed record=3000 total=900 queue=1 error="SECRET leaked through an error"
[2026-10-12T09:00:00.000Z] verify: take ccc pipeline mismatch: text native="SECRET this matches the CLI" cli="x"
[2026-10-12T09:00:01.000Z] verify: take ddd pipeline mismatch: text native="SECRET skipped: and could not run" cli="x"
[2026-10-12T09:00:02.000Z] verify: take eee matches the CLI
[2026-10-13T09:00:02.000Z] verify: take fff matches the CLI
EOF
report_text="$(TZ=UTC "$ROOT/tools/khuluma-report.sh" --log "$REPORT_LOG")"
assert_contains "khuluma_report_take_counts" "$report_text" "Takes: 7 (native 5, fallback 2)"
assert_contains "khuluma_report_fallback_rate" "$report_text" "fallback rate: 28.6% (2 of 7 tried natively); daemon unreachable x2"
assert_contains "khuluma_report_failure_rate" "$report_text" "failure rate: 28.6% (2 of 7)"
assert_contains "khuluma_report_failure_kinds" "$report_text" "    timed_out x1"
assert_contains "khuluma_report_error_codes_only" "$report_text" "    failed: other x1"
assert_contains "khuluma_report_incomplete_tail" "$report_text" "1 without daemon timings for every pass"
assert_contains "khuluma_report_overhead" "$report_text" "minus Parakeet and delivery waits): median 55ms, p90 60ms (n=2)"
assert_contains "khuluma_report_overhead_bucket" "$report_text" "5-15s: median 60ms, p90 60ms (n=1)"
assert_contains "khuluma_report_overhead_cold" "$report_text" "overhead, not warm (cold): median 150ms"
assert_contains "khuluma_report_transport" "$report_text" "request minus model time (warm): median 8ms"
assert_contains "khuluma_report_start_failures" "$report_text" "recordings that failed to start: 1"
assert_contains "khuluma_report_warmups" "$report_text" "model warmups started by Khuluma (daemon model warmup time): median 1800ms"
assert_not_contains "khuluma_report_ignores_verify" "$report_text" "Verify"
assert_not_contains "khuluma_report_ignores_legacy" "$report_text" "before instrumentation"
assert_not_contains "khuluma_report_transcript_free" "$report_text" "SECRET"
report_since="$(TZ=UTC "$ROOT/tools/khuluma-report.sh" --log "$REPORT_LOG" --since 2026-10-12)"
assert_contains "khuluma_report_since_window" "$report_since" "Window: 2026-10-12 to 2026-10-13 (since 2026-10-12)"
assert_contains "khuluma_report_since_drops_takes" "$report_since" "Takes: 0"
if "$ROOT/tools/khuluma-report.sh" --log "$REPORT_LOG" --days x >/dev/null 2>&1; then
  echo "FAIL: khuluma_report_rejects_bad_days" >&2
  exit 1
fi
echo "PASS: khuluma_report_rejects_bad_days"

echo "Regression tests passed."
