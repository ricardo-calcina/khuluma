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

custom_debug="$(HOME="$CUSTOM_HOME" PATH="$CUSTOM_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CUSTOM_DICTATE_CONFIG_DIR" DICTATE_CONFIG_FILE="$CUSTOM_DICTATE_CONFIG_FILE" "$CUSTOM_BIN/tmux-whisper" debug)"
assert_contains "debug_channel_present" "$custom_debug" "channel: "
assert_contains "debug_paths_section" "$custom_debug" "Paths:"
assert_contains "debug_install_lib_line" "$custom_debug" "lib:"
custom_debug_json="$(HOME="$CUSTOM_HOME" PATH="$CUSTOM_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CUSTOM_DICTATE_CONFIG_DIR" DICTATE_CONFIG_FILE="$CUSTOM_DICTATE_CONFIG_FILE" "$CUSTOM_BIN/tmux-whisper" debug --json)"
assert_json_equals "debug_json_command" "$custom_debug_json" "command" "debug"
assert_json_equals "debug_json_channel" "$custom_debug_json" "binaries.channel" "custom"
assert_json_equals "debug_json_backend" "$custom_debug_json" "paths.backend" "swift_parakeet"

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

local_debug="$(HOME="$LOCAL_HOME" PATH="$LOCAL_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOCAL_DICTATE_CONFIG_DIR" DICTATE_CONFIG_FILE="$LOCAL_DICTATE_CONFIG_FILE" tmux-whisper debug)"
assert_contains "debug_local_user_channel" "$local_debug" "channel: local-user"

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

backend_debug="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_STATE_FILE="$BACKEND_STATE_FILE" DICTATE_INLINE_STATE_FILE="$BACKEND_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$BACKEND_TMUX_JOBS_DIR" tmux-whisper debug)"
assert_contains "debug_backend_requested" "$backend_debug" "backend:      swift_parakeet"
assert_contains "debug_backend_model_path" "$backend_debug" "parakeet_mod: $BACKEND_MODEL (ok, v3)"

backend_doctor="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_STATE_FILE="$BACKEND_STATE_FILE" DICTATE_INLINE_STATE_FILE="$BACKEND_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$BACKEND_TMUX_JOBS_DIR" tmux-whisper doctor)"
assert_contains "doctor_backend_requested" "$backend_doctor" "backend: swift_parakeet"
assert_contains "doctor_backend_model_version" "$backend_doctor" "parakeet model version: v3"

backend_status="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_STATE_FILE="$BACKEND_STATE_FILE" DICTATE_INLINE_STATE_FILE="$BACKEND_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$BACKEND_TMUX_JOBS_DIR" tmux-whisper status)"
assert_contains "status_backend_summary_state" "$backend_status" "state: ready"
assert_contains "status_backend_summary_readiness" "$backend_status" "backend_readiness: cold"
assert_contains "status_backend_summary_next_action" "$backend_status" "run tmux-whisper warmup"
assert_contains "status_backend_swift_model" "$backend_status" "swift_parakeet.model: $BACKEND_MODEL (v3)"
assert_contains "status_backend_swift_socket" "$backend_status" "swift_parakeet.socket: $BACKEND_CFG/.cache/tmux-whisperd.sock"
assert_contains "status_backend_inline_process_sound" "$backend_status" "inline.process_sound: ON"
assert_not_contains "status_backend_hides_inline_model" "$backend_status" "model.inline:"
assert_not_contains "status_backend_hides_tmux_model" "$backend_status" "model.tmux:"
assert_not_contains "status_backend_hides_whisper_knobs" "$backend_status" "whisper.threads/beam/best_of:"
backend_status_json="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_STATE_FILE="$BACKEND_STATE_FILE" DICTATE_INLINE_STATE_FILE="$BACKEND_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$BACKEND_TMUX_JOBS_DIR" tmux-whisper status --json)"
assert_json_equals "status_json_command" "$backend_status_json" "command" "status"
assert_json_equals "status_json_summary_state" "$backend_status_json" "summary.state" "ready"
assert_json_equals "status_json_summary_backend_readiness" "$backend_status_json" "summary.backend_readiness" "cold"
assert_json_equals "status_json_backend" "$backend_status_json" "effective_settings.backend" "swift_parakeet"
assert_json_equals "status_json_model_version" "$backend_status_json" "effective_settings.swift_parakeet.model.version" "v3"
assert_json_equals "status_json_inline_process_sound" "$backend_status_json" "effective_settings.inline.process_sound" "true"
assert_json_equals "status_json_tmux_queue_total" "$backend_status_json" "runtime.tmux_queue.total" "0"
backend_status_compact="$(HOME="$BACKEND_HOME" PATH="$BACKEND_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BACKEND_CFG" DICTATE_CONFIG_FILE="$BACKEND_CFG/config.toml" DICTATE_STATE_FILE="$BACKEND_STATE_FILE" DICTATE_INLINE_STATE_FILE="$BACKEND_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$BACKEND_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$BACKEND_TMUX_JOBS_DIR" tmux-whisper status --preset compact)"
assert_contains "status_compact_header" "$backend_status_compact" "Tmux Whisper status (compact)"
assert_contains "status_compact_summary" "$backend_status_compact" "Summary: state=ready backend=cold flow=none config=v1/ok"
assert_contains "status_compact_modes" "$backend_status_compact" "Modes: inline=code [auto], tmux=code"
assert_contains "status_compact_runtime" "$backend_status_compact" "Runtime: tmux=idle inline=idle proc=0/0 stale=0 queue=0/0"
assert_contains "status_compact_next" "$backend_status_compact" "Next: Use your normal hotkey, or run tmux-whisper warmup to pre-load the daemon."
assert_contains "status_compact_more" "$backend_status_compact" "More: tmux-whisper watch --preset compact | tmux-whisper last | tmux-whisper bench"

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
if rg -q 'budget_long_words_threshold' "$MISMATCH_CFG/config.toml"; then
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
assert_file_contains "config_repair_added_threshold" "$MISMATCH_CFG/config.toml" "budget_long_words_threshold = 120"
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
invalidcfg_doctor="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_STATE_FILE="$INVALIDCFG_STATE_FILE" DICTATE_INLINE_STATE_FILE="$INVALIDCFG_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$INVALIDCFG_TMUX_JOBS_DIR" tmux-whisper doctor 2>&1)"
assert_contains "doctor_invalidcfg_status" "$invalidcfg_doctor" "config schema: invalid (expected v1, status=invalid)"
assert_contains "doctor_invalidcfg_hint" "$invalidcfg_doctor" "config TOML is invalid"
assert_contains "doctor_invalidcfg_parse_error" "$invalidcfg_doctor" "parse error:"
assert_not_contains "doctor_invalidcfg_no_traceback" "$invalidcfg_doctor" "Traceback (most recent call last)"

invalidcfg_status="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_STATE_FILE="$INVALIDCFG_STATE_FILE" DICTATE_INLINE_STATE_FILE="$INVALIDCFG_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$INVALIDCFG_TMUX_JOBS_DIR" tmux-whisper status 2>&1)"
assert_contains "status_invalidcfg_headline" "$invalidcfg_status" "headline: Config file is invalid TOML."
assert_contains "status_invalidcfg_schema" "$invalidcfg_status" "config.schema: invalid (status=invalid)"
assert_contains "status_invalidcfg_parse_error" "$invalidcfg_status" "config.parse_error:"
assert_not_contains "status_invalidcfg_no_traceback" "$invalidcfg_status" "Traceback (most recent call last)"

set +e
invalidcfg_keep_logs_out="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_STATE_FILE="$INVALIDCFG_STATE_FILE" DICTATE_INLINE_STATE_FILE="$INVALIDCFG_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$INVALIDCFG_TMUX_JOBS_DIR" tmux-whisper keep-logs on 2>&1)"
invalidcfg_keep_logs_rc=$?
set -e
assert_equals "config_set_invalid_exit" "$invalidcfg_keep_logs_rc" "2"
assert_contains "config_set_invalid_hint" "$invalidcfg_keep_logs_out" "config TOML is invalid"
assert_contains "config_set_invalid_preview" "$invalidcfg_keep_logs_out" "tmux-whisper config repair --dry-run"
assert_contains "config_set_invalid_parse_error" "$invalidcfg_keep_logs_out" "Parse error: "
assert_not_contains "config_set_invalid_no_traceback" "$invalidcfg_keep_logs_out" "Traceback (most recent call last)"
assert_file_contains "config_set_invalid_no_mutation" "$INVALIDCFG_CFG/config.toml" "[audio"

invalidcfg_repair_dry_run="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_STATE_FILE="$INVALIDCFG_STATE_FILE" DICTATE_INLINE_STATE_FILE="$INVALIDCFG_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$INVALIDCFG_TMUX_JOBS_DIR" tmux-whisper config repair --dry-run)"
assert_contains "config_repair_invalid_dry_run_summary" "$invalidcfg_repair_dry_run" "Config repair dry-run: invalid/invalid -> v1"
assert_contains "config_repair_invalid_dry_run_action" "$invalidcfg_repair_dry_run" "Action: replace invalid TOML with canonical defaults"
assert_contains "config_repair_invalid_dry_run_parse_error" "$invalidcfg_repair_dry_run" "Parse error: "
assert_not_contains "config_repair_invalid_dry_run_no_backup" "$invalidcfg_repair_dry_run" "Backup: "
assert_file_contains "config_repair_invalid_dry_run_no_mutation" "$INVALIDCFG_CFG/config.toml" "[audio"

invalidcfg_repair_out="$(HOME="$INVALIDCFG_HOME" PATH="$INVALIDCFG_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INVALIDCFG_CFG" DICTATE_CONFIG_FILE="$INVALIDCFG_CFG/config.toml" DICTATE_STATE_FILE="$INVALIDCFG_STATE_FILE" DICTATE_INLINE_STATE_FILE="$INVALIDCFG_INLINE_STATE_FILE" DICTATE_PROCESSING_DIR="$INVALIDCFG_PROCESSING_DIR" DICTATE_TMUX_JOBS_DIR="$INVALIDCFG_TMUX_JOBS_DIR" tmux-whisper config repair)"
assert_contains "config_repair_invalid_summary" "$invalidcfg_repair_out" "Config repair: invalid/invalid -> v1"
assert_contains "config_repair_invalid_action" "$invalidcfg_repair_out" "Action: replace invalid TOML with canonical defaults"
assert_contains "config_repair_invalid_parse_error" "$invalidcfg_repair_out" "Parse error: "
assert_contains "config_repair_invalid_backup_line" "$invalidcfg_repair_out" "Backup: "
invalidcfg_repair_backup="$(printf "%s\n" "$invalidcfg_repair_out" | sed -n 's/^Backup: //p' | head -n 1)"
assert_file_exists "config_repair_invalid_backup_exists" "$invalidcfg_repair_backup"
assert_file_contains "config_repair_invalid_written_version" "$INVALIDCFG_CFG/config.toml" "config_version = 1"
assert_file_contains "config_repair_invalid_written_audio" "$INVALIDCFG_CFG/config.toml" "source = \"auto\""

# --- Regression 5: doctor mode checks should show clear fallbacks + fixes. ---
MODECHECK_HOME="$TMP_ROOT/home-modecheck"
MODECHECK_BIN="$MODECHECK_HOME/.local/bin"
MODECHECK_CFG="$MODECHECK_HOME/.config/dictate"
mkdir -p "$MODECHECK_BIN" "$MODECHECK_CFG/modes/code" "$MODECHECK_CFG/modes/long"
install_test_runtime "$MODECHECK_BIN"
cat >"$MODECHECK_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[tmux]
mode = "ghost"
EOF
printf '%s\n' "ghost" >"$MODECHECK_CFG/current-mode"
printf '%s\n' "Context: code mode." >"$MODECHECK_CFG/modes/code/prompt"
printf '%s\n' "Context: long mode." >"$MODECHECK_CFG/modes/long/prompt"
modecheck_doctor="$(HOME="$MODECHECK_HOME" PATH="$MODECHECK_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODECHECK_CFG" DICTATE_CONFIG_FILE="$MODECHECK_CFG/config.toml" tmux-whisper doctor)"
assert_contains "doctor_modecheck_section" "$modecheck_doctor" "Mode/config:"
assert_contains "doctor_modecheck_fixed_invalid" "$modecheck_doctor" "mode.current: ghost (invalid, fallback=auto)"
assert_contains "doctor_modecheck_tmux_invalid" "$modecheck_doctor" "tmux.mode: ghost (invalid, fallback=code)"
assert_contains "doctor_modecheck_fix_mode" "$modecheck_doctor" "Set inline mode policy: tmux-whisper mode auto"
assert_contains "doctor_modecheck_fix_tmux" "$modecheck_doctor" "Set tmux mode to a valid mode: tmux-whisper tmux mode code"

# --- Regression 5b: inline auto mode should use app detection with base fallback. ---
MODEAUTO_HOME="$TMP_ROOT/home-modeauto"
MODEAUTO_BIN="$MODEAUTO_HOME/.local/bin"
MODEAUTO_CFG="$MODEAUTO_HOME/.config/dictate"
mkdir -p "$MODEAUTO_BIN" "$MODEAUTO_CFG/modes/base" "$MODEAUTO_CFG/modes/chat" "$MODEAUTO_CFG/modes/code"
install_test_runtime "$MODEAUTO_BIN"
cat >"$MODEAUTO_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"
EOF
printf '%s\n' "auto" >"$MODEAUTO_CFG/current-mode"
printf '%s\n' "Context: base mode." >"$MODEAUTO_CFG/modes/base/prompt"
printf '%s\n' "inline" >"$MODEAUTO_CFG/modes/base/flows"
printf '%s\n' "Context: chat mode." >"$MODEAUTO_CFG/modes/chat/prompt"
printf '%s\n' "Messages" >"$MODEAUTO_CFG/modes/chat/apps"
printf '%s\n' "inline" >"$MODEAUTO_CFG/modes/chat/flows"
printf '%s\n' "Context: code mode." >"$MODEAUTO_CFG/modes/code/prompt"
printf '%s\n' "tmux" "inline" >"$MODEAUTO_CFG/modes/code/flows"
modeauto_status_messages="$(HOME="$MODEAUTO_HOME" PATH="$MODEAUTO_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODEAUTO_CFG" DICTATE_CONFIG_FILE="$MODEAUTO_CFG/config.toml" DICTATE_TEST_FRONT_APP=Messages tmux-whisper status)"
assert_contains "status_modeauto_chat" "$modeauto_status_messages" "mode.inline: chat (auto)"
modeauto_status_preview="$(HOME="$MODEAUTO_HOME" PATH="$MODEAUTO_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODEAUTO_CFG" DICTATE_CONFIG_FILE="$MODEAUTO_CFG/config.toml" DICTATE_TEST_FRONT_APP=Preview tmux-whisper status)"
assert_contains "status_modeauto_base" "$modeauto_status_preview" "mode.inline: base (auto)"

# --- Regression 5c: mode flow command should surface and set flow availability. ---
MODEFLOWS_HOME="$TMP_ROOT/home-modeflows"
MODEFLOWS_BIN="$MODEFLOWS_HOME/.local/bin"
MODEFLOWS_CFG="$MODEFLOWS_HOME/.config/dictate"
mkdir -p "$MODEFLOWS_BIN" "$MODEFLOWS_CFG/modes/code"
install_test_runtime "$MODEFLOWS_BIN"
cat >"$MODEFLOWS_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"
EOF
printf '%s\n' "code" >"$MODEFLOWS_CFG/current-mode"
printf '%s\n' "Context: code mode." >"$MODEFLOWS_CFG/modes/code/prompt"
modeflows_tmux="$(HOME="$MODEFLOWS_HOME" PATH="$MODEFLOWS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODEFLOWS_CFG" DICTATE_CONFIG_FILE="$MODEFLOWS_CFG/config.toml" tmux-whisper mode flows code tmux)"
assert_contains "mode_flows_tmux_summary" "$modeflows_tmux" "Mode flows for code: tmux"
assert_file_contains "mode_flows_tmux_file" "$MODEFLOWS_CFG/modes/code/flows" "tmux"
modeflows_both="$(HOME="$MODEFLOWS_HOME" PATH="$MODEFLOWS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODEFLOWS_CFG" DICTATE_CONFIG_FILE="$MODEFLOWS_CFG/config.toml" tmux-whisper mode flows code both)"
assert_contains "mode_flows_both_summary" "$modeflows_both" "Mode flows for code: tmux+inline"
assert_file_contains "mode_flows_both_file_tmux" "$MODEFLOWS_CFG/modes/code/flows" "tmux"
assert_file_contains "mode_flows_both_file_inline" "$MODEFLOWS_CFG/modes/code/flows" "inline"

# --- Regression 5d: doctor should flag flow-disabled mode policies and ignored app mappings. ---
MODEDOCTOR_HOME="$TMP_ROOT/home-modedoctor"
MODEDOCTOR_BIN="$MODEDOCTOR_HOME/.local/bin"
MODEDOCTOR_CFG="$MODEDOCTOR_HOME/.config/dictate"
mkdir -p "$MODEDOCTOR_BIN" \
  "$MODEDOCTOR_CFG/modes/base" \
  "$MODEDOCTOR_CFG/modes/chat" \
  "$MODEDOCTOR_CFG/modes/code" \
  "$MODEDOCTOR_CFG/modes/email"
install_test_runtime "$MODEDOCTOR_BIN"
cat >"$MODEDOCTOR_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[tmux]
mode = "base"
EOF
printf '%s\n' "chat" >"$MODEDOCTOR_CFG/current-mode"
printf '%s\n' "Context: base mode." >"$MODEDOCTOR_CFG/modes/base/prompt"
printf '%s\n' "inline" >"$MODEDOCTOR_CFG/modes/base/flows"
printf '%s\n' "Context: chat mode." >"$MODEDOCTOR_CFG/modes/chat/prompt"
printf '%s\n' "tmux" >"$MODEDOCTOR_CFG/modes/chat/flows"
printf '%s\n' "Messages" >"$MODEDOCTOR_CFG/modes/chat/apps"
printf '%s\n' "Context: code mode." >"$MODEDOCTOR_CFG/modes/code/prompt"
printf '%s\n' "tmux" >"$MODEDOCTOR_CFG/modes/code/flows"
printf '%s\n' "Context: email mode." >"$MODEDOCTOR_CFG/modes/email/prompt"
printf '%s\n' "voice" >"$MODEDOCTOR_CFG/modes/email/flows"
modedoctor_out="$(HOME="$MODEDOCTOR_HOME" PATH="$MODEDOCTOR_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODEDOCTOR_CFG" DICTATE_CONFIG_FILE="$MODEDOCTOR_CFG/config.toml" tmux-whisper doctor)"
assert_contains "doctor_flow_disabled_inline" "$modedoctor_out" "mode.current: chat (fixed, inline disabled, fallback=base)"
assert_contains "doctor_flow_disabled_tmux" "$modedoctor_out" "tmux.mode: base (tmux disabled, fallback=code)"
assert_contains "doctor_flow_count_inline" "$modedoctor_out" "modes.inline-capable: 1"
assert_contains "doctor_flow_count_tmux" "$modedoctor_out" "modes.tmux-capable: 2"
assert_contains "doctor_flow_apps_ignored" "$modedoctor_out" "mode.chat.apps: 1 mapping(s) ignored (inline flow disabled)"
assert_contains "doctor_flow_invalid_entries" "$modedoctor_out" "mode.email.flows: hidden (explicit; invalid=voice)"
assert_contains "doctor_flow_fix_inline" "$modedoctor_out" "Enable inline flow for 'chat': tmux-whisper mode flows chat both"
assert_contains "doctor_flow_fix_tmux" "$modedoctor_out" "Enable tmux flow for 'base': tmux-whisper mode flows base both"
assert_contains "doctor_flow_fix_invalid" "$modedoctor_out" "Review flow filter for 'email': tmux-whisper mode flows email"

modedoctor_json="$(HOME="$MODEDOCTOR_HOME" PATH="$MODEDOCTOR_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODEDOCTOR_CFG" DICTATE_CONFIG_FILE="$MODEDOCTOR_CFG/config.toml" tmux-whisper doctor --json)"
assert_json_equals "doctor_flow_json_inline_status" "$modedoctor_json" "mode_config.inline.status" "flow_disabled"
assert_json_equals "doctor_flow_json_inline_allowed" "$modedoctor_json" "mode_config.inline.flow_allowed" "false"
assert_json_equals "doctor_flow_json_tmux_status" "$modedoctor_json" "mode_config.tmux.status" "flow_disabled"
assert_json_equals "doctor_flow_json_tmux_allowed" "$modedoctor_json" "mode_config.tmux.flow_allowed" "false"
assert_json_equals "doctor_flow_json_inline_count" "$modedoctor_json" "mode_config.available.inline_count" "1"
assert_json_equals "doctor_flow_json_tmux_count" "$modedoctor_json" "mode_config.available.tmux_count" "2"
assert_json_equals "doctor_flow_json_chat_mode" "$modedoctor_json" "mode_config.modes.1.mode" "chat"
assert_json_equals "doctor_flow_json_chat_apps_ignored" "$modedoctor_json" "mode_config.modes.1.apps.ignored" "true"
assert_json_equals "doctor_flow_json_email_mode" "$modedoctor_json" "mode_config.modes.3.mode" "email"
assert_json_equals "doctor_flow_json_email_invalid_entry" "$modedoctor_json" "mode_config.modes.3.flows.invalid_entries.0" "voice"

# --- Regression 6: postprocess commands clarify mode prompt inactivity when OFF. ---
modecheck_postprocess_off="$(HOME="$MODECHECK_HOME" PATH="$MODECHECK_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODECHECK_CFG" DICTATE_CONFIG_FILE="$MODECHECK_CFG/config.toml" tmux-whisper postprocess off)"
assert_contains "postprocess_off_prompt_note" "$modecheck_postprocess_off" "Mode prompt: inactive (postprocess OFF)"

modecheck_tmux_postprocess_off="$(HOME="$MODECHECK_HOME" PATH="$MODECHECK_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODECHECK_CFG" DICTATE_CONFIG_FILE="$MODECHECK_CFG/config.toml" tmux-whisper tmux postprocess off)"
assert_contains "tmux_postprocess_off_prompt_note" "$modecheck_tmux_postprocess_off" "tmux mode prompt: inactive (tmux postprocess OFF)"

# --- Regression 7: budget command UX uses budget profile naming. ---
modecheck_budget_show="$(HOME="$MODECHECK_HOME" PATH="$MODECHECK_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODECHECK_CFG" DICTATE_CONFIG_FILE="$MODECHECK_CFG/config.toml" tmux-whisper budget)"
assert_contains "budget_show_header" "$modecheck_budget_show" "Postprocess budget profiles"
assert_contains "budget_show_threshold" "$modecheck_budget_show" "auto_long_words_threshold:"
assert_contains "budget_show_dynamic_note" "$modecheck_budget_show" "auto_numeric_sizing: dynamic"

modecheck_budget_threshold="$(HOME="$MODECHECK_HOME" PATH="$MODECHECK_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$MODECHECK_CFG" DICTATE_CONFIG_FILE="$MODECHECK_CFG/config.toml" tmux-whisper budget threshold 42)"
assert_contains "budget_threshold_set" "$modecheck_budget_threshold" "budget auto_long_words_threshold: 42"

# --- Regression 8: integration scripts keep PATH-based command resolution. ---
assert_file_contains "raycast_inline_binary_resolution" "$ROOT/integrations/raycast/tmux-whisper-inline.sh" "command -v tmux-whisper"
assert_file_contains "raycast_inline_toggle_delegate" "$ROOT/integrations/raycast/tmux-whisper-inline.sh" 'inline toggle'
assert_file_contains "raycast_toggle_dictate_resolution" "$ROOT/integrations/raycast/tmux-whisper-toggle.sh" "command -v tmux-whisper"
assert_file_contains "swiftbar_dictate_resolution" "$ROOT/integrations/tmux-whisper-status.0.2s.sh" "command -v tmux-whisper"
assert_file_contains "raycast_inline_path_hardening" "$ROOT/integrations/raycast/tmux-whisper-inline.sh" "/usr/local/bin"
assert_file_contains "raycast_toggle_path_hardening" "$ROOT/integrations/raycast/tmux-whisper-toggle.sh" "/usr/local/bin"
assert_file_contains "raycast_cancel_path_hardening" "$ROOT/integrations/raycast/tmux-whisper-cancel.sh" "/usr/local/bin"
assert_file_contains "swiftbar_path_hardening" "$ROOT/integrations/tmux-whisper-status.0.2s.sh" "/usr/local/bin"
assert_file_contains "raycast_inline_binary_notice" "$ROOT/integrations/raycast/tmux-whisper-inline.sh" "Tmux Whisper binary not found."
assert_file_contains "raycast_toggle_binary_notice" "$ROOT/integrations/raycast/tmux-whisper-toggle.sh" "Tmux Whisper binary not found."
assert_file_contains "swiftbar_missing_binary_notice" "$ROOT/integrations/tmux-whisper-status.0.2s.sh" "Tmux Whisper binary not found | color=red"
assert_file_contains "swiftbar_enabled_config_parse" "$ROOT/integrations/tmux-whisper-status.0.2s.sh" "integrations.swiftbar.enabled"
assert_file_contains "raycast_inline_adapter_version_source" "$ROOT/integrations/raycast/tmux-whisper-inline.sh" "tmux-whisper.adapter-version: 1"
assert_file_contains "raycast_toggle_adapter_version_source" "$ROOT/integrations/raycast/tmux-whisper-toggle.sh" "tmux-whisper.adapter-version: 1"
assert_file_contains "raycast_cancel_adapter_version_source" "$ROOT/integrations/raycast/tmux-whisper-cancel.sh" "tmux-whisper.adapter-version: 1"
assert_file_contains "swiftbar_adapter_version_source" "$ROOT/integrations/tmux-whisper-status.0.2s.sh" "tmux-whisper.adapter-version: 2"

# --- Regression 8b: integration status inspects installed adapter paths. ---
INTEGRATIONS_HOME="$TMP_ROOT/home-integrations"
INTEGRATIONS_BIN="$INTEGRATIONS_HOME/.local/bin"
INTEGRATIONS_CFG="$INTEGRATIONS_HOME/.config/dictate"
INTEGRATIONS_SWIFTBAR="$INTEGRATIONS_HOME/.config/swiftbar/plugins"
mkdir -p "$INTEGRATIONS_BIN" "$INTEGRATIONS_CFG/integrations/raycast" "$INTEGRATIONS_SWIFTBAR"
install_test_runtime "$INTEGRATIONS_BIN"
cp "$ROOT/integrations/raycast/tmux-whisper-inline.sh" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
cp "$ROOT/integrations/raycast/tmux-whisper-toggle.sh" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-toggle.sh"
cp "$ROOT/integrations/raycast/tmux-whisper-cancel.sh" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-cancel.sh"
cp "$ROOT/integrations/tmux-whisper-status.0.2s.sh" "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
chmod +x "$INTEGRATIONS_CFG/integrations/raycast/"*.sh "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
cat >"$INTEGRATIONS_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[integrations.swiftbar]
enabled = false
EOF
cat >"$INTEGRATIONS_CFG/install-receipt.env" <<EOF
installed_at='2026-05-11T00:00:00Z'
install_source='test'
repo_git_ref='architecture-test'
repo_git_commit='abc123'
repo_root='$ROOT'
bin_path='$INTEGRATIONS_BIN/tmux-whisper'
config_dir='$INTEGRATIONS_CFG'
swiftbar_plugin='$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh'
EOF
integrations_text="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations)"
assert_contains "integrations_status_header" "$integrations_text" "Integrations:"
assert_contains "integrations_status_receipt" "$integrations_text" "install receipt: $INTEGRATIONS_CFG/install-receipt.env (present)"
assert_contains "integrations_status_swiftbar_off" "$integrations_text" "enabled: OFF"
assert_contains "integrations_status_swiftbar_path" "$integrations_text" "plugin: $INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh (executable)"
assert_contains "integrations_status_swiftbar_state" "$integrations_text" "plugin state: current"
assert_contains "integrations_status_swiftbar_version" "$integrations_text" "plugin version: 2 (source: 2)"
assert_contains "integrations_status_raycast_inline" "$integrations_text" "inline: $INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh (executable)"
assert_contains "integrations_status_raycast_inline_state" "$integrations_text" "inline state: current"
assert_contains "integrations_status_raycast_inline_version" "$integrations_text" "inline version: 1 (source: 1)"
assert_contains "integrations_status_source" "$integrations_text" "source: $ROOT"
assert_contains "integrations_status_next_doctor" "$integrations_text" "tmux-whisper integrations doctor"
integrations_json="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations --json)"
assert_json_equals "integrations_json_command" "$integrations_json" "command" "integrations"
assert_json_equals "integrations_json_source_root" "$integrations_json" "source.root" "$ROOT"
assert_json_equals "integrations_json_receipt_exists" "$integrations_json" "receipt.exists" "true"
assert_json_equals "integrations_json_receipt_ref" "$integrations_json" "receipt.repo_git_ref" "architecture-test"
assert_json_equals "integrations_json_swiftbar_enabled" "$integrations_json" "swiftbar.enabled" "false"
assert_json_equals "integrations_json_swiftbar_executable" "$integrations_json" "swiftbar.plugin.executable" "true"
assert_json_equals "integrations_json_swiftbar_state" "$integrations_json" "swiftbar.plugin.state" "current"
assert_json_equals "integrations_json_swiftbar_version" "$integrations_json" "swiftbar.plugin.version" "2"
assert_json_equals "integrations_json_swiftbar_source_version" "$integrations_json" "swiftbar.plugin.source_version" "2"
assert_json_equals "integrations_json_swiftbar_source" "$integrations_json" "swiftbar.plugin.source_path" "$ROOT/integrations/tmux-whisper-status.0.2s.sh"
assert_json_equals "integrations_json_raycast_inline" "$integrations_json" "raycast.scripts.0.name" "inline"
assert_json_equals "integrations_json_raycast_inline_executable" "$integrations_json" "raycast.scripts.0.executable" "true"
assert_json_equals "integrations_json_raycast_inline_state" "$integrations_json" "raycast.scripts.0.state" "current"
assert_json_equals "integrations_json_raycast_inline_version" "$integrations_json" "raycast.scripts.0.version" "1"
assert_json_equals "integrations_json_raycast_inline_source_version" "$integrations_json" "raycast.scripts.0.source_version" "1"
assert_json_equals "integrations_json_raycast_toggle_state" "$integrations_json" "raycast.scripts.1.state" "current"
assert_json_equals "integrations_json_raycast_toggle_version" "$integrations_json" "raycast.scripts.1.version" "1"
assert_json_equals "integrations_json_raycast_cancel_state" "$integrations_json" "raycast.scripts.2.state" "current"
assert_json_equals "integrations_json_raycast_cancel_version" "$integrations_json" "raycast.scripts.2.version" "1"
assert_json_equals "integrations_json_next_doctor" "$integrations_json" "next.0" "run tmux-whisper integrations doctor to diagnose adapter lifecycle drift"
integrations_doctor="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations doctor)"
assert_contains "integrations_doctor_header" "$integrations_doctor" "Integration doctor:"
assert_contains "integrations_doctor_ok" "$integrations_doctor" "status: ok (0 warnings)"
assert_contains "integrations_doctor_source" "$integrations_doctor" "source: $ROOT"
assert_contains "integrations_doctor_swiftbar" "$integrations_doctor" "plugin: $INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh (executable)"
assert_contains "integrations_doctor_swiftbar_state" "$integrations_doctor" "plugin state: current"
assert_contains "integrations_doctor_swiftbar_version" "$integrations_doctor" "plugin version: 2 (source: 2)"
assert_contains "integrations_doctor_raycast_inline_state" "$integrations_doctor" "inline state: current"
assert_contains "integrations_doctor_raycast_inline_version" "$integrations_doctor" "inline version: 1 (source: 1)"
assert_contains "integrations_doctor_next_repair" "$integrations_doctor" "tmux-whisper integrations repair --dry-run"
assert_contains "integrations_doctor_next_repair_apply" "$integrations_doctor" "tmux-whisper integrations repair"
integrations_repair_dry_run="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations repair --dry-run)"
assert_contains "integrations_repair_dry_run_header" "$integrations_repair_dry_run" "Integration repair dry run:"
assert_contains "integrations_repair_dry_run_no_mutation" "$integrations_repair_dry_run" "files changed: 0"
assert_contains "integrations_repair_dry_run_raycast_plan" "$integrations_repair_dry_run" "would install Raycast inline: $ROOT/integrations/raycast/tmux-whisper-inline.sh -> $INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
assert_contains "integrations_repair_dry_run_swiftbar_plan" "$integrations_repair_dry_run" "would install SwiftBar plugin: $ROOT/integrations/tmux-whisper-status.0.2s.sh -> $INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
chmod -x "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-cancel.sh"
integrations_doctor_raycast_nonexec="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations doctor)"
assert_contains "integrations_doctor_raycast_nonexec_status" "$integrations_doctor_raycast_nonexec" "status: needs repair"
assert_contains "integrations_doctor_raycast_nonexec_issue" "$integrations_doctor_raycast_nonexec" "Raycast cancel script is not executable"
assert_contains "integrations_doctor_raycast_nonexec_state" "$integrations_doctor_raycast_nonexec" "cancel state: non-executable"
chmod +x "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-cancel.sh"
printf '%s\n' "# stale raycast inline" >"$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
chmod +x "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
integrations_doctor_drift="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations doctor)"
assert_contains "integrations_doctor_drift_status" "$integrations_doctor_drift" "status: ok (1 warnings)"
assert_contains "integrations_doctor_drift_state" "$integrations_doctor_drift" "inline state: different"
assert_contains "integrations_doctor_drift_warning" "$integrations_doctor_drift" "Raycast inline script differs from source"
cp "$ROOT/integrations/raycast/tmux-whisper-inline.sh" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
chmod +x "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
rm -rf "$INTEGRATIONS_CFG/integrations/raycast"
printf '%s\n' "# stale swiftbar plugin" >"$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
chmod -x "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
integrations_doctor_broken="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations doctor)"
assert_contains "integrations_doctor_broken_status" "$integrations_doctor_broken" "status: needs repair"
assert_contains "integrations_doctor_broken_inline" "$integrations_doctor_broken" "Raycast inline script is missing"
assert_contains "integrations_doctor_broken_inline_state" "$integrations_doctor_broken" "inline state: missing"
assert_contains "integrations_doctor_broken_swiftbar" "$integrations_doctor_broken" "SwiftBar plugin is not executable"
assert_contains "integrations_doctor_broken_swiftbar_state" "$integrations_doctor_broken" "plugin state: non-executable"
integrations_repair_broken_dry_run="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations repair --dry-run)"
assert_contains "integrations_repair_broken_dry_run_no_mutation" "$integrations_repair_broken_dry_run" "files changed: 0"
assert_file_not_exists "integrations_repair_dry_run_missing_kept" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
assert_file_not_executable "integrations_repair_dry_run_mode_kept" "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
assert_file_contains "integrations_repair_dry_run_content_kept" "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh" "stale swiftbar"
integrations_repair_apply="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations repair)"
assert_contains "integrations_repair_apply_header" "$integrations_repair_apply" "Integration repair:"
assert_contains "integrations_repair_apply_changed" "$integrations_repair_apply" "files changed: 4"
assert_contains "integrations_repair_apply_inline" "$integrations_repair_apply" "changed Raycast inline: installed"
assert_contains "integrations_repair_apply_swiftbar_backup" "$integrations_repair_apply" "changed SwiftBar plugin: replaced"
assert_file_executable "integrations_repair_apply_inline_executable" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-inline.sh"
assert_file_executable "integrations_repair_apply_toggle_executable" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-toggle.sh"
assert_file_executable "integrations_repair_apply_cancel_executable" "$INTEGRATIONS_CFG/integrations/raycast/tmux-whisper-cancel.sh"
assert_file_executable "integrations_repair_apply_swiftbar_executable" "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh"
assert_glob_exists "integrations_repair_apply_swiftbar_backup" "$INTEGRATIONS_CFG/backups/integrations/tmux-whisper-status.0.2s.sh.*"
if compgen -G "$INTEGRATIONS_SWIFTBAR/tmux-whisper-status.0.2s.sh.*" >/dev/null; then
  echo "FAIL: integrations_repair_backup_outside_plugin_dir" >&2
  exit 1
fi
echo "PASS: integrations_repair_backup_outside_plugin_dir"
for backup in "$INTEGRATIONS_CFG"/backups/integrations/*; do
  assert_file_not_executable "integrations_repair_backup_not_executable" "$backup"
done
integrations_doctor_repaired="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations doctor)"
assert_contains "integrations_doctor_repaired_ok" "$integrations_doctor_repaired" "status: ok (0 warnings)"
integrations_repair_apply_again="$(HOME="$INTEGRATIONS_HOME" PATH="$INTEGRATIONS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$INTEGRATIONS_CFG" DICTATE_CONFIG_FILE="$INTEGRATIONS_CFG/config.toml" tmux-whisper integrations repair)"
assert_contains "integrations_repair_apply_idempotent" "$integrations_repair_apply_again" "files changed: 0"

# --- Regression 8c: Homebrew layout resolves adapter sources from pkgshare and
# ignores a stale local-install receipt; optional adapters are warnings only. ---
BREW_INT_HOME="$TMP_ROOT/home-brew-integrations"
BREW_INT_PREFIX="$BREW_INT_HOME/Cellar/tmux-whisper/0.7.0"
BREW_INT_BIN="$BREW_INT_HOME/bin"
BREW_INT_CFG="$BREW_INT_HOME/.config/dictate"
install_test_runtime "$BREW_INT_PREFIX/libexec"
mkdir -p "$BREW_INT_PREFIX/share/tmux-whisper" "$BREW_INT_BIN" "$BREW_INT_CFG"
cp -R "$ROOT/integrations" "$BREW_INT_PREFIX/share/tmux-whisper/integrations"
printf '#!/bin/bash\nexec "%s/libexec/tmux-whisper" "$@"\n' "$BREW_INT_PREFIX" >"$BREW_INT_BIN/tmux-whisper"
chmod +x "$BREW_INT_BIN/tmux-whisper"
printf '[meta]\nconfig_version = 1\n' >"$BREW_INT_CFG/config.toml"
cat >"$BREW_INT_CFG/install-receipt.env" <<EOF
install_source='local'
repo_root='$ROOT'
bin_path='$BREW_INT_HOME/.local/bin/tmux-whisper'
swiftbar_plugin='skipped'
EOF
brew_int_run() {
  HOME="$BREW_INT_HOME" PATH="$BREW_INT_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= \
    DICTATE_CONFIG_DIR="$BREW_INT_CFG" DICTATE_CONFIG_FILE="$BREW_INT_CFG/config.toml" tmux-whisper integrations "$@"
}
brew_int_share="$(cd "$BREW_INT_PREFIX/share/tmux-whisper" && pwd)"
brew_int_doctor="$(brew_int_run doctor)"
assert_contains "integrations_brew_source_pkgshare" "$brew_int_doctor" "source: $brew_int_share"
assert_not_contains "integrations_brew_ignores_stale_receipt_root" "$brew_int_doctor" "source: $ROOT"
assert_contains "integrations_brew_optional_missing_ok" "$brew_int_doctor" "status: ok"
assert_contains "integrations_brew_raycast_missing_warn" "$brew_int_doctor" "warn/raycast: Raycast inline script is missing"
assert_not_contains "integrations_brew_swiftbar_skipped_quiet" "$brew_int_doctor" "SwiftBar plugin is not installed"
brew_int_dry_run="$(brew_int_run repair --dry-run)"
assert_contains "integrations_brew_dry_run_skips_swiftbar" "$brew_int_dry_run" "would skip SwiftBar plugin"
brew_int_repair="$(brew_int_run repair)"
assert_contains "integrations_brew_repair_changed" "$brew_int_repair" "files changed: 3"
assert_contains "integrations_brew_repair_swiftbar_skipped" "$brew_int_repair" "unchanged SwiftBar plugin: skipped at install"
assert_file_executable "integrations_brew_repair_inline_installed" "$BREW_INT_CFG/integrations/raycast/tmux-whisper-inline.sh"
assert_file_not_exists "integrations_brew_repair_no_swiftbar" "$BREW_INT_HOME/.config/swiftbar/plugins/tmux-whisper-status.0.2s.sh"

# --- Regression 9: script-level behavior for missing tmux-whisper binary is explicit. ---
INLINE_HOME="$TMP_ROOT/home-inline"
mkdir -p "$INLINE_HOME"
rm -f /tmp/dictate-raycast-inline.log 2>/dev/null || true
HOME="$INLINE_HOME" PATH="$STUB_BIN:/usr/bin:/bin" DICTATE_BIN="$TMP_ROOT/not-found-dictate" bash "$ROOT/integrations/raycast/tmux-whisper-inline.sh" >/dev/null 2>&1 || true
assert_file_contains "raycast_inline_missing_binary_runtime" "/tmp/dictate-raycast-inline.log" "ERROR: Tmux Whisper binary not found."

TOGGLE_HOME="$TMP_ROOT/home-toggle"
mkdir -p "$TOGGLE_HOME"
toggle_out="$(HOME="$TOGGLE_HOME" PATH="$STUB_BIN:/usr/bin:/bin" DICTATE_BIN="$TMP_ROOT/not-found-dictate" bash "$ROOT/integrations/raycast/tmux-whisper-toggle.sh" 2>&1 || true)"
assert_contains "raycast_toggle_missing_binary_runtime" "$toggle_out" "tmux-whisper-toggle: Tmux Whisper binary not found."

RAYCAST_REFRESH_HOME="$TMP_ROOT/home-raycast-refresh"
RAYCAST_REFRESH_BIN="$RAYCAST_REFRESH_HOME/.local/bin"
RAYCAST_REFRESH_LOG="$TMP_ROOT/raycast-refresh.log"
mkdir -p "$RAYCAST_REFRESH_BIN" "$RAYCAST_REFRESH_HOME/.config"
cat >"$RAYCAST_REFRESH_BIN/tmux-whisper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DICTATE_TEST_RAYCAST_REFRESH_LOG:?}"
exit 0
EOF
chmod +x "$RAYCAST_REFRESH_BIN/tmux-whisper"
HOME="$RAYCAST_REFRESH_HOME" PATH="$RAYCAST_REFRESH_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_BIN="$RAYCAST_REFRESH_BIN/tmux-whisper" DICTATE_TEST_RAYCAST_REFRESH_LOG="$RAYCAST_REFRESH_LOG" bash "$ROOT/integrations/raycast/tmux-whisper-inline.sh" >/dev/null 2>&1
assert_file_contains "raycast_inline_uses_cli_refresh" "$RAYCAST_REFRESH_LOG" "swiftbar refresh"

RAYCAST_CANCEL_STATE="$TMP_ROOT/raycast-cancel-inline.state"
printf 'pid=\nwav=%q\n' "$TMP_ROOT/raycast-cancel.wav" >"$RAYCAST_CANCEL_STATE"
HOME="$RAYCAST_REFRESH_HOME" PATH="$RAYCAST_REFRESH_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_BIN="$RAYCAST_REFRESH_BIN/tmux-whisper" DICTATE_INLINE_STATE_FILE="$RAYCAST_CANCEL_STATE" DICTATE_STATE_FILE="$TMP_ROOT/raycast-cancel-tmux.state" DICTATE_CANCEL_FLAG="$TMP_ROOT/raycast-cancel.flag" DICTATE_PROCESSING_DIR="$TMP_ROOT/raycast-processing" DICTATE_TEST_RAYCAST_REFRESH_LOG="$RAYCAST_REFRESH_LOG" bash "$ROOT/integrations/raycast/tmux-whisper-cancel.sh" >/dev/null 2>&1 || true
assert_file_contains "raycast_cancel_uses_cli_refresh" "$RAYCAST_REFRESH_LOG" "swiftbar refresh"

SWIFTBAR_HOME="$TMP_ROOT/home-swiftbar"
mkdir -p "$SWIFTBAR_HOME"
swiftbar_out="$(HOME="$SWIFTBAR_HOME" PATH="$STUB_BIN:/usr/bin:/bin" DICTATE_BIN="$TMP_ROOT/not-found-dictate" DICTATE_STATE_FILE="$SWIFTBAR_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_missing_binary_runtime" "$swiftbar_out" "Tmux Whisper binary not found"

IDLE_STOP_HOME="$TMP_ROOT/home-idle-stop"
IDLE_STOP_BIN="$IDLE_STOP_HOME/.local/bin"
IDLE_STOP_CFG="$IDLE_STOP_HOME/.config/dictate"
mkdir -p "$IDLE_STOP_BIN" "$IDLE_STOP_CFG"
install_test_runtime "$IDLE_STOP_BIN"
cat >"$IDLE_STOP_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$IDLE_STOP_BIN/tmux"
cat >"$IDLE_STOP_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[integrations.swiftbar]
enabled = true
EOF

idle_stop_out="$(HOME="$IDLE_STOP_HOME" PATH="$IDLE_STOP_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$IDLE_STOP_CFG" DICTATE_CONFIG_FILE="$IDLE_STOP_CFG/config.toml" DICTATE_STATE_FILE="$IDLE_STOP_HOME/tmux.state" DICTATE_INLINE_STATE_FILE="$IDLE_STOP_HOME/inline.state" DICTATE_ERROR_FLAG="$IDLE_STOP_HOME/error.flag" DICTATE_SWIFTBAR_REFRESH_LOG="$IDLE_STOP_HOME/refresh.log" tmux-whisper stop 2>&1 || true)"
assert_contains "idle_tmux_stop_reports_not_recording" "$idle_stop_out" "not recording. Run: tmux-whisper start"
assert_file_not_exists "idle_tmux_stop_no_error_flag" "$IDLE_STOP_HOME/error.flag"
assert_file_not_exists "idle_tmux_stop_no_swiftbar_refresh" "$IDLE_STOP_HOME/refresh.log"

idle_inline_stop_out="$(HOME="$IDLE_STOP_HOME" PATH="$IDLE_STOP_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$IDLE_STOP_CFG" DICTATE_CONFIG_FILE="$IDLE_STOP_CFG/config.toml" DICTATE_STATE_FILE="$IDLE_STOP_HOME/tmux.state" DICTATE_INLINE_STATE_FILE="$IDLE_STOP_HOME/inline.state" DICTATE_ERROR_FLAG="$IDLE_STOP_HOME/error.flag" DICTATE_SWIFTBAR_REFRESH_LOG="$IDLE_STOP_HOME/refresh.log" tmux-whisper inline stop 2>&1 || true)"
assert_contains "idle_inline_stop_reports_not_recording" "$idle_inline_stop_out" "not recording. Run: tmux-whisper inline start"
assert_file_not_exists "idle_inline_stop_no_error_flag" "$IDLE_STOP_HOME/error.flag"
assert_file_not_exists "idle_inline_stop_no_swiftbar_refresh" "$IDLE_STOP_HOME/refresh.log"

# Lifecycle refreshes are skipped when the SwiftBar integration is disabled,
# while an explicit `swiftbar refresh` still requests one.
GATED_REFRESH_LOG="$IDLE_STOP_HOME/gated-refresh.log"
CFG_SWIFTBAR_ENABLED=0 DICTATE_SWIFTBAR_REFRESH_LOG="$GATED_REFRESH_LOG" \
  bash -c 'source "$1"; swiftbar_refresh' _ "$ROOT/bin/tmux-whisper-lib/integrations.sh"
assert_file_not_exists "swiftbar_refresh_disabled_noop" "$GATED_REFRESH_LOG"
CFG_SWIFTBAR_ENABLED=1 DICTATE_SWIFTBAR_REFRESH_LOG="$GATED_REFRESH_LOG" \
  bash -c 'source "$1"; swiftbar_refresh' _ "$ROOT/bin/tmux-whisper-lib/integrations.sh"
assert_file_contains "swiftbar_refresh_enabled_requests" "$GATED_REFRESH_LOG" "refresh plugin=tmux-whisper-status.0.2s.sh"
rm -f "$GATED_REFRESH_LOG"
CFG_SWIFTBAR_ENABLED=0 DICTATE_SWIFTBAR_REFRESH_LOG="$GATED_REFRESH_LOG" \
  bash -c 'source "$1"; swiftbar_refresh_now' _ "$ROOT/bin/tmux-whisper-lib/integrations.sh"
assert_file_contains "swiftbar_refresh_now_ignores_toggle" "$GATED_REFRESH_LOG" "refresh plugin=tmux-whisper-status.0.2s.sh"

# A freshly truncated marker can be an active writer between open and publish.
# Doctor must leave it alone so the recording control is not lost.
PENDING_INLINE_STATE="$IDLE_STOP_HOME/pending-inline.state"
: >"$PENDING_INLINE_STATE"
pending_state_doctor_json="$(HOME="$IDLE_STOP_HOME" PATH="$IDLE_STOP_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$IDLE_STOP_CFG" DICTATE_CONFIG_FILE="$IDLE_STOP_CFG/config.toml" DICTATE_STATE_FILE="$IDLE_STOP_HOME/tmux.state" DICTATE_INLINE_STATE_FILE="$PENDING_INLINE_STATE" DICTATE_PROCESSING_DIR="$IDLE_STOP_HOME/dictate-processing" DICTATE_TMUX_JOBS_DIR="$IDLE_STOP_HOME/dictate-tmux-jobs" tmux-whisper doctor --json)"
assert_json_equals "doctor_fresh_incomplete_state_pending" "$pending_state_doctor_json" "state_files.inline.state" "pending"
assert_file_exists "doctor_fresh_incomplete_state_preserved" "$PENDING_INLINE_STATE"

# Exercise the race directly: a concurrent status read must not remove the
# marker between a legacy writer's truncation and its atomic replacement.
CONCURRENT_INLINE_STATE="$IDLE_STOP_HOME/concurrent-inline.state"
CONCURRENT_STATE_SEEN="$IDLE_STOP_HOME/concurrent-state-seen"
: >"$CONCURRENT_INLINE_STATE"
(
  sleep 0.15
  [[ -f "$CONCURRENT_INLINE_STATE" ]] && : >"$CONCURRENT_STATE_SEEN"
  printf 'pid=%s\n' "$$" >"${CONCURRENT_INLINE_STATE}.tmp"
  mv -f "${CONCURRENT_INLINE_STATE}.tmp" "$CONCURRENT_INLINE_STATE"
) &
concurrent_writer_pid="$!"
while kill -0 "$concurrent_writer_pid" 2>/dev/null; do
  HOME="$IDLE_STOP_HOME" PATH="$IDLE_STOP_BIN:$STUB_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$IDLE_STOP_CFG" DICTATE_CONFIG_FILE="$IDLE_STOP_CFG/config.toml" DICTATE_STATE_FILE="$IDLE_STOP_HOME/tmux.state" DICTATE_INLINE_STATE_FILE="$CONCURRENT_INLINE_STATE" DICTATE_PROCESSING_DIR="$IDLE_STOP_HOME/dictate-processing" DICTATE_TMUX_JOBS_DIR="$IDLE_STOP_HOME/dictate-tmux-jobs" tmux-whisper status --json >/dev/null
done
wait "$concurrent_writer_pid"
assert_file_exists "status_concurrent_state_not_pruned_before_publish" "$CONCURRENT_STATE_SEEN"
assert_file_contains "status_concurrent_state_published" "$CONCURRENT_INLINE_STATE" "pid=$$"

# --- Regression 10: SwiftBar runtime integration toggle works end-to-end. ---
SWIFTBAR_TOGGLE_HOME="$TMP_ROOT/home-swiftbar-toggle"
SWIFTBAR_TOGGLE_BIN="$SWIFTBAR_TOGGLE_HOME/.local/bin"
SWIFTBAR_TOGGLE_CFG="$SWIFTBAR_TOGGLE_HOME/.config/dictate"
mkdir -p "$SWIFTBAR_TOGGLE_BIN" "$SWIFTBAR_TOGGLE_CFG"
install_test_runtime "$SWIFTBAR_TOGGLE_BIN"
cat >"$SWIFTBAR_TOGGLE_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[integrations.swiftbar]
enabled = false
EOF

swiftbar_show_off="$(HOME="$SWIFTBAR_TOGGLE_HOME" PATH="$SWIFTBAR_TOGGLE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$SWIFTBAR_TOGGLE_CFG" DICTATE_CONFIG_FILE="$SWIFTBAR_TOGGLE_CFG/config.toml" tmux-whisper swiftbar)"
assert_contains "swiftbar_cli_show_off" "$swiftbar_show_off" "SwiftBar integration: OFF"

swiftbar_cli_on="$(HOME="$SWIFTBAR_TOGGLE_HOME" PATH="$SWIFTBAR_TOGGLE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$SWIFTBAR_TOGGLE_CFG" DICTATE_CONFIG_FILE="$SWIFTBAR_TOGGLE_CFG/config.toml" tmux-whisper swiftbar on)"
assert_contains "swiftbar_cli_on" "$swiftbar_cli_on" "SwiftBar integration: ON"

swiftbar_cli_toggle="$(HOME="$SWIFTBAR_TOGGLE_HOME" PATH="$SWIFTBAR_TOGGLE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$SWIFTBAR_TOGGLE_CFG" DICTATE_CONFIG_FILE="$SWIFTBAR_TOGGLE_CFG/config.toml" tmux-whisper swiftbar toggle)"
assert_contains "swiftbar_cli_toggle" "$swiftbar_cli_toggle" "SwiftBar integration: OFF"

swiftbar_toggle_out="$(HOME="$SWIFTBAR_TOGGLE_HOME" XDG_CONFIG_HOME="$SWIFTBAR_TOGGLE_HOME/.config" PATH="$SWIFTBAR_TOGGLE_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_TOGGLE_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_TOGGLE_BIN/tmux-whisper" DICTATE_STATE_FILE="$SWIFTBAR_TOGGLE_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_TOGGLE_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_TOGGLE_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_TOGGLE_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_TOGGLE_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_TOGGLE_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_TOGGLE_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_plugin_off_state" "$swiftbar_toggle_out" "SwiftBar integration: OFF"
assert_contains "swiftbar_plugin_off_enable_action" "$swiftbar_toggle_out" "Enable SwiftBar integration"

# --- Regression 11: SwiftBar mode menus are folder-driven and respect flow filters. ---
SWIFTBAR_MODES_HOME="$TMP_ROOT/home-swiftbar-modes"
SWIFTBAR_MODES_BIN="$SWIFTBAR_MODES_HOME/.local/bin"
SWIFTBAR_MODES_CFG="$SWIFTBAR_MODES_HOME/.config/dictate"
mkdir -p "$SWIFTBAR_MODES_BIN" "$SWIFTBAR_MODES_CFG/modes/base" "$SWIFTBAR_MODES_CFG/modes/code" "$SWIFTBAR_MODES_CFG/modes/email" "$SWIFTBAR_MODES_CFG/modes/long"
install_test_runtime "$SWIFTBAR_MODES_BIN"
cat >"$SWIFTBAR_MODES_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[integrations.swiftbar]
enabled = true

[ui.icons]
email = ""
EOF
printf '%s\n' "auto" >"$SWIFTBAR_MODES_CFG/current-mode"
printf '%s\n' "Context: base mode." >"$SWIFTBAR_MODES_CFG/modes/base/prompt"
printf '%s\n' "inline" >"$SWIFTBAR_MODES_CFG/modes/base/flows"
printf '%s\n' "Context: code mode." >"$SWIFTBAR_MODES_CFG/modes/code/prompt"
printf '%s\n' "tmux" "inline" >"$SWIFTBAR_MODES_CFG/modes/code/flows"
printf '%s\n' "Context: email mode." >"$SWIFTBAR_MODES_CFG/modes/email/prompt"
printf '%s\n' "Mail" >"$SWIFTBAR_MODES_CFG/modes/email/apps"
printf '%s\n' "inline" >"$SWIFTBAR_MODES_CFG/modes/email/flows"
printf '%s\n' "Context: long mode." >"$SWIFTBAR_MODES_CFG/modes/long/prompt"
printf '%s\n' "inline" >"$SWIFTBAR_MODES_CFG/modes/long/flows"

swiftbar_modes_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
swiftbar_modes_first_line="$(printf '%s\n' "$swiftbar_modes_out" | sed -n '1p')"
assert_equals "swiftbar_inline_blank_mode_icon_ready_line" "$swiftbar_modes_first_line" "🎙️"
assert_contains "swiftbar_inline_mode_auto_display" "$swiftbar_modes_out" "Mode: email"
assert_not_contains "swiftbar_inline_menu_auto_hidden" "$swiftbar_modes_out" "param1=mode param2=auto"
assert_not_contains "swiftbar_inline_menu_email_hidden" "$swiftbar_modes_out" "param1=mode param2=email"
assert_contains "swiftbar_inline_process_sound_present" "$swiftbar_modes_out" "param1=inline param2=process-sound"
assert_contains "swiftbar_tmux_menu_code" "$swiftbar_modes_out" "param1=tmux param2=mode param3=code"
assert_not_contains "swiftbar_tmux_menu_email_hidden" "$swiftbar_modes_out" "param1=tmux param2=mode param3=email"
assert_not_contains "swiftbar_tmux_menu_long_hidden" "$swiftbar_modes_out" "param1=tmux param2=mode param3=long"
assert_not_contains "swiftbar_inline_model_menu_removed" "$swiftbar_modes_out" "param1=model"
assert_not_contains "swiftbar_tmux_model_menu_removed" "$swiftbar_modes_out" "param2=model param3="
assert_not_contains "swiftbar_inline_silence_trim_removed" "$swiftbar_modes_out" "Silence trim:"
assert_contains "swiftbar_inline_repeats_present" "$swiftbar_modes_out" "Repeats level"
assert_contains "swiftbar_inline_repeats_action" "$swiftbar_modes_out" "param1=repeats param2=1"
assert_not_contains "swiftbar_inline_backend_removed" "$swiftbar_modes_out" "Backend:"

mkdir -p "$SWIFTBAR_MODES_HOME/dictate-processing"
printf 'pid=%s\nkind=inline\n' "$$" >"$SWIFTBAR_MODES_HOME/dictate-processing/inline-test"
swiftbar_processing_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_inline_processing_marker_state" "$swiftbar_processing_out" "Processing (1)"
rm -f "$SWIFTBAR_MODES_HOME/dictate-processing/inline-test"
# Lowkey's markers span the whole take: only queued/processing count, and a
# take handed to the CLI (phase=cli) is counted by the CLI's own marker.
for lowkey_phase in recording queued processing cli; do
  printf 'pid=%s\nkind=inline\nsession_id=%s\nphase=%s\n' "$$" "$lowkey_phase" "$lowkey_phase" \
    >"$SWIFTBAR_MODES_HOME/dictate-processing/inline-lowkey-$lowkey_phase"
done
swiftbar_lowkey_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_lowkey_counts_processing_phases" "$swiftbar_lowkey_out" "Processing (2)"
rm -f "$SWIFTBAR_MODES_HOME/dictate-processing"/inline-lowkey-*
assert_contains "swiftbar_tmux_target_present" "$swiftbar_modes_out" "param1=tmux param2=target"

touch "$SWIFTBAR_MODES_HOME/stale.wav"
printf 'pid=999999\nwav=%q\n' "$SWIFTBAR_MODES_HOME/stale.wav" >"$SWIFTBAR_MODES_HOME/swiftbar-inline.state"
touch -t 202001010000 "$SWIFTBAR_MODES_HOME/swiftbar-inline.state" 2>/dev/null || true
swiftbar_stale_recording_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_stale_recording_ready" "$swiftbar_stale_recording_out" "Ready"
assert_file_not_exists "swiftbar_stale_recording_cleaned" "$SWIFTBAR_MODES_HOME/swiftbar-inline.state"
assert_file_exists "swiftbar_stale_recording_wav_preserved" "$SWIFTBAR_MODES_HOME/stale.wav"

printf 'pid=%s\n' "$$" >"$SWIFTBAR_MODES_HOME/swiftbar-inline.state"
touch "$SWIFTBAR_MODES_HOME/dictate-error.flag"
swiftbar_live_recording_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_ERROR_FLAG="$SWIFTBAR_MODES_HOME/dictate-error.flag" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_live_recording_precedes_recent_error" "$swiftbar_live_recording_out" "Recording..."
assert_not_contains "swiftbar_live_recording_hides_recent_error" "$swiftbar_live_recording_out" "Error occurred"
rm -f "$SWIFTBAR_MODES_HOME/swiftbar-inline.state" "$SWIFTBAR_MODES_HOME/dictate-error.flag"

mkdir -p "$SWIFTBAR_MODES_HOME/dictate-processing"
printf 'pid=999999\nkind=inline\n' >"$SWIFTBAR_MODES_HOME/dictate-processing/inline-stale"
touch "$SWIFTBAR_MODES_HOME/dictate-cancelled.flag"
swiftbar_cancel_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_recent_cancel_visible" "$swiftbar_cancel_out" "Cancelled"
touch -t 202001010000 "$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" "$SWIFTBAR_MODES_HOME/dictate-just-processed" 2>/dev/null || true
swiftbar_stale_marker_out="$(HOME="$SWIFTBAR_MODES_HOME" XDG_CONFIG_HOME="$SWIFTBAR_MODES_HOME/.config" PATH="$SWIFTBAR_MODES_BIN:$STUB_BIN:/usr/bin:/bin" SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_MODES_HOME/.cache/swiftbar" DICTATE_BIN="$SWIFTBAR_MODES_BIN/tmux-whisper" DICTATE_TEST_FRONT_APP=Mail DICTATE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar.state" DICTATE_INLINE_STATE_FILE="$SWIFTBAR_MODES_HOME/swiftbar-inline.state" DICTATE_PROCESSING_DIR="$SWIFTBAR_MODES_HOME/dictate-processing" DICTATE_PROCESSED_FLAG="$SWIFTBAR_MODES_HOME/dictate-just-processed" DICTATE_CANCEL_FLAG="$SWIFTBAR_MODES_HOME/dictate-cancelled.flag" DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_MODES_HOME/dictate-inline-processing-long.flag" DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_MODES_HOME/dictate-tmux-jobs" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_stale_processing_ready" "$swiftbar_stale_marker_out" "Ready"
assert_file_not_exists "swiftbar_stale_processing_cleaned" "$SWIFTBAR_MODES_HOME/dictate-processing/inline-stale"
assert_file_not_exists "swiftbar_old_cancel_cleaned" "$SWIFTBAR_MODES_HOME/dictate-cancelled.flag"
assert_file_not_exists "swiftbar_old_processed_cleaned" "$SWIFTBAR_MODES_HOME/dictate-just-processed"

# --- Regression 12: SwiftBar consumes cached stable CLI usage JSON. ---
SWIFTBAR_USAGE_HOME="$TMP_ROOT/home-swiftbar-usage"
SWIFTBAR_USAGE_BIN="$SWIFTBAR_USAGE_HOME/.local/bin"
SWIFTBAR_USAGE_CFG="$SWIFTBAR_USAGE_HOME/.config/dictate"
SWIFTBAR_USAGE_CACHE="$SWIFTBAR_USAGE_HOME/.cache/swiftbar"
SWIFTBAR_USAGE_CALL_LOG="$SWIFTBAR_USAGE_HOME/usage-calls.log"
SWIFTBAR_USAGE_JSON="$SWIFTBAR_USAGE_HOME/usage-response.json"
mkdir -p "$SWIFTBAR_USAGE_BIN" "$SWIFTBAR_USAGE_CFG" "$SWIFTBAR_USAGE_CACHE"
cat >"$SWIFTBAR_USAGE_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[integrations.swiftbar]
enabled = true
EOF
cat >"$SWIFTBAR_USAGE_BIN/tmux-whisper" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "usage" && "${2:-}" == "--json" ]]; then
  printf 'usage\n' >>"${DICTATE_USAGE_CALL_LOG:?}"
  cat "${DICTATE_USAGE_STUB_JSON:?}"
  exit 0
fi
exit 1
EOF
chmod +x "$SWIFTBAR_USAGE_BIN/tmux-whisper"
cat >"$SWIFTBAR_USAGE_JSON" <<'EOF'
{"command":"usage","schema_version":1,"coverage":{"status":"active","tracking_started_at":"2026-09-17T09:00:00Z"},"delivered_dictations":{"count":4},"processed_words":1234,"estimated_time_difference_ms":150000}
EOF
swiftbar_usage_env=(
  HOME="$SWIFTBAR_USAGE_HOME"
  XDG_CONFIG_HOME="$SWIFTBAR_USAGE_HOME/.config"
  PATH="$SWIFTBAR_USAGE_BIN:$STUB_BIN:/usr/bin:/bin"
  SWIFTBAR_PLUGIN_CACHE_PATH="$SWIFTBAR_USAGE_CACHE"
  DICTATE_BIN="$SWIFTBAR_USAGE_BIN/tmux-whisper"
  DICTATE_INTERNAL_LIB_DIR="$ROOT/bin/tmux-whisper-lib"
  DICTATE_USAGE_CALL_LOG="$SWIFTBAR_USAGE_CALL_LOG"
  DICTATE_USAGE_STUB_JSON="$SWIFTBAR_USAGE_JSON"
  DICTATE_USAGE_SUMMARY_FILE="$SWIFTBAR_USAGE_HOME/usage.json"
  DICTATE_STATE_FILE="$SWIFTBAR_USAGE_HOME/tmux.state"
  DICTATE_INLINE_STATE_FILE="$SWIFTBAR_USAGE_HOME/inline.state"
  DICTATE_PROCESSING_DIR="$SWIFTBAR_USAGE_HOME/dictate-processing"
  DICTATE_PROCESSED_FLAG="$SWIFTBAR_USAGE_HOME/dictate-just-processed"
  DICTATE_CANCEL_FLAG="$SWIFTBAR_USAGE_HOME/dictate-cancelled.flag"
  DICTATE_PROCESSING_LONG_FLAG="$SWIFTBAR_USAGE_HOME/dictate-inline-processing-long.flag"
  DICTATE_TMUX_JOBS_DIR="$SWIFTBAR_USAGE_HOME/dictate-tmux-jobs"
)
swiftbar_usage_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_words" "$swiftbar_usage_out" "Usage (tracked): 1234 words · 4 deliveries"
assert_contains "swiftbar_usage_tracking_period" "$swiftbar_usage_out" "Tracking since: 2026-09-17T09:00:00Z"
assert_contains "swiftbar_usage_labeled_difference" "$swiftbar_usage_out" "Estimated typing-time difference: +2m 30s (typing - dictation)"
assert_file_contains "swiftbar_usage_cli_contract_called" "$SWIFTBAR_USAGE_CALL_LOG" "usage"
assert_file_exists "swiftbar_config_private_cache_created" "$SWIFTBAR_USAGE_CACHE/dictate-config.cache"
assert_file_exists "swiftbar_usage_private_cache_created" "$SWIFTBAR_USAGE_CACHE/tmux-whisper-usage.cache"
swiftbar_cache_mode="$(stat -c '%a' "$SWIFTBAR_USAGE_CACHE" 2>/dev/null || stat -f '%Lp' "$SWIFTBAR_USAGE_CACHE" 2>/dev/null)"
assert_equals "swiftbar_sourced_caches_private_permissions" "$swiftbar_cache_mode" "700"
swiftbar_usage_cached_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_cache_keeps_menu" "$swiftbar_usage_cached_out" "Usage (tracked): 1234 words"
usage_call_count="$(wc -l <"$SWIFTBAR_USAGE_CALL_LOG" | tr -d ' ')"
assert_equals "swiftbar_usage_cache_avoids_hot_path_cli" "$usage_call_count" "1"

# A cache file left behind from a formerly shared directory must never be
# sourced. The plugin ignores it and atomically replaces it with a regular,
# private cache file after reading the CLI contract again.
printf '%s\n' 'USAGE_MENU_STATE=not_started' >"$SWIFTBAR_USAGE_HOME/untrusted-cache"
ln -sf "$SWIFTBAR_USAGE_HOME/untrusted-cache" "$SWIFTBAR_USAGE_CACHE/tmux-whisper-usage.cache"
swiftbar_usage_symlink_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_symlink_not_sourced" "$swiftbar_usage_symlink_out" "Usage (tracked): 1234 words"
assert_not_symlink "swiftbar_usage_symlink_replaced" "$SWIFTBAR_USAGE_CACHE/tmux-whisper-usage.cache"
usage_call_count="$(wc -l <"$SWIFTBAR_USAGE_CALL_LOG" | tr -d ' ')"
assert_equals "swiftbar_usage_symlink_refreshes_contract" "$usage_call_count" "2"

# Atomic usage-ledger replacements can share a whole-second mtime and byte
# length. The inode in the cache signature still makes the new total visible.
printf '%s' 'old' >"$SWIFTBAR_USAGE_HOME/usage.json"
touch -t 202609170900 "$SWIFTBAR_USAGE_HOME/usage.json"
swiftbar_usage_ledger_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_ledger_first_signature" "$swiftbar_usage_ledger_out" "Usage (tracked): 1234 words"
printf '%s' 'new' >"$SWIFTBAR_USAGE_HOME/usage.json.replacement"
touch -t 202609170900 "$SWIFTBAR_USAGE_HOME/usage.json.replacement"
mv -f "$SWIFTBAR_USAGE_HOME/usage.json.replacement" "$SWIFTBAR_USAGE_HOME/usage.json"
swiftbar_usage_ledger_replaced_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_ledger_same_tick_replaced" "$swiftbar_usage_ledger_replaced_out" "Usage (tracked): 1234 words"
usage_call_count="$(wc -l <"$SWIFTBAR_USAGE_CALL_LOG" | tr -d ' ')"
assert_equals "swiftbar_usage_ledger_inode_invalidates_cache" "$usage_call_count" "4"

# The just-processed handoff bypasses the cache so an event refresh reports a
# newly completed dictation immediately, even inside the normal cache window.
touch "$SWIFTBAR_USAGE_HOME/dictate-just-processed"
swiftbar_usage_fresh_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_post_delivery_refresh" "$swiftbar_usage_fresh_out" "Usage (tracked): 1234 words"
usage_call_count="$(wc -l <"$SWIFTBAR_USAGE_CALL_LOG" | tr -d ' ')"
assert_equals "swiftbar_usage_post_delivery_bypasses_cache" "$usage_call_count" "5"
# A cache-directory write is unrelated to the usage ledger or completion
# marker. It must not alter their signatures and force another CLI read.
printf '%s\n' 'unrelated cache write' >"$SWIFTBAR_USAGE_CACHE/unrelated-cache-file"
swiftbar_usage_post_delivery_cached_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_post_delivery_cache_keeps_menu" "$swiftbar_usage_post_delivery_cached_out" "Usage (tracked): 1234 words"
usage_call_count="$(wc -l <"$SWIFTBAR_USAGE_CALL_LOG" | tr -d ' ')"
assert_equals "swiftbar_usage_unrelated_cache_write_keeps_completion_cache" "$usage_call_count" "5"

# Missing and malformed summaries are non-fatal and leave the rest of the
# ready-state controls visible. A failed refresh must replace older cached
# metrics, and is briefly cached so polling does not hammer the CLI.
printf '%s\n' '{"command":"usage","schema_version":1,"coverage":{"status":"future"},"delivered_dictations":{"count":true},"processed_words":1.5,"estimated_time_difference_ms":0}' >"$SWIFTBAR_USAGE_JSON"
touch "$SWIFTBAR_USAGE_HOME/usage.json"
swiftbar_usage_bad_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_malformed_nonfatal" "$swiftbar_usage_bad_out" "Usage summary unavailable (will retry)"
assert_contains "swiftbar_usage_malformed_keeps_controls" "$swiftbar_usage_bad_out" "Inline"
swiftbar_usage_bad_cached_out="$(env "${swiftbar_usage_env[@]}" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
assert_contains "swiftbar_usage_failure_cache_keeps_fallback" "$swiftbar_usage_bad_cached_out" "Usage summary unavailable (will retry)"
usage_call_count="$(wc -l <"$SWIFTBAR_USAGE_CALL_LOG" | tr -d ' ')"
assert_equals "swiftbar_usage_failure_cache_avoids_hot_path_cli" "$usage_call_count" "6"

# --- Regression 13: budget profile auto-selection is based on transcript length, not mode name. ---
BUDGET_HOME="$TMP_ROOT/home-budget"
BUDGET_BIN="$BUDGET_HOME/.local/bin"
BUDGET_CFG="$BUDGET_HOME/.config/dictate"
BUDGET_STUBS="$TMP_ROOT/budget-stubs"
mkdir -p "$BUDGET_BIN" "$BUDGET_CFG/modes/code" "$BUDGET_CFG/modes/long" "$BUDGET_STUBS"
install_test_runtime "$BUDGET_BIN"
cat >"$BUDGET_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"

[postprocess]
llm = "gpt-oss-120b"
max_tokens = 1111
chunk_words = 0

[postprocess.budget_profiles.short]
max_tokens = 2222
chunk_words = 0

[postprocess.budget_profiles.long]
max_tokens = 5555
chunk_words = 0
EOF
printf '%s\n' "Context: code mode." >"$BUDGET_CFG/modes/code/prompt"
printf '%s\n' "Context: long mode." >"$BUDGET_CFG/modes/long/prompt"

cat >"$BUDGET_STUBS/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      payload="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -n "${DICTATE_TEST_CURL_DUMP:-}" ]]; then
  printf '%s' "$payload" >"$DICTATE_TEST_CURL_DUMP"
fi
printf '%s\n' '{"choices":[{"message":{"content":"processed"}}]}'
EOF
chmod +x "$BUDGET_STUBS/curl"

cat >"$BUDGET_STUBS/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-Rs" && "${2:-}" == "." ]]; then
  python3 - <<'PY'
import json, sys
print(json.dumps(sys.stdin.read()))
PY
  exit 0
fi
if [[ "${1:-}" == "-r" ]]; then
  filter="${2:-}"
  python3 - "$filter" <<'PY'
import json, sys
flt = sys.argv[1]
raw = sys.stdin.read().strip()
if not raw:
    print("")
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
if flt == '.choices[0].message.content // empty':
    out = ""
    try:
        out = data["choices"][0]["message"]["content"] or ""
    except Exception:
        out = ""
    print(out)
    raise SystemExit(0)
if flt == '.error.message // .error // empty':
    err = data.get("error", "")
    if isinstance(err, dict):
        print(err.get("message", "") or "")
    elif isinstance(err, str):
        print(err)
    else:
        print("")
    raise SystemExit(0)
print("")
PY
  exit 0
fi
exit 1
EOF
chmod +x "$BUDGET_STUBS/jq"

cat >"$BUDGET_STUBS/pbcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
EOF
chmod +x "$BUDGET_STUBS/pbcopy"

BUDGET_CURL_DUMP="$TMP_ROOT/budget-curl.json"
BUDGET_CURL_DUMP_SHORT="$TMP_ROOT/budget-curl-short.json"
long_text="one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty"
short_text="one two three four five six seven eight nine ten"
budget_replay_out="$(HOME="$BUDGET_HOME" PATH="$BUDGET_STUBS:$BUDGET_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BUDGET_CFG" DICTATE_CONFIG_FILE="$BUDGET_CFG/config.toml" CEREBRAS_API_KEY=test-key DICTATE_LLM_BUDGET_LONG_WORDS_THRESHOLD=20 DICTATE_TEST_CURL_DUMP="$BUDGET_CURL_DUMP" tmux-whisper replay code "$long_text")"
assert_contains "budget_replay_runs" "$budget_replay_out" "Re-processing with code mode"
assert_file_contains "budget_profile_auto_long_max_tokens" "$BUDGET_CURL_DUMP" '"max_tokens": 5555'
budget_replay_short_out="$(HOME="$BUDGET_HOME" PATH="$BUDGET_STUBS:$BUDGET_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BUDGET_CFG" DICTATE_CONFIG_FILE="$BUDGET_CFG/config.toml" CEREBRAS_API_KEY=test-key DICTATE_LLM_BUDGET_LONG_WORDS_THRESHOLD=20 DICTATE_TEST_CURL_DUMP="$BUDGET_CURL_DUMP_SHORT" tmux-whisper replay code "$short_text")"
assert_contains "budget_replay_short_runs" "$budget_replay_short_out" "Re-processing with code mode"
assert_file_contains "budget_profile_auto_short_scaled_max_tokens" "$BUDGET_CURL_DUMP_SHORT" '"max_tokens": 3888'

# --- Regression 12: history stats summarizes postprocess budget observability metadata. ---
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
  "metrics": {"record_ms": 18000, "transcribe_ms": 220, "clean_ms": 18, "postprocess_ms": 620, "paste_ms": 45, "total_ms": 18940},
  "postprocess_budget": {
    "numeric_sizing": "auto_dynamic",
    "profile": "long",
    "threshold_words": 20,
    "word_count": 30,
    "max_tokens": 5555,
    "chunk_words": 1000,
    "chunk_count": 2,
    "llm": "gpt-oss-120b"
  },
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
assert_contains "history_stats_budget_obs_count" "$histobs_stats" "Postprocess budget observability entries: 2"
assert_contains "history_stats_budget_profiles" "$histobs_stats" "budget_profile_counts: long=1, short=1"
assert_contains "history_stats_budget_numeric_mode" "$histobs_stats" "budget_numeric_sizing: auto_dynamic"
assert_contains "history_stats_budget_threshold" "$histobs_stats" "budget_threshold_words: 20"
assert_contains "history_stats_budget_max_tokens_line" "$histobs_stats" "budget.max_tokens: n=2"
assert_contains "history_stats_budget_chunk_count_line" "$histobs_stats" "budget.chunk_count: n=2"
assert_contains "history_stats_budget_postprocess_ms_line" "$histobs_stats" "metrics.postprocess_ms: n=2"
assert_contains "history_stats_recent_24h" "$histobs_stats" "last_24h: entries=2 raw_words=40 processed_words=40"
assert_contains "history_stats_recent_7d" "$histobs_stats" "last_7d: entries=2 raw_words=40 processed_words=40"
assert_contains "history_stats_typing_equivalent" "$histobs_stats" "typing_equivalent.total: 1m 00s @ 40 wpm"
assert_contains "history_stats_typing_delta" "$histobs_stats" "typing_delta.total: +32.6s vs end-to-end"
assert_contains "history_stats_dictation_overall" "$histobs_stats" "dictation_wpm.overall: 92"
assert_contains "history_stats_mode_breakdown" "$histobs_stats" "code: entries=2 processed_words=40 raw_words=40"
assert_contains "history_stats_app_breakdown" "$histobs_stats" "Ghostty: entries=1 processed_words=30 raw_words=30"
histobs_sessions="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history sessions 2)"
assert_contains "history_sessions_header" "$histobs_sessions" "Recent dictation sessions (newest first):"
assert_contains "history_sessions_latest" "$histobs_sessions" "mode=code app=Ghostty words=30 record=18.0s"
assert_contains "history_sessions_audio" "$histobs_sessions" "audio: capture_wav=18.1s archive_wav=18.0s capture_bytes=580000 archive_bytes=577000"
assert_contains "history_sessions_debug" "$histobs_sessions" "debug: debug_archive_prefix=2026-02-22T17-05-00-inline; retention_note=debug wav retained"
assert_contains "history_sessions_next" "$histobs_sessions" "  tmux-whisper logs tail transcribe --lines 40"
histobs_sessions_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history sessions 2 --json)"
assert_json_equals "history_sessions_json_command" "$histobs_sessions_json" "command" "history"
assert_json_equals "history_sessions_json_subcommand" "$histobs_sessions_json" "subcommand" "sessions"
assert_json_equals "history_sessions_json_first_app" "$histobs_sessions_json" "sessions.0.app" "Ghostty"
assert_json_equals "history_sessions_json_first_debug" "$histobs_sessions_json" "sessions.0.audio.debug_archive_prefix" "2026-02-22T17-05-00-inline"
assert_json_equals "history_sessions_json_first_note" "$histobs_sessions_json" "sessions.0.debug_notes.0" "debug_archive_prefix=2026-02-22T17-05-00-inline"
assert_json_equals "history_sessions_json_next" "$histobs_sessions_json" "next_commands.1" "tmux-whisper bench 10"
histobs_show_latest="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history 1)"
assert_contains "history_show_metrics_section" "$histobs_show_latest" "--- Metrics ---"
assert_contains "history_show_metrics_postprocess_ms" "$histobs_show_latest" "postprocess_ms : 620"
assert_contains "history_show_budget_section" "$histobs_show_latest" "--- Postprocess Budget ---"
assert_contains "history_show_budget_profile" "$histobs_show_latest" "profile : long"
assert_contains "history_show_budget_max_tokens" "$histobs_show_latest" "max_tokens : 5555"
assert_contains "history_show_budget_chunk_count" "$histobs_show_latest" "chunk_count : 2"
histobs_show_latest_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history --json 1)"
assert_json_equals "history_show_json_index" "$histobs_show_latest_json" "index" "1"
assert_json_equals "history_show_json_mode" "$histobs_show_latest_json" "entry.mode" "code"
assert_json_equals "history_show_json_budget_profile" "$histobs_show_latest_json" "entry.postprocess_budget.profile" "long"
histobs_list_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history list 2 --json)"
assert_json_equals "history_list_json_first_index" "$histobs_list_json" "0.index" "1"
assert_json_equals "history_list_json_first_filename" "$histobs_list_json" "0.filename" "2026-02-22T17-05-00.json"
assert_json_equals "history_list_json_first_mode" "$histobs_list_json" "0.mode" "code"
assert_json_equals "history_list_json_first_app" "$histobs_list_json" "0.app" "Ghostty"
assert_json_equals "history_list_json_first_processed_words" "$histobs_list_json" "0.processed_words" "30"
assert_json_equals "history_list_json_first_budget_profile" "$histobs_list_json" "0.postprocess_budget.profile" "long"
assert_json_equals "history_list_json_second_filename" "$histobs_list_json" "1.filename" "2026-02-22T17-00-00.json"
assert_json_equals "history_list_json_second_budget_profile" "$histobs_list_json" "1.postprocess_budget.profile" "short"
assert_contains "history_list_json_preview" "$histobs_list_json" "\"preview\": \"one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen"
histobs_search_app="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history search Ghostty)"
assert_contains "history_search_header" "$histobs_search_app" "History search: \"Ghostty\""
assert_contains "history_search_app_match" "$histobs_search_app" "(code @ Ghostty) [app]"
histobs_search_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper history search tmux 5 --json)"
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
assert_json_equals "history_export_json_first_index" "$histobs_export_json" "0.index" "1"
assert_json_equals "history_export_json_first_filename" "$histobs_export_json" "0.filename" "2026-02-22T17-05-00.json"
assert_json_equals "history_export_json_first_app" "$histobs_export_json" "0.app" "Ghostty"
assert_json_equals "history_export_json_first_processed_words" "$histobs_export_json" "0.processed_words" "30"
assert_json_equals "history_export_json_second_filename" "$histobs_export_json" "1.filename" "2026-02-22T17-00-00.json"
assert_json_equals "history_export_json_second_mode" "$histobs_export_json" "1.mode" "code"
histobs_stats_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" DICTATE_HISTORY_STATS_NOW=2026-02-22T18:00:00Z tmux-whisper history stats --json)"
assert_json_equals "history_stats_json_entries" "$histobs_stats_json" "entries" "2"
assert_json_equals "history_stats_json_budget_entries" "$histobs_stats_json" "postprocess_budget.entries" "2"
assert_json_equals "history_stats_json_budget_long_count" "$histobs_stats_json" "postprocess_budget.profile_counts.long" "1"
assert_json_equals "history_stats_json_recent_24h" "$histobs_stats_json" "recent.last_24h.entries" "2"
assert_json_equals "history_stats_json_mode_processed_words" "$histobs_stats_json" "breakdowns.modes.code.processed_words" "40"
assert_json_equals "history_stats_json_app_processed_words" "$histobs_stats_json" "breakdowns.apps.Ghostty.processed_words" "30"
assert_json_equals "history_stats_json_typing_wpm_assumed" "$histobs_stats_json" "estimates.typing_wpm_assumed" "40"
assert_json_equals "history_stats_json_typing_delta" "$histobs_stats_json" "estimates.delta_vs_end_to_end_ms" "32650"
histobs_last="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper last)"
assert_contains "history_last_header" "$histobs_last" "Latest dictation"
assert_contains "history_last_budget" "$histobs_last" "budget: profile=long"
assert_contains "history_last_capture_time" "$histobs_last" "capture_time: 18.0s"
assert_contains "history_last_end_to_end" "$histobs_last" "end_to_end: 18.9s"
assert_contains "history_last_pace" "$histobs_last" "dictation_pace: 100 wpm (raw)"
assert_contains "history_last_typing_equivalent" "$histobs_last" "typing_equivalent: 45.0s @ 40 wpm"
assert_contains "history_last_typing_delta" "$histobs_last" "typing_delta: +26.1s vs end-to-end"
histobs_last_json="$(HOME="$HISTOBS_HOME" PATH="$HISTOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$HISTOBS_CFG" DICTATE_CONFIG_FILE="$HISTOBS_CFG/config.toml" tmux-whisper last --json)"
assert_json_equals "history_last_json_app" "$histobs_last_json" "entry.app" "Ghostty"
assert_json_equals "history_last_json_budget_profile" "$histobs_last_json" "entry.postprocess_budget.profile" "long"

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
# cancelled, failed, no-speech, superseded, and replay paths do not call it.
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

# --- Regression 12b: logs command should expose paths, tail views, and JSON output cleanly. ---
LOGS_HOME="$TMP_ROOT/home-logs"
LOGS_BIN="$LOGS_HOME/.local/bin"
LOGS_CFG="$LOGS_HOME/.config/dictate"
LOGS_TMP="$LOGS_HOME/logs-tmp"
mkdir -p "$LOGS_BIN" "$LOGS_CFG" "$LOGS_TMP"
install_test_runtime "$LOGS_BIN"
cat >"$LOGS_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "auto"
EOF
LOGS_RECORD="$LOGS_TMP/record.log"
LOGS_TRANSCRIBE="$LOGS_TMP/transcribe.log"
LOGS_INLINE_RECORD="$LOGS_TMP/whisper-dictate-inline.record.log"
LOGS_INLINE_TRANSCRIBE="$LOGS_TMP/whisper-dictate-inline.transcribe.log"
cat >"$LOGS_RECORD" <<'EOF'
record line 1
record line 2
EOF
cat >"$LOGS_TRANSCRIBE" <<'EOF'
transcribe line 1
transcribe line 2
EOF
cat >"$LOGS_INLINE_RECORD" <<'EOF'
inline record line 1
inline record line 2
EOF
cat >"$LOGS_INLINE_TRANSCRIBE" <<'EOF'
inline transcribe line 1
inline transcribe line 2
EOF
logs_path_out="$(HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" tmux-whisper logs path)"
assert_contains "logs_path_header" "$logs_path_out" "Log paths"
assert_contains "logs_path_record" "$logs_path_out" "record:"
assert_contains "logs_path_inline_transcribe" "$logs_path_out" "inline-transcribe:"
assert_contains "logs_path_next" "$logs_path_out" "  tmux-whisper history sessions 5"
logs_tail_out="$(HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" tmux-whisper logs tail record --lines 1)"
assert_contains "logs_tail_header" "$logs_tail_out" "--- record (tail 1) ---"
assert_contains "logs_tail_last_line" "$logs_tail_out" "record line 2"
assert_not_contains "logs_tail_old_line_hidden" "$logs_tail_out" "record line 1"
logs_path_json="$(HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" tmux-whisper logs path inline-record --json)"
assert_json_equals "logs_path_json_command" "$logs_path_json" "command" "logs"
assert_json_equals "logs_path_json_subcommand" "$logs_path_json" "subcommand" "path"
assert_json_equals "logs_path_json_stream_key" "$logs_path_json" "streams.0.key" "inline-record"
assert_json_equals "logs_path_json_exists" "$logs_path_json" "streams.0.exists" "true"
assert_json_equals "logs_path_json_path" "$logs_path_json" "streams.0.path" "$LOGS_INLINE_RECORD"
logs_show_json="$(HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" tmux-whisper logs --json)"
assert_json_equals "logs_show_json_subcommand" "$logs_show_json" "subcommand" "show"
assert_json_equals "logs_show_json_first_stream" "$logs_show_json" "streams.0.key" "record"
assert_json_equals "logs_show_json_first_line_count" "$logs_show_json" "streams.0.line_count" "2"
assert_json_equals "logs_show_json_first_line" "$logs_show_json" "streams.0.lines.0" "record line 1"
assert_json_equals "logs_show_json_next" "$logs_show_json" "next_commands.1" "tmux-whisper history sessions 5"
logs_tail_json="$(HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" tmux-whisper logs tail transcribe --lines 1 --json)"
assert_json_equals "logs_tail_json_subcommand" "$logs_tail_json" "subcommand" "tail"
assert_json_equals "logs_tail_json_stream_key" "$logs_tail_json" "streams.0.key" "transcribe"
assert_json_equals "logs_tail_json_requested_lines" "$logs_tail_json" "streams.0.tail_lines_requested" "1"
assert_json_equals "logs_tail_json_line" "$logs_tail_json" "streams.0.lines.0" "transcribe line 2"
wait_for_follow_initial_line() {
  local file="$1" needle="$2" attempt
  for ((attempt = 0; attempt < 250; attempt++)); do
    if [[ -f "$file" ]] && rg -q --fixed-strings "$needle" "$file"; then
      break
    fi
    sleep 0.02
  done
}

# Append only after follow has emitted its initial tail. A timed writer can
# win the startup race and turn the new line into the initial tail instead.
logs_follow_record_out="$LOGS_TMP/follow-record.out"
HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" DICTATE_LOGS_FOLLOW_POLL_MS=50 DICTATE_LOGS_FOLLOW_ITERATIONS=20 tmux-whisper logs follow record --lines 1 >"$logs_follow_record_out" &
logs_follow_record_pid=$!
wait_for_follow_initial_line "$logs_follow_record_out" "record line 2"
assert_file_contains "logs_follow_initial_line" "$logs_follow_record_out" "record line 2"
printf '%s\n' 'record line 3' >>"$LOGS_RECORD"
wait "$logs_follow_record_pid"
logs_follow_out="$(cat "$logs_follow_record_out")"
assert_contains "logs_follow_header" "$logs_follow_out" "Following logs (poll 50ms). Press Ctrl-C to stop."
assert_contains "logs_follow_block_header" "$logs_follow_out" "--- record (follow tail 1) ---"
assert_contains "logs_follow_new_line" "$logs_follow_out" "record line 3"
assert_not_contains "logs_follow_old_line_hidden" "$logs_follow_out" "record line 1"
logs_follow_json_out="$LOGS_TMP/follow-transcribe.jsonl"
HOME="$LOGS_HOME" PATH="$LOGS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$LOGS_CFG" DICTATE_CONFIG_FILE="$LOGS_CFG/config.toml" DICTATE_RECORD_LOG="$LOGS_RECORD" DICTATE_TRANSCRIBE_LOG="$LOGS_TRANSCRIBE" DICTATE_TMPDIR="$LOGS_TMP" DICTATE_LOGS_FOLLOW_POLL_MS=50 DICTATE_LOGS_FOLLOW_ITERATIONS=20 tmux-whisper logs follow transcribe --lines 1 --json >"$logs_follow_json_out" &
logs_follow_json_pid=$!
wait_for_follow_initial_line "$logs_follow_json_out" "transcribe line 2"
assert_file_contains "logs_follow_json_initial_tail" "$logs_follow_json_out" "transcribe line 2"
printf '%s\n' 'transcribe line 3' >>"$LOGS_TRANSCRIBE"
wait "$logs_follow_json_pid"
logs_follow_json="$(cat "$logs_follow_json_out")"
logs_follow_json_last="$(printf '%s\n' "$logs_follow_json" | tail -n 1)"
assert_json_equals "logs_follow_json_event" "$logs_follow_json_last" "event" "line"
assert_json_equals "logs_follow_json_subcommand" "$logs_follow_json_last" "subcommand" "follow"
assert_json_equals "logs_follow_json_stream" "$logs_follow_json_last" "stream" "transcribe"
assert_json_equals "logs_follow_json_initial" "$logs_follow_json_last" "initial" "false"
assert_json_equals "logs_follow_json_line" "$logs_follow_json_last" "line" "transcribe line 3"

# --- Regression 12c: devices JSON output should enumerate AVFoundation audio devices cleanly. ---
DEVICES_HOME="$TMP_ROOT/home-devices"
DEVICES_BIN="$DEVICES_HOME/.local/bin"
mkdir -p "$DEVICES_BIN"
install_test_runtime "$DEVICES_BIN"
cat >"$DEVICES_BIN/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'OUT'
ffmpeg version test
[AVFoundation indev @ 0x0] AVFoundation audio devices:
[AVFoundation indev @ 0x0] [0] MacBook Air Microphone
[AVFoundation indev @ 0x0] [1] External USB Mic
[AVFoundation indev @ 0x0] AVFoundation video devices:
[AVFoundation indev @ 0x0] [0] FaceTime HD Camera
Error opening input files: Input/output error
OUT
exit 1
EOF
chmod +x "$DEVICES_BIN/ffmpeg"
devices_json="$(HOME="$DEVICES_HOME" PATH="$DEVICES_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= tmux-whisper devices --json)"
assert_json_equals "devices_json_command" "$devices_json" "command" "devices"
assert_json_equals "devices_json_platform" "$devices_json" "platform" "macos"
assert_json_equals "devices_json_count" "$devices_json" "count" "2"
assert_json_equals "devices_json_first_index" "$devices_json" "devices.0.index" "0"
assert_json_equals "devices_json_first_name" "$devices_json" "devices.0.name" "MacBook Air Microphone"
assert_json_equals "devices_json_second_name" "$devices_json" "devices.1.name" "External USB Mic"
assert_json_equals "devices_json_permission_hint" "$devices_json" "permission_hint" "null"

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

[audio]
source = "external"
device_name = "Studio Mic"

[swift_parakeet]
model_path = "$CONFIGOBS_MODEL"
socket_path = "$CONFIGOBS_SOCKET"

[postprocess]
enabled = true
llm = "qwen-3-32b"

[inline]
autosend = false
process_sound = true

[tmux]
mode = "chat"

[debug]
keep_logs = true
EOF
configobs_show="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config)"
assert_contains "config_show_path" "$configobs_show" "Config path: $CONFIGOBS_CFG/config.toml (present)"
assert_contains "config_show_audio_source" "$configobs_show" "audio.source: external"
assert_contains "config_show_postprocess" "$configobs_show" "postprocess.enabled: on"
assert_contains "config_show_tmux_mode" "$configobs_show" "tmux.mode: chat"
configobs_show_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config --json)"
assert_json_equals "config_show_json_command" "$configobs_show_json" "command" "config"
assert_json_equals "config_show_json_subcommand" "$configobs_show_json" "subcommand" "show"
assert_json_equals "config_show_json_exists" "$configobs_show_json" "config_exists" "true"
assert_json_equals "config_show_json_schema_status" "$configobs_show_json" "schema.status" "ok"
assert_json_equals "config_show_json_audio_source" "$configobs_show_json" "effective.audio.source" "external"
assert_json_equals "config_show_json_inline_autosend" "$configobs_show_json" "effective.inline.autosend" "false"
assert_json_equals "config_show_json_postprocess_llm" "$configobs_show_json" "effective.postprocess.llm" "qwen-3-32b"
assert_json_equals "config_show_json_keep_logs" "$configobs_show_json" "effective.debug.keep_logs" "true"
configobs_path_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config path --json)"
assert_json_equals "config_path_json_subcommand" "$configobs_path_json" "subcommand" "path"
assert_json_equals "config_path_json_path" "$configobs_path_json" "config_path" "$CONFIGOBS_CFG/config.toml"
configobs_get_text="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config get audio.source)"
assert_contains "config_get_text_value" "$configobs_get_text" "audio.source = \"external\""
assert_contains "config_get_text_source" "$configobs_get_text" "source: file"
configobs_get_default_json="$(HOME="$CONFIGOBS_HOME" PATH="$CONFIGOBS_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$CONFIGOBS_CFG" DICTATE_CONFIG_FILE="$CONFIGOBS_CFG/config.toml" tmux-whisper config get audio.silence_trim --json)"
assert_json_equals "config_get_default_found" "$configobs_get_default_json" "found" "true"
assert_json_equals "config_get_default_source" "$configobs_get_default_json" "source" "default"
assert_json_equals "config_get_default_value" "$configobs_get_default_json" "value" "false"
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
assert_json_equals "bench_json_latest_mode" "$bench_summary_json" "latest.mode" "email"
assert_json_equals "bench_json_latest_postprocess" "$bench_summary_json" "latest.postprocess_enabled" "true"
assert_json_equals "bench_json_next" "$bench_summary_json" "next_commands.0" "tmux-whisper history sessions 5"

bench_filtered_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench all --flow inline)"
assert_contains "bench_filter_header" "$bench_filtered_out" "Tmux Whisper bench (last 2 of 2 matching runs; total 3)"
assert_contains "bench_filter_flow_line" "$bench_filtered_out" "flow: inline"
assert_contains "bench_filter_flow_counts" "$bench_filtered_out" "by flow: inline=2"
assert_contains "bench_filter_latest_line" "$bench_filtered_out" "2026-04-22T09:02:00Z flow=inline status=ok"

bench_filtered_json="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench all --flow inline --slow-startup-audio-ms 31 --json)"
assert_json_equals "bench_filter_json_total_records" "$bench_filtered_json" "total_records" "3"
assert_json_equals "bench_filter_json_filtered_records" "$bench_filtered_json" "filtered_records" "1"
assert_json_equals "bench_filter_json_subset_records" "$bench_filtered_json" "subset_records" "1"
assert_json_equals "bench_filter_json_filter_flow" "$bench_filtered_json" "filters.flow" "inline"
assert_json_equals "bench_filter_json_filter_audio_min" "$bench_filtered_json" "filters.minimums.startup_audio_ms" "31"
assert_json_equals "bench_filter_json_latest_timestamp" "$bench_filtered_json" "latest.timestamp" "2026-04-22T09:00:00Z"

bench_filtered_export_json="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" tmux-whisper bench export all --slow-startup-ffmpeg-ms 16 --json)"
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

# --- Regression 15: bench-matrix UX checks are stable. ---

bench_bad_n_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" CEREBRAS_API_KEY= tmux-whisper bench-matrix nope 2>&1 || true)"
assert_contains "bench_matrix_invalid_n_usage" "$bench_bad_n_out" "usage: tmux-whisper bench-matrix [N] [phrase_file]"

bench_missing_phrase_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" CEREBRAS_API_KEY= tmux-whisper bench-matrix 1 "$TMP_ROOT/no-such-phrases.txt" 2>&1 || true)"
assert_contains "bench_matrix_missing_phrase_file" "$bench_missing_phrase_out" "phrase file not found:"

bench_matrix_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" CEREBRAS_API_KEY= tmux-whisper bench-matrix 1)"
assert_contains "bench_matrix_smoke_header" "$bench_matrix_out" "Tmux Whisper bench-matrix"
assert_contains "bench_matrix_smoke_skip_note" "$bench_matrix_out" "postprocess=on combos skipped"

BENCH_PHRASES_FILE="$TMP_ROOT/bench-phrases.txt"
cat >"$BENCH_PHRASES_FILE" <<'EOF'
# label<TAB>phrase format is supported
ops-check	please check the current install status
just a plain phrase line
EOF

bench_matrix_file_out="$(HOME="$BENCH_HOME" PATH="$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" CEREBRAS_API_KEY= DICTATE_BENCH_MATRIX_PROGRESS=0 tmux-whisper bench-matrix 1 "$BENCH_PHRASES_FILE")"
assert_contains "bench_matrix_phrase_file_count" "$bench_matrix_file_out" "Phrases: 2"
assert_contains "bench_matrix_header_llm_model" "$bench_matrix_file_out" "llm_model"
assert_not_contains "bench_matrix_progress_suppressed" "$bench_matrix_file_out" "bench-matrix: combo"

bench_matrix_obs_out="$(HOME="$BENCH_HOME" PATH="$BUDGET_STUBS:$BENCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$BENCH_CFG" DICTATE_CONFIG_FILE="$BENCH_CFG/config.toml" CEREBRAS_API_KEY=test-key DICTATE_BENCH_MATRIX_MODELS=gpt DICTATE_BENCH_MATRIX_PROGRESS=0 DICTATE_LLM_BUDGET_LONG_WORDS_THRESHOLD=20 tmux-whisper bench-matrix 1 "$BENCH_PHRASES_FILE")"
assert_contains "bench_matrix_budget_obs_section" "$bench_matrix_obs_out" "Budget auto observability (postprocess rows)"
assert_contains "bench_matrix_budget_obs_profiles" "$bench_matrix_obs_out" "profile counts:"
assert_contains "bench_matrix_budget_obs_max_tokens" "$bench_matrix_obs_out" "max_tokens: n="
assert_contains "bench_matrix_budget_obs_chunk_count" "$bench_matrix_obs_out" "chunk_count: n="

# --- Regression 16: watch provides a text-first live operator overview. ---
WATCH_HOME="$TMP_ROOT/home-watch"
WATCH_BIN="$WATCH_HOME/.local/bin"
WATCH_CFG="$WATCH_HOME/.config/dictate"
WATCH_HISTORY="$WATCH_CFG/history"
WATCH_MODEL="$WATCH_HOME/models/parakeet-watch"
WATCH_RUNTIME="$WATCH_HOME/runtime"
mkdir -p "$WATCH_BIN" "$WATCH_CFG" "$WATCH_HISTORY" "$WATCH_MODEL" "$WATCH_RUNTIME"
install_test_runtime "$WATCH_BIN"
cat >"$WATCH_CFG/config.toml" <<EOF
[meta]
config_version = 1

[audio]
source = "mac"
mac_name = "MacBook Air Microphone"

[swift_parakeet]
model_path = "$WATCH_MODEL"
EOF
cat >"$WATCH_BIN/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'OUT'
ffmpeg version test
[AVFoundation indev @ 0x0] AVFoundation audio devices:
[AVFoundation indev @ 0x0] [0] MacBook Air Microphone
[AVFoundation indev @ 0x0] AVFoundation video devices:
[AVFoundation indev @ 0x0] [0] FaceTime HD Camera
Error opening input files: Input/output error
OUT
exit 1
EOF
chmod +x "$WATCH_BIN/ffmpeg"
cat >"$WATCH_HISTORY/2026-04-22T09-05-00.json" <<'EOF'
{
  "timestamp": "2026-04-22T09:05:00Z",
  "mode": "code",
  "app": "Ghostty",
  "raw": "hello there friend",
  "processed": "Hello there, friend.",
  "metrics": {
    "record_ms": 2500,
    "transcribe_ms": 300,
    "clean_ms": 15,
    "postprocess_ms": 0,
    "paste_ms": 120,
    "total_ms": 2935
  }
}
EOF
cat >"$WATCH_HISTORY/bench.tsv" <<'EOF'
2026-04-22T09:04:00Z	inline	ok	parakeet-watch	base	0	10	10	1800	260	10	0	100	2170	65	20	12	0	cache:source(mac)
2026-04-22T09:05:00Z	inline	ok	parakeet-watch	code	0	18	20	2500	300	15	0	120	2935	70	25	15	0	cache:source(mac)
EOF

watch_out="$(HOME="$WATCH_HOME" PATH="$WATCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$WATCH_CFG" DICTATE_CONFIG_FILE="$WATCH_CFG/config.toml" DICTATE_STATE_FILE="$WATCH_RUNTIME/tmux.state" DICTATE_INLINE_STATE_FILE="$WATCH_RUNTIME/inline.state" DICTATE_TMUX_JOBS_DIR="$WATCH_RUNTIME/tmux-jobs" DICTATE_PROCESSING_DIR="$WATCH_RUNTIME/processing" tmux-whisper watch --interval 0.01 --iterations 1)"
assert_contains "watch_header" "$watch_out" "=== Tmux Whisper watch snapshot 1/1 ==="
assert_contains "watch_summary_state" "$watch_out" "  state: ready"
assert_contains "watch_summary_backend" "$watch_out" "  backend: swift_parakeet (cold)"
assert_contains "watch_latest_mode_app" "$watch_out" "  mode/app: code @ Ghostty"
assert_contains "watch_latest_preview" "$watch_out" "  preview: Hello there, friend."
assert_contains "watch_bench_window" "$watch_out" "  window: last 2 of 2"
assert_contains "watch_bench_latest" "$watch_out" "  latest: inline ok mode=code total=2.9s transcribe=300ms paste=120ms"
assert_contains "watch_more_detail" "$watch_out" "  tmux-whisper last"

watch_compact_out="$(HOME="$WATCH_HOME" PATH="$WATCH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$WATCH_CFG" DICTATE_CONFIG_FILE="$WATCH_CFG/config.toml" DICTATE_STATE_FILE="$WATCH_RUNTIME/tmux.state" DICTATE_INLINE_STATE_FILE="$WATCH_RUNTIME/inline.state" DICTATE_TMUX_JOBS_DIR="$WATCH_RUNTIME/tmux-jobs" DICTATE_PROCESSING_DIR="$WATCH_RUNTIME/processing" tmux-whisper watch --preset compact --interval 0.01 --iterations 1)"
assert_contains "watch_compact_header" "$watch_compact_out" "=== Tmux Whisper watch snapshot 1/1 ==="
assert_contains "watch_compact_preset" "$watch_compact_out" "Preset: compact"
assert_contains "watch_compact_summary" "$watch_compact_out" "Summary: state=ready backend=cold flow=none config=v1/ok"
assert_contains "watch_compact_modes" "$watch_compact_out" "Modes: inline=code [auto], tmux=code"
assert_contains "watch_compact_runtime" "$watch_compact_out" "Runtime: tmux=idle inline=idle proc=0/0 stale=0 queue=0/0"
assert_contains "watch_compact_last" "$watch_compact_out" "Last: code @ Ghostty 2026-04-22T09:05:00Z total=2.9s transcribe=300ms preview=Hello there, friend."
assert_contains "watch_compact_bench" "$watch_compact_out" "Bench: window=2/2 latest=inline ok mode=code total=2.9s transcribe=300ms paste=120ms"
assert_contains "watch_compact_more" "$watch_compact_out" "More: tmux-whisper last | tmux-whisper bench | tmux-whisper logs tail transcribe --lines 20"

WATCH_REFRESH_HOME="$TMP_ROOT/home-watch-refresh"
WATCH_REFRESH_BIN="$WATCH_REFRESH_HOME/.local/bin"
WATCH_REFRESH_CFG="$WATCH_REFRESH_HOME/.config/dictate"
WATCH_REFRESH_HISTORY="$WATCH_REFRESH_CFG/history"
WATCH_REFRESH_MODEL="$WATCH_REFRESH_HOME/models/parakeet-watch"
WATCH_REFRESH_RUNTIME="$WATCH_REFRESH_HOME/runtime"
WATCH_REFRESH_SIGNAL="$TMP_ROOT/watch-refresh.signal"
mkdir -p "$WATCH_REFRESH_BIN" "$WATCH_REFRESH_CFG" "$WATCH_REFRESH_HISTORY" "$WATCH_REFRESH_MODEL" "$WATCH_REFRESH_RUNTIME"
install_test_runtime "$WATCH_REFRESH_BIN"
cat >"$WATCH_REFRESH_CFG/config.toml" <<EOF
[meta]
config_version = 1

[audio]
source = "mac"
mac_name = "MacBook Air Microphone"

[swift_parakeet]
model_path = "$WATCH_REFRESH_MODEL"
EOF
cat >"$WATCH_REFRESH_BIN/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'OUT'
ffmpeg version test
[AVFoundation indev @ 0x0] AVFoundation audio devices:
[AVFoundation indev @ 0x0] [0] MacBook Air Microphone
[AVFoundation indev @ 0x0] AVFoundation video devices:
[AVFoundation indev @ 0x0] [0] FaceTime HD Camera
Error opening input files: Input/output error
OUT
exit 1
EOF
chmod +x "$WATCH_REFRESH_BIN/ffmpeg"
cat >"$WATCH_REFRESH_HISTORY/2026-04-22T09-08-00.json" <<'EOF'
{
  "timestamp": "2026-04-22T09:08:00Z",
  "mode": "code",
  "app": "Ghostty",
  "raw": "show me the first snapshot state",
  "processed": "Show me the first snapshot state.",
  "metrics": {
    "record_ms": 2200,
    "transcribe_ms": 280,
    "clean_ms": 16,
    "postprocess_ms": 0,
    "paste_ms": 100,
    "total_ms": 2596
  }
}
EOF

watch_refresh_out="$(
  (
    while [[ ! -f "$WATCH_REFRESH_SIGNAL" ]]; do
      sleep 0.05
    done
    cat >"$WATCH_REFRESH_HISTORY/2026-04-22T09-10-00.json" <<'EOF'
{
  "timestamp": "2026-04-22T09:10:00Z",
  "mode": "base",
  "app": "WezTerm",
  "raw": "check the second snapshot please",
  "processed": "Check the second snapshot, please.",
  "metrics": {
    "record_ms": 1800,
    "transcribe_ms": 210,
    "clean_ms": 12,
    "postprocess_ms": 0,
    "paste_ms": 90,
    "total_ms": 2112
  }
}
EOF
  ) &
  watch_refresh_writer_pid=$!
  HOME="$WATCH_REFRESH_HOME" PATH="$WATCH_REFRESH_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_CONFIG_DIR="$WATCH_REFRESH_CFG" DICTATE_CONFIG_FILE="$WATCH_REFRESH_CFG/config.toml" DICTATE_STATE_FILE="$WATCH_REFRESH_RUNTIME/tmux.state" DICTATE_INLINE_STATE_FILE="$WATCH_REFRESH_RUNTIME/inline.state" DICTATE_TMUX_JOBS_DIR="$WATCH_REFRESH_RUNTIME/tmux-jobs" DICTATE_PROCESSING_DIR="$WATCH_REFRESH_RUNTIME/processing" tmux-whisper watch --interval 0.2 --iterations 3 | WATCH_REFRESH_SIGNAL="$WATCH_REFRESH_SIGNAL" python3 -c 'import os, pathlib, sys
signal = pathlib.Path(os.environ["WATCH_REFRESH_SIGNAL"])
for line in sys.stdin:
    sys.stdout.write(line)
    sys.stdout.flush()
    if line.startswith("=== Tmux Whisper watch snapshot 1/3 ==="):
        signal.touch(exist_ok=True)
'
  wait "$watch_refresh_writer_pid"
)"
assert_contains "watch_refresh_first_snapshot" "$watch_refresh_out" "=== Tmux Whisper watch snapshot 1/3 ==="
assert_contains "watch_refresh_final_snapshot" "$watch_refresh_out" "=== Tmux Whisper watch snapshot 3/3 ==="
assert_contains "watch_refresh_initial_history" "$watch_refresh_out" "  mode/app: code @ Ghostty"
assert_contains "watch_refresh_initial_preview" "$watch_refresh_out" "  preview: Show me the first snapshot state."
assert_contains "watch_refresh_new_history" "$watch_refresh_out" "  mode/app: base @ WezTerm"
assert_contains "watch_refresh_new_preview" "$watch_refresh_out" "  preview: Check the second snapshot, please."

# --- Regression 17: stale cached audio indices should be ignored when ffmpeg devices change. ---
AUDIOCACHE_HOME="$TMP_ROOT/home-audiocache"
AUDIOCACHE_BIN="$AUDIOCACHE_HOME/.local/bin"
AUDIOCACHE_CFG="$AUDIOCACHE_HOME/.config/dictate"
AUDIOCACHE_CACHE="$AUDIOCACHE_CFG/.cache"
mkdir -p "$AUDIOCACHE_BIN" "$AUDIOCACHE_CFG" "$AUDIOCACHE_CACHE"
install_test_runtime "$AUDIOCACHE_BIN"
cat >"$AUDIOCACHE_CFG/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "mac"
mac_name = "MacBook Air Microphone"
EOF
cat >"$AUDIOCACHE_CACHE/audio-index.sh" <<'EOF'
CACHED_AUDIO_KEY=source=mac\;preferred=MacBook\ Air\ Microphone\;mac=MacBook\ Air\ Microphone\;iphone=
CACHED_AUDIO_NAME=MacBook\ Air\ Microphone
CACHED_AUDIO_MATCH=mac
CACHED_AUDIO_INDEX=1
CACHED_AUDIO_AT=2026-03-20T08:47:56Z
EOF
cat >"$AUDIOCACHE_BIN/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"-list_devices true"* ]]; then
  cat >&2 <<'OUT'
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] FaceTime HD Camera
[AVFoundation indev @ 0x1] [1] Capture screen 0
[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] MacBook Air Microphone
OUT
  exit 0
fi
exit 0
EOF
chmod +x "$AUDIOCACHE_BIN/ffmpeg"

# This case verifies a stale index against the device list. Do not inherit the
# recording fast-path override from a developer shell, which deliberately skips
# that validation for warm caches.
audiocache_debug="$(HOME="$AUDIOCACHE_HOME" PATH="$AUDIOCACHE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_AUDIO_CACHE_SKIP_VALIDATE=0 DICTATE_CONFIG_DIR="$AUDIOCACHE_CFG" DICTATE_CONFIG_FILE="$AUDIOCACHE_CFG/config.toml" tmux-whisper debug)"
assert_contains "audio_cache_stale_refreshed" "$audiocache_debug" "Resolved audio index: 0 (source: detect:source(mac):match(mac):name(MacBook Air Microphone))"
assert_contains "audio_cache_note_present" "$audiocache_debug" "Audio cache note: stale cache invalidated: cached idx=1 name=MacBook Air Microphone match=mac at=2026-03-20T08:47:56Z; re-resolved idx=0 match=mac name=MacBook Air Microphone"
assert_file_contains "audio_cache_rewritten_index" "$AUDIOCACHE_CACHE/audio-index.sh" "CACHED_AUDIO_INDEX=0"

cat >"$AUDIOCACHE_CACHE/audio-index.sh" <<'EOF'
CACHED_AUDIO_KEY=source=mac\;preferred=MacBook\ Air\ Microphone\;mac=MacBook\ Air\ Microphone\;iphone=
CACHED_AUDIO_NAME=MacBook\ Air\ Microphone
CACHED_AUDIO_MATCH=mac
CACHED_AUDIO_INDEX=1
CACHED_AUDIO_AT=2026-03-20T08:47:56Z
EOF

audiocache_debug_json="$(HOME="$AUDIOCACHE_HOME" PATH="$AUDIOCACHE_BIN:/usr/bin:/bin" DICTATE_LIB_PATH= DICTATE_AUDIO_CACHE_SKIP_VALIDATE=0 DICTATE_CONFIG_DIR="$AUDIOCACHE_CFG" DICTATE_CONFIG_FILE="$AUDIOCACHE_CFG/config.toml" tmux-whisper debug --json)"
assert_json_equals "audio_cache_json_index" "$audiocache_debug_json" "audio_resolution.index" "0"
assert_json_equals "audio_cache_json_note" "$audiocache_debug_json" "audio_resolution.cache_note" "stale cache invalidated: cached idx=1 name=MacBook Air Microphone match=mac at=2026-03-20T08:47:56Z; re-resolved idx=0 match=mac name=MacBook Air Microphone"

echo "Regression tests passed."
