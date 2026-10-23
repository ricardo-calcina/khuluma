#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KHULUMA_BIN="$ROOT/bin/khuluma"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_ROOT"
source "$ROOT/tests/fixture_helpers.sh"
STUB_DIR="$TMP_ROOT/stubs"
STUB_REGISTRY_DIR="$TMP_ROOT/stub-daemons"
mkdir -p "$STUB_DIR"

stub_process_matches_registry() {
  local pid="$1"
  local socket_path="$2"
  local proc_cmd

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$socket_path" == "$TMP_ROOT/"* ]] || return 1
  proc_cmd="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$proc_cmd" == *"$socket_path"* ]]
}

cleanup_stub_daemons() {
  local sf pid socket_path tries

  [[ -d "$STUB_REGISTRY_DIR" ]] || return 0
  while IFS= read -r sf; do
    [[ -f "$sf" ]] || continue
    unset pid socket_path
    # shellcheck disable=SC1090
    . "$sf" 2>/dev/null || true
    stub_process_matches_registry "${pid:-}" "${socket_path:-}" || continue

    kill -TERM "$pid" 2>/dev/null || true
    for ((tries = 0; tries < 20; tries++)); do
      ! stub_process_matches_registry "$pid" "$socket_path" && break
      sleep 0.05
    done
    if stub_process_matches_registry "$pid" "$socket_path"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(find "$STUB_REGISTRY_DIR" -type f -name '*.state' 2>/dev/null || true)
}

assert_no_registered_stub_processes() {
  local sf pid socket_path

  [[ -d "$STUB_REGISTRY_DIR" ]] || return 0
  while IFS= read -r sf; do
    [[ -f "$sf" ]] || continue
    unset pid socket_path
    # shellcheck disable=SC1090
    . "$sf" 2>/dev/null || true
    if stub_process_matches_registry "${pid:-}" "${socket_path:-}"; then
      fail "stub_daemon_cleanup pid=${pid} socket=${socket_path}"
    fi
  done < <(find "$STUB_REGISTRY_DIR" -type f -name '*.state' 2>/dev/null || true)
  pass "stub_daemon_cleanup"
}

assert_registered_stub_process() {
  local sf pid socket_path

  [[ -d "$STUB_REGISTRY_DIR" ]] || fail "stub_daemon_registry_created"
  while IFS= read -r sf; do
    [[ -f "$sf" ]] || continue
    unset pid socket_path
    # shellcheck disable=SC1090
    . "$sf" 2>/dev/null || true
    if stub_process_matches_registry "${pid:-}" "${socket_path:-}"; then
      pass "stub_daemon_registry_records_live_stub"
      return 0
    fi
  done < <(find "$STUB_REGISTRY_DIR" -type f -name '*.state' 2>/dev/null || true)
  fail "stub_daemon_registry_records_live_stub"
}

cleanup() {
  set +e
  if [[ -d "$TMP_ROOT" ]]; then
    cleanup_stub_daemons
    while IFS= read -r sf; do
      [[ -f "$sf" ]] || continue
      unset pid wav
      # shellcheck disable=SC1090
      . "$sf" 2>/dev/null || true
      if [[ -n "${pid:-}" && "$pid" =~ ^[0-9]+$ ]]; then
        local proc_cmd
        proc_cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$proc_cmd" == *"/ffmpeg"* ]]; then
          kill -INT "$pid" 2>/dev/null || true
        fi
      fi
      : # Audio fixtures remain inside the retained temporary root.
    done < <(find "$TMP_ROOT" -type f -name '*.state' 2>/dev/null || true)
    report_fixture_root
  fi
}
trap cleanup EXIT

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected to find: $needle" >&2
    echo "In output: $haystack" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_file_contains() {
  local name="$1"
  local file="$2"
  local needle="$3"
  if ! grep -Fq "$needle" "$file"; then
    echo "Missing pattern in $file: $needle" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_file_not_contains() {
  local name="$1"
  local file="$2"
  local needle="$3"
  if grep -Fq "$needle" "$file"; then
    echo "Unexpected pattern in $file: $needle" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_equals() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_number_ge() {
  local name="$1"
  local actual="$2"
  local expected="$3"
  if (( actual < expected )); then
    echo "Expected >= $expected" >&2
    echo "Actual:   $actual" >&2
    fail "$name"
  fi
  pass "$name"
}

wait_for_file_contains() {
  local file="$1"
  local needle="$2"
  local tries="${3:-120}"
  local i
  for ((i = 0; i < tries; i++)); do
    if [[ -f "$file" ]] && grep -Fq "$needle" "$file"; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_for_file_not_contains() {
  local file="$1"
  local needle="$2"
  local tries="${3:-120}"
  local i
  for ((i = 0; i < tries; i++)); do
    if [[ -f "$file" ]] && ! grep -Fq "$needle" "$file"; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_for_matching_file() {
  local dir="$1"
  local pattern="$2"
  local tries="${3:-120}"
  local i
  for ((i = 0; i < tries; i++)); do
    if find "$dir" -name "$pattern" -type f -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_for_no_matching_file() {
  local dir="$1"
  local pattern="$2"
  local tries="${3:-120}"
  local i
  for ((i = 0; i < tries; i++)); do
    if [[ ! -d "$dir" ]] || ! find "$dir" -name "$pattern" -type f | grep -q .; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_for_absent() {
  local path="$1"
  local tries="${2:-120}"
  local i
  for ((i = 0; i < tries; i++)); do
    [[ ! -e "$path" ]] && return 0
    sleep 0.05
  done
  return 1
}

write_stubs() {
  cat >"$STUB_DIR/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"-list_devices true"* ]]; then
  [[ -n "${KHULUMA_TEST_FFMPEG_LIST_LOG:-}" ]] && printf 'list_devices\n' >>"$KHULUMA_TEST_FFMPEG_LIST_LOG"
  cat >&2 <<'OUT'
[AVFoundation input device @ 0x0] AVFoundation audio devices:
[AVFoundation input device @ 0x0] [0] MacBook Air Microphone
[AVFoundation input device @ 0x0] AVFoundation video devices:
[AVFoundation input device @ 0x0] [0] FaceTime HD Camera
OUT
  exit 0
fi

if [[ -n "${KHULUMA_TEST_FFMPEG_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$KHULUMA_TEST_FFMPEG_LOG"
fi

# Simulate a device that can't be opened by name (renamed/unplugged). Real
# ffmpeg takes 0.2-0.8s to give up, well past a bare "is it running" check.
if [[ "${KHULUMA_TEST_FFMPEG_FAIL_NAME:-0}" == "1" && "$*" == *"-i :MacBook Air Microphone"* ]]; then
  sleep 0.4
  echo "[AVFoundation indev] Audio device not found" >&2
  exit 251
fi

out="${!#}"
mkdir -p "$(dirname "$out")"
duration_ms=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-t" ]]; then
    duration_ms="$(awk -v seconds="$arg" 'BEGIN { printf "%.0f", seconds * 1000 }')"
    break
  fi
  prev="$arg"
done
if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
  printf 'duration_ms=%s\n' "$duration_ms" >"$out"
else
  printf '%s\n' "stub-wav" >"$out"
fi

if [[ "${KHULUMA_TEST_FFMPEG_HOLD:-0}" == "1" && ( "$out" == *"khuluma-"* || "$out" == *"khuluma-inline-"* ) ]]; then
  trap 'exit 0' INT TERM
  if [[ "$*" != *"-nostdin"* ]]; then
    while IFS= read -r -n 1 ch; do
      [[ "$ch" == "q" ]] && exit 0
    done
  fi
  while :; do sleep 1; done
fi
exit 0
EOF

  cat >"$STUB_DIR/ffprobe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

duration_ms="${KHULUMA_TEST_FFPROBE_DURATION_MS:-}"
if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
  awk -v ms="$duration_ms" 'BEGIN { printf "%.6f\n", ms/1000 }'
  exit 0
fi

exit 1
EOF

  cat >"$STUB_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${KHULUMA_TEST_TMUX_LOG:-}"
cmd="${1:-}"
[[ -n "$cmd" ]] || exit 0
shift || true

if [[ -n "$log" ]]; then
  printf 'tmux %s' "$cmd" >>"$log"
  for arg in "$@"; do
    printf ' %s' "$arg" >>"$log"
  done
  printf '\n' >>"$log"
fi

case "$cmd" in
  display-message)
    fmt=""
    for arg in "$@"; do
      fmt="$arg"
    done
    case "$fmt" in
      '#{pane_id}')
        printf '%s\n' "${KHULUMA_TEST_TMUX_PANE:-%1}"
        ;;
      '#{pane_current_path}')
        printf '%s\n' "${KHULUMA_TEST_TMUX_PATH:-/tmp/project}"
        ;;
      '#{pane_title}')
        printf '%s\n' "${KHULUMA_TEST_TMUX_TITLE:-main}"
        ;;
      '#{pane_current_command}')
        printf '%s\n' "${KHULUMA_TEST_TMUX_PANE_CMD:-bash}"
        ;;
      '#{pane_tty}')
        printf '%s\n' "${KHULUMA_TEST_TMUX_TTY:-}"
        ;;
      '#{pane_pid}')
        printf '%s\n' "${KHULUMA_TEST_TMUX_PANE_PID:-}"
        ;;
    esac
    ;;
esac
exit 0
EOF

  cat >"$STUB_DIR/pbcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >"${KHULUMA_TEST_PBCOPY_OUT:-/tmp/khuluma-test-pbcopy.out}"
EOF

  cat >"$STUB_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [[ -n "${KHULUMA_TEST_OSASCRIPT_LOG:-}" ]]; then
  printf '%s\n' "$joined" >>"$KHULUMA_TEST_OSASCRIPT_LOG"
fi
if [[ "$joined" == *"get name of first process whose frontmost is true"* ]]; then
  printf '%s\n' "${KHULUMA_TEST_FRONT_APP:-Ghostty}"
fi
exit 0
EOF

  cat >"$STUB_DIR/afplay" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${KHULUMA_TEST_SOUND_LOG:-}" ]]; then
  printf '%s\n' "${1:-}" >>"$KHULUMA_TEST_SOUND_LOG"
fi
exit 0
EOF

  cat >"$STUB_DIR/khulumad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  serve)
    socket_path=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --socket)
          socket_path="${2:-}"
          shift 2
          ;;
        *)
          echo "unknown arg: $1" >&2
          exit 2
          ;;
      esac
    done
    [[ -n "$socket_path" ]] || { echo "missing socket path" >&2; exit 2; }
    registry_dir="${KHULUMA_TEST_STUB_REGISTRY_DIR:-}"
    if [[ -n "$registry_dir" ]]; then
      mkdir -p "$registry_dir"
      printf 'pid=%q\nsocket_path=%q\n' "$$" "$socket_path" >"$registry_dir/$$.state"
    fi
    exec python3 - "$socket_path" <<'PYEOF'
import json
import os
import socket
import sys

socket_path = sys.argv[1]
os.makedirs(os.path.dirname(socket_path), exist_ok=True)
# Like the real daemon: never take over a socket another daemon serves.
probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    probe.connect(socket_path)
    sys.stderr.write("another daemon is already listening on %s\n" % socket_path)
    sys.exit(2)
except OSError:
    pass
finally:
    probe.close()
try:
    os.rename(socket_path, socket_path + ".retained." + __import__("uuid").uuid4().hex)
except FileNotFoundError:
    pass

import time, uuid
time.sleep(float(os.environ.get("KHULUMA_TEST_STUB_START_DELAY", "0") or 0))
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(5)
transcribe_count = 0
generation = str(uuid.uuid4())
loaded = None
delay_values = [s.strip() for s in os.environ.get("KHULUMA_TEST_SWIFT_DELAY_SEQUENCE", "").split("|")]
text_values = [s for s in os.environ.get("KHULUMA_TEST_SWIFT_TEXT_SEQUENCE", "").split("|")]

while True:
    conn, _ = server.accept()
    try:
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        if not data:
            continue
        req = json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
        if req.get("op") == "ping":
            resp = {
                "id": req.get("id"),
                "ok": True,
                "engine": "swift_parakeet",
                "message": "ok",
                "pid": os.getpid(),
                "generation": generation,
            }
            if loaded:
                resp["model_loaded"] = loaded
        elif os.environ.get("KHULUMA_TEST_SWIFT_DAEMON_FAIL", "0") == "1":
            resp = {
                "id": req.get("id"),
                "ok": False,
                "engine": "swift_parakeet",
                "error_code": "forced_error",
                "message": "forced daemon failure",
            }
        else:
            if req.get("op") == "transcribe" and req.get("flow") != "warmup":
                if os.environ.get("KHULUMA_TEST_SWIFT_REJECT_SUBSECOND", "0") == "1":
                    wav_path = req.get("wav_path") or ""
                    try:
                        with open(wav_path, encoding="utf-8", errors="replace") as fh:
                            marker = fh.read(200)
                        if marker.startswith("duration_ms="):
                            duration_ms = int(marker.split("=", 1)[1].splitlines()[0])
                            if duration_ms < 1000:
                                resp = {
                                    "id": req.get("id"),
                                    "ok": False,
                                    "engine": "swift_parakeet",
                                    "error_code": "runtime_error",
                                    "message": "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
                                }
                                conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")
                                continue
                    except Exception:
                        pass
                transcribe_count += 1
                idx = transcribe_count - 1
                if idx < len(delay_values) and delay_values[idx]:
                    try:
                        import time
                        time.sleep(float(delay_values[idx]))
                    except Exception:
                        pass
                text_value = os.environ.get("KHULUMA_TEST_SWIFT_TEXT", "swift transcript")
                if idx < len(text_values) and text_values[idx]:
                    text_value = text_values[idx]
            elif req.get("op") == "transcribe":
                text_value = ""
            else:
                text_value = os.environ.get("KHULUMA_TEST_SWIFT_TEXT", "swift transcript")
            if req.get("model_path") and os.environ.get("KHULUMA_TEST_STUB_NEVER_LOADS", "0") != "1":
                loaded = {"path": req["model_path"],
                          "version": os.environ.get("KHULUMA_TEST_STUB_LOADED_VERSION") or req.get("model_version") or "v3"}
            resp = {
                "id": req.get("id"),
                "ok": True,
                "engine": "swift_parakeet",
                "model": os.path.basename(req.get("model_path") or "parakeet-test"),
                "text": text_value,
                "duration_ms": 7,
            }
        conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")
    finally:
        conn.close()
PYEOF
    ;;
  version|--version)
    printf '%s\n' "khulumad test-stub"
    ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 2
    ;;
esac
EOF

  chmod +x "$STUB_DIR/ffmpeg" "$STUB_DIR/ffprobe" "$STUB_DIR/tmux" "$STUB_DIR/pbcopy" "$STUB_DIR/osascript" "$STUB_DIR/afplay" "$STUB_DIR/khulumad"
}

CASE_DIR=""

setup_case() {
  local name="$1"
  local socket_tag
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"/{home,tmp,logs,tmux-jobs,swift-model}
  mkdir -p "$CASE_DIR/config"

  # Keep the stub daemon socket short enough for macOS AF_UNIX limits.
  socket_tag="$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
  [[ -n "$socket_tag" ]] || socket_tag="khulumatest"

  : >"$CASE_DIR/config/vocab"
  cp "$ROOT/config/config.toml" "$CASE_DIR/config/config.toml"

  export HOME="$CASE_DIR/home"
  export XDG_CONFIG_HOME="$CASE_DIR/home/.config"
  export XDG_DATA_HOME="$CASE_DIR/home/.local/share"
  export PATH="$STUB_DIR:/usr/bin:/bin"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$STUB_DIR/ffmpeg" "$HOME/.local/bin/ffmpeg"
  ln -sf "$STUB_DIR/ffprobe" "$HOME/.local/bin/ffprobe"
  ln -sf "$STUB_DIR/tmux" "$HOME/.local/bin/tmux"
  ln -sf "$STUB_DIR/pbcopy" "$HOME/.local/bin/pbcopy"
  ln -sf "$STUB_DIR/osascript" "$HOME/.local/bin/osascript"
  ln -sf "$STUB_DIR/afplay" "$HOME/.local/bin/afplay"
  mkdir -p "$HOME/.local/share/sounds/khuluma"
  : >"$HOME/.local/share/sounds/khuluma/start.wav"
  : >"$HOME/.local/share/sounds/khuluma/stop.wav"
  : >"$HOME/.local/share/sounds/khuluma/process.wav"
  : >"$HOME/.local/share/sounds/khuluma/error.wav"
  : >"$HOME/.local/share/sounds/khuluma/cancel.wav"

  export KHULUMA_CONFIG_DIR="$CASE_DIR/config"
  export KHULUMA_CONFIG_FILE="$CASE_DIR/config/config.toml"
  export KHULUMA_LIB_PATH="$ROOT/bin/khuluma-lib.sh"
  export KHULUMA_STATE_FILE="$CASE_DIR/tmux.state"
  export KHULUMA_INLINE_STATE_FILE="$CASE_DIR/inline.state"
  export KHULUMA_PROCESSING_DIR="$CASE_DIR/processing"
  export KHULUMA_TMPDIR="$CASE_DIR/tmp"
  export KHULUMA_RECORD_LOG="$CASE_DIR/logs/record.log"
  export KHULUMA_TRANSCRIBE_LOG="$CASE_DIR/logs/transcribe.log"
  export KHULUMA_DAEMON_BIN="$STUB_DIR/khulumad"
  export KHULUMA_TEST_STUB_REGISTRY_DIR="$STUB_REGISTRY_DIR"
  export KHULUMA_SWIFT_PARAKEET_MODEL_PATH="$CASE_DIR/swift-model"
  export KHULUMA_SWIFT_PARAKEET_SOCKET_PATH="$TMP_ROOT/${socket_tag}.sock"
  export KHULUMA_KEEP_LOGS=1
  unset KHULUMA_HISTORY_AUDIO_RETENTION_DAYS
  export KHULUMA_AUDIO_INDEX=0
  export KHULUMA_INLINE_ACTIVATE_DELAY_MS=0
  export KHULUMA_INLINE_SEND_DELAY_MS=0
  export KHULUMA_INLINE_PASTE_TARGET=current
  unset KHULUMA_SWIFT_PARAKEET_MODEL_VERSION

  export KHULUMA_TEST_FFMPEG_LOG="$CASE_DIR/logs/ffmpeg.log"
  export KHULUMA_TEST_TMUX_LOG="$CASE_DIR/logs/tmux.log"
  export KHULUMA_TEST_OSASCRIPT_LOG="$CASE_DIR/logs/osascript.log"
  export KHULUMA_TEST_PBCOPY_OUT="$CASE_DIR/logs/pbcopy.txt"
  export KHULUMA_TEST_SOUND_LOG="$CASE_DIR/logs/sounds.log"
  export KHULUMA_TEST_TMUX_PANE="%1"
  export KHULUMA_TEST_TMUX_PANE_CMD="bash"
  export KHULUMA_TEST_FFMPEG_HOLD=0
  export KHULUMA_TEST_SWIFT_TEXT="default transcript"
  unset KHULUMA_TEST_SWIFT_DAEMON_FAIL
  unset KHULUMA_TEST_SWIFT_DELAY_SEQUENCE
  unset KHULUMA_TEST_SWIFT_TEXT_SEQUENCE
  unset KHULUMA_TEST_SWIFT_REJECT_SUBSECOND
  unset KHULUMA_TEST_FFPROBE_DURATION_MS
  unset KHULUMA_TRANSCRIBE_FILE_LOG
  unset KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE
  unset KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE_MS
  unset KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE_MIN_MS

  unset TMUX
  unset TMUX_PANE
}

# CLI fallback takes go through `inline process`: print the text it returns.
app_process_text() {
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  "$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --app Safari --record-ms "${1:-3000}" --json \
    | python3 -c 'import json, sys; r = json.load(sys.stdin); print(r["text"] if r["ok"] else "FAILED: %s" % r)'
}

run_inline_keep_logs_archive_round() {
  setup_case "inline-keep-logs-archive"
  export KHULUMA_TEST_SWIFT_TEXT="inline archive transcript"

  local text archive_dir wav_archive meta_archive transcribe_archive
  archive_dir="$CASE_DIR/config/history/inline-debug"

  text="$(app_process_text)"
  assert_contains "inline_archive_text" "$text" "inline archive transcript"
  wait_for_matching_file "$archive_dir" '*.meta' || fail "inline_archive_meta_ready"

  wav_archive="$(find "$archive_dir" -name '*.wav' -type f | head -n 1)"
  meta_archive="$(find "$archive_dir" -name '*.meta' -type f | head -n 1)"
  transcribe_archive="$(find "$archive_dir" -name '*.transcribe.log' -type f | head -n 1)"

  [[ -n "$wav_archive" && -f "$wav_archive" ]] || fail "inline_archive_wav_exists"
  pass "inline_archive_wav_exists"
  [[ -n "$meta_archive" && -f "$meta_archive" ]] || fail "inline_archive_meta_exists"
  pass "inline_archive_meta_exists"
  [[ -n "$transcribe_archive" && -f "$transcribe_archive" ]] || fail "inline_archive_transcribe_exists"
  pass "inline_archive_transcribe_exists"
  assert_file_contains "inline_archive_meta_status" "$meta_archive" "status=ok"
  assert_file_contains "inline_archive_meta_capture_bytes" "$meta_archive" "capture_wav_bytes="
  assert_file_contains "inline_archive_meta_archive_bytes" "$meta_archive" "archive_wav_bytes="
  assert_file_contains "inline_archive_meta_retention_days" "$meta_archive" "wav_retention_days=2"
  assert_file_contains "inline_archive_meta_retention_note" "$meta_archive" "retention_note="
  assert_file_not_contains "inline_archive_meta_no_stop_grace" "$meta_archive" "stop_grace_ms="
}

run_inline_audio_retention_round() {
  setup_case "inline-audio-retention"
  export KHULUMA_TEST_SWIFT_TEXT="inline retention transcript"
  export KHULUMA_HISTORY_AUDIO_RETENTION_DAYS=0

  local text archive_dir wav_archive meta_archive history_file
  archive_dir="$CASE_DIR/config/history/inline-debug"

  text="$(app_process_text)"
  assert_contains "inline_audio_retention_text" "$text" "inline retention transcript"
  wait_for_matching_file "$archive_dir" '*.meta' || fail "inline_audio_retention_meta_ready"
  wait_for_matching_file "$CASE_DIR/config/history" '*.json' || fail "inline_audio_retention_history_ready"

  wav_archive="$(find "$archive_dir" -name '*.wav' -type f | head -n 1)"
  [[ -z "$wav_archive" ]] || fail "inline_audio_retention_wav_pruned"
  pass "inline_audio_retention_wav_pruned"

  meta_archive="$(find "$archive_dir" -name '*.meta' -type f | head -n 1)"
  assert_file_contains "inline_audio_retention_meta_kept" "$meta_archive" "wav_retention_days=0"
  assert_file_contains "inline_audio_retention_meta_archive_bytes" "$meta_archive" "archive_wav_bytes="

  history_file="$(find "$CASE_DIR/config/history" -maxdepth 1 -name '*.json' -type f | head -n 1)"
  wait_for_file_contains "$history_file" "\"audio\": {" || fail "inline_audio_retention_history_audio_ready"
  pass "inline_audio_retention_history_audio_ready"
  assert_file_contains "inline_audio_retention_history_audio" "$history_file" "\"audio\": {"
  assert_file_contains "inline_audio_retention_history_retention" "$history_file" "\"wav_retention_days\": 0"
  assert_file_contains "inline_audio_retention_history_record_ms" "$history_file" "\"record_ms\":"
}

run_inline_swift_round() {
  setup_case "inline-swift"
  export KHULUMA_TEST_SWIFT_TEXT="swift backend transcript"

  local text
  text="$(app_process_text)"
  assert_contains "inline_swift_transcript" "$text" "swift backend transcript"
  assert_file_contains "inline_swift_tail_pad_ffmpeg" "$KHULUMA_TEST_FFMPEG_LOG" "anullsrc=r=16000:cl=mono"
}

run_inline_swift_tail_rescue_round() {
  setup_case "inline-swift-tail-rescue"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=20591
  export KHULUMA_TEST_SWIFT_TEXT_SEQUENCE="section by section review and then we'll go back|And we'll go back down and break down each section and then potentially rewrite then"

  local text inline_transcribe_log
  inline_transcribe_log="$CASE_DIR/tmp/khuluma-inline.transcribe.log"
  text="$(app_process_text 20591)"
  assert_contains "inline_swift_tail_rescue_merged" "$text" "section by section review and then we'll go back down and break down each section and then potentially rewrite then"
  assert_file_contains "inline_swift_tail_rescue_log" "$inline_transcribe_log" "swift_parakeet_tail_rescue:"
}

run_status_model_mode_round() {
  setup_case "status-model-mode"

  local out
  out="$("$KHULUMA_BIN" status)"
  assert_contains "status_backend_swift" "$out" "backend: swift_parakeet"
  [[ "$out" != *"mode."* && "$out" != *"postprocess"* ]] || fail "status_no_tmux_lines"
  pass "status_no_tmux_lines"
  assert_contains "status_model_swift_path" "$out" "swift_parakeet.model: $CASE_DIR/swift-model (v3)"
}

run_status_backend_round() {
  setup_case "status-backend"
  local out
  out="$("$KHULUMA_BIN" status)"
  assert_contains "status_backend_summary_headline" "$out" "headline: Dictation is ready, but the backend is cold."
  assert_contains "status_backend_requested" "$out" "backend: swift_parakeet"
  assert_contains "status_backend_model" "$out" "swift_parakeet.model: $CASE_DIR/swift-model (v3)"
}

assert_path_absent() {
  local name="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    echo "Unexpected path: $path" >&2
    fail "$name"
  fi
  pass "$name"
}

setup_transcribe_case() {
  setup_case "$1"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=5000
  export KHULUMA_TRANSCRIBE_FILE_LOG="$CASE_DIR/logs/transcribe-file.log"
  mkdir -p "$CASE_DIR/memos"
  printf '%s\n' "original memo bytes" >"$CASE_DIR/memos/memo.m4a"
  cp "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memo.orig"
}

run_transcribe_file_raw_round() {
  setup_transcribe_case "transcribe-raw"
  # Dictation cleanup that must NOT apply to file transcripts.
  printf '%s\n' 'codex -> Codex' >"$KHULUMA_CONFIG_DIR/vocab"
  export KHULUMA_TEST_SWIFT_TEXT="codex picked a color um [BLANK_AUDIO]"
  local out
  out="$("$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" 2>"$CASE_DIR/logs/stderr.txt")"

  assert_equals "transcribe_raw_stdout" "$out" "codex picked a color um"
  assert_file_contains "transcribe_raw_progress_stderr" "$CASE_DIR/logs/stderr.txt" "Transcribing $CASE_DIR/memos/memo.m4a (5s)"
  cmp -s "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memo.orig" || fail "transcribe_raw_original_untouched"
  pass "transcribe_raw_original_untouched"
  assert_file_contains "transcribe_raw_ffmpeg_input" "$KHULUMA_TEST_FFMPEG_LOG" "$CASE_DIR/memos/memo.m4a -vn"
  assert_file_contains "transcribe_raw_ffmpeg_format" "$KHULUMA_TEST_FFMPEG_LOG" "ac 1 -ar 16000 -c:a pcm_s16le"
  assert_file_not_contains "transcribe_raw_ffmpeg_never_writes_input" "$KHULUMA_TEST_FFMPEG_LOG" "pcm_s16le $CASE_DIR/memos/memo.m4a"
  assert_path_absent "transcribe_raw_no_clipboard" "$KHULUMA_TEST_PBCOPY_OUT"
  assert_path_absent "transcribe_raw_no_usage_ledger" "$KHULUMA_CONFIG_DIR/usage.json"
  assert_path_absent "transcribe_raw_no_history" "$KHULUMA_CONFIG_DIR/history"
  assert_path_absent "transcribe_raw_no_sounds" "$KHULUMA_TEST_SOUND_LOG"
  assert_path_absent "transcribe_raw_no_osascript" "$KHULUMA_TEST_OSASCRIPT_LOG"
  if compgen -G "$CASE_DIR/tmp/khuluma-transcribe.*" >/dev/null; then
    fail "transcribe_raw_temp_cleaned"
  fi
  pass "transcribe_raw_temp_cleaned"
}

run_transcribe_file_outputs_round() {
  setup_transcribe_case "transcribe-outputs"
  export KHULUMA_TEST_SWIFT_TEXT="file transcript text"
  local out rc

  out="$("$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside -q)"
  assert_equals "transcribe_beside_stdout_empty" "$out" ""
  assert_file_contains "transcribe_beside_written" "$CASE_DIR/memos/memo.txt" "file transcript text"
  local mode
  if [[ "${OSTYPE:-}" == darwin* ]]; then
    mode="$(stat -f '%Lp' "$CASE_DIR/memos/memo.txt")"
  else
    mode="$(stat -c '%a' "$CASE_DIR/memos/memo.txt")"
  fi
  assert_equals "transcribe_beside_umask_mode" "$mode" "$(printf '%o' $(( 0666 & ~$(umask) )))"

  rc=0
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside -q 2>"$CASE_DIR/logs/exists.txt" || rc=$?
  assert_equals "transcribe_beside_exists_exit" "$rc" "1"
  assert_file_contains "transcribe_beside_exists_message" "$CASE_DIR/logs/exists.txt" "use --force to overwrite"
  assert_file_not_contains "transcribe_exists_fails_before_decode" "$CASE_DIR/logs/exists.txt" "Transcribing"

  printf '%s\n' "stale" >"$CASE_DIR/memos/memo.txt"
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside --force -q
  assert_file_contains "transcribe_beside_force" "$CASE_DIR/memos/memo.txt" "file transcript text"
  assert_file_not_contains "transcribe_beside_force_replaced" "$CASE_DIR/memos/memo.txt" "stale"

  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -o "$CASE_DIR/out/one.txt" -q
  assert_file_contains "transcribe_output_file" "$CASE_DIR/out/one.txt" "file transcript text"
  if compgen -G "$CASE_DIR/memos/.khuluma-transcript.*" >/dev/null || compgen -G "$CASE_DIR/out/.khuluma-transcript.*" >/dev/null; then
    fail "transcribe_no_temp_files_in_output_dirs"
  fi
  pass "transcribe_no_temp_files_in_output_dirs"

  cp "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memos/second.mp3"
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memos/second.mp3" --out-dir "$CASE_DIR/out-dir" --format json -q
  assert_file_contains "transcribe_out_dir_json_first" "$CASE_DIR/out-dir/memo.json" '"text": "file transcript text"'
  assert_file_contains "transcribe_out_dir_json_duration" "$CASE_DIR/out-dir/second.json" '"audio_duration_ms": 5000'

  out="$("$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memos/second.mp3" -q -c)"
  assert_contains "transcribe_multi_header_first" "$out" "==> $CASE_DIR/memos/memo.m4a <=="
  assert_contains "transcribe_multi_header_second" "$out" "==> $CASE_DIR/memos/second.mp3 <=="
  assert_file_contains "transcribe_clipboard_combined" "$KHULUMA_TEST_PBCOPY_OUT" "file transcript text"

  out="$("$KHULUMA_BIN" transcribe - --format json -q <"$CASE_DIR/memos/memo.m4a")"
  assert_contains "transcribe_stdin_json_file" "$out" '"file": "stdin"'
  assert_contains "transcribe_stdin_json_engine" "$out" '"engine": "swift_parakeet"'
}

run_transcribe_file_errors_round() {
  setup_transcribe_case "transcribe-errors"
  local rc out

  rc=0
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/missing.m4a" >/dev/null 2>"$CASE_DIR/logs/missing.txt" || rc=$?
  assert_equals "transcribe_missing_exit" "$rc" "2"
  assert_file_contains "transcribe_missing_message" "$CASE_DIR/logs/missing.txt" "not a readable file"

  rc=0
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memo.orig" -o "$CASE_DIR/x.txt" >/dev/null 2>&1 || rc=$?
  assert_equals "transcribe_output_single_input_exit" "$rc" "2"

  rc=0
  "$KHULUMA_BIN" transcribe - --beside </dev/null >/dev/null 2>&1 || rc=$?
  assert_equals "transcribe_stdin_beside_rejected" "$rc" "2"

  export KHULUMA_TEST_SWIFT_DAEMON_FAIL=1
  rc=0
  out="$("$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside -q 2>"$CASE_DIR/logs/daemon.txt")" || rc=$?
  assert_equals "transcribe_daemon_fail_exit" "$rc" "1"
  assert_equals "transcribe_daemon_fail_no_stdout" "$out" ""
  assert_file_contains "transcribe_daemon_fail_message" "$CASE_DIR/logs/daemon.txt" "transcription failed"
  assert_path_absent "transcribe_daemon_fail_no_output_file" "$CASE_DIR/memos/memo.txt"
}

run_transcribe_file_no_speech_round() {
  setup_transcribe_case "transcribe-no-speech"
  export KHULUMA_TEST_SWIFT_TEXT="[BLANK_AUDIO]"
  local rc=0
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -q >/dev/null 2>"$CASE_DIR/logs/silent.txt" || rc=$?
  assert_equals "transcribe_no_speech_exit" "$rc" "1"
  assert_file_contains "transcribe_no_speech_message" "$CASE_DIR/logs/silent.txt" "no speech detected"
}

run_transcribe_file_long_round() {
  setup_transcribe_case "transcribe-long"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=1200000
  export KHULUMA_TEST_SWIFT_TEXT_SEQUENCE="alpha beta gamma delta epsilon zeta|epsilon zeta eta theta"
  local out
  out="$("$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -q)"
  assert_equals "transcribe_long_tail_rescue_merge" "$out" "alpha beta gamma delta epsilon zeta eta theta"
  assert_file_contains "transcribe_long_tail_rescue_logged" "$KHULUMA_TRANSCRIBE_FILE_LOG" "swift_parakeet_tail_rescue: duration_ms=1200000"
  assert_path_absent "transcribe_long_dictation_log_untouched" "$KHULUMA_TRANSCRIBE_LOG"
}

run_transcribe_file_no_tail_rescue_round() {
  setup_transcribe_case "transcribe-no-tail"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=1200000
  export KHULUMA_TEST_SWIFT_TEXT_SEQUENCE="only the main pass|should not appear"
  local out
  out="$("$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -q --no-tail-rescue)"
  assert_equals "transcribe_no_tail_rescue" "$out" "only the main pass"
  assert_file_not_contains "transcribe_no_tail_rescue_logged" "$KHULUMA_TRANSCRIBE_FILE_LOG" "swift_parakeet_tail_rescue"
}


run_finder_quick_action_round() {
  setup_case "finder-quick-action"
  local services="$CASE_DIR/services" workflow out
  workflow="$services/Transcribe with Khuluma.workflow"

  out="$(KHULUMA_SERVICES_DIR="$services" "$KHULUMA_BIN" finder install)"
  assert_contains "finder_install_message" "$out" "Installed Finder Quick Action: Transcribe with Khuluma"
  assert_contains "finder_install_handler" "$out" "handler: $ROOT/integrations/finder/khuluma-transcribe.sh"
  WORKFLOW="$workflow" HANDLER="$ROOT/integrations/finder/khuluma-transcribe.sh" python3 - <<'PYEOF2'
import os, plistlib
wf = os.environ["WORKFLOW"]
info = plistlib.load(open(os.path.join(wf, "Contents/Info.plist"), "rb"))
service = info["NSServices"][0]
assert service["NSMenuItem"]["default"] == "Transcribe with Khuluma"
assert service["NSRequiredContext"]["NSApplicationIdentifier"] == "com.apple.finder"
assert "public.audio" in service["NSSendFileTypes"]
doc = plistlib.load(open(os.path.join(wf, "Contents/document.wflow"), "rb"))
params = doc["actions"][0]["action"]["ActionParameters"]
assert params["inputMethod"] == 1, params["inputMethod"]
assert params["shell"] == "/bin/bash"
assert os.environ["HANDLER"] in params["COMMAND_STRING"]
assert doc["workflowMetaData"]["workflowTypeIdentifier"] == "com.apple.Automator.servicesMenu"
PYEOF2
  pass "finder_install_workflow_plists"

  out="$(KHULUMA_SERVICES_DIR="$services" "$KHULUMA_BIN" finder status)"
  assert_contains "finder_status_installed" "$out" "(installed)"
  out="$(KHULUMA_SERVICES_DIR="$services" "$KHULUMA_BIN" finder remove)"
  assert_contains "finder_remove_message" "$out" "Removed Finder Quick Action"
  assert_path_absent "finder_remove_workflow" "$workflow"
}

run_finder_handler_round() {
  setup_case "finder-handler"
  local stub="$CASE_DIR/stub-cli" args_log="$CASE_DIR/logs/cli-args.txt" notify_log="$CASE_DIR/logs/notify.txt"
  local guard="$CASE_DIR/legacy-guard" guard_log="$CASE_DIR/logs/legacy-guard.txt"
  # A refused obsolete override must not invoke any command or write logs.
  printf '#!/usr/bin/env bash\nprintf invoked >"%s"\nexit 97\n' "$guard_log" >"$guard"
  chmod +x "$guard"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit "${STUB_CLI_EXIT:-0}"\n' "$args_log" >"$stub"
  chmod +x "$stub"
  mkdir -p "$CASE_DIR/memos"
  : >"$CASE_DIR/memos/idea one.m4a"

  KHULUMA_BIN="$stub" KHULUMA_FINDER_NOTIFY_LOG="$notify_log" KHULUMA_FINDER_TRANSCRIBE_LOG="$CASE_DIR/logs/finder.log" \
    bash "$ROOT/integrations/finder/khuluma-transcribe.sh" "$CASE_DIR/memos/idea one.m4a"
  assert_file_contains "finder_handler_cli_args" "$args_log" "transcribe --beside --clipboard $CASE_DIR/memos/idea one.m4a"
  assert_path_absent "finder_handler_legacy_guard_unused" "$guard_log"
  assert_file_contains "finder_handler_notify_start" "$notify_log" "Transcribing idea one.m4a..."
  assert_file_contains "finder_handler_notify_done" "$notify_log" "Saved idea one.txt and copied it to the clipboard."

  local rc=0
  printf 'khuluma: output exists (use --force to overwrite): x.txt\n' >>"$CASE_DIR/logs/finder.log"
  STUB_CLI_EXIT=1 KHULUMA_BIN="$stub" KHULUMA_FINDER_NOTIFY_LOG="$notify_log" KHULUMA_FINDER_TRANSCRIBE_LOG="$CASE_DIR/logs/finder.log" \
    bash "$ROOT/integrations/finder/khuluma-transcribe.sh" "$CASE_DIR/memos/idea one.m4a" || rc=$?
  assert_equals "finder_handler_failure_exit_clean" "$rc" "0"
  assert_file_contains "finder_handler_notify_failure" "$notify_log" "Transcription failed: output exists"

  local before_args
  before_args="$(wc -l <"$args_log" | tr -d ' ')"
  KHULUMA_BIN="$CASE_DIR/does-not-exist" KHULUMA_FINDER_NOTIFY_LOG="$notify_log" KHULUMA_FINDER_TRANSCRIBE_LOG="$CASE_DIR/logs/finder.log" \
    bash "$ROOT/integrations/finder/khuluma-transcribe.sh" "$CASE_DIR/memos/idea one.m4a"
  assert_file_contains "finder_handler_invalid_override_refused" "$notify_log" "Configured Khuluma CLI is not executable: $CASE_DIR/does-not-exist"
  assert_equals "finder_handler_invalid_override_no_cli" "$(wc -l <"$args_log" | tr -d ' ')" "$before_args"
  assert_path_absent "finder_handler_invalid_override_no_legacy" "$guard_log"

  local notify_before
  notify_before="$(cksum <"$notify_log")"
  rc=0
  DICTATE_BIN="$guard" KHULUMA_BIN="$stub" KHULUMA_FINDER_NOTIFY_LOG="$notify_log" \
  KHULUMA_FINDER_TRANSCRIBE_LOG="$CASE_DIR/logs/refused-finder.log" \
    bash "$ROOT/integrations/finder/khuluma-transcribe.sh" "$CASE_DIR/memos/idea one.m4a" 2>"$CASE_DIR/logs/obsolete-finder.err" || rc=$?
  assert_equals "finder_handler_obsolete_override_exit" "$rc" "2"
  assert_file_contains "finder_handler_obsolete_override_error" "$CASE_DIR/logs/obsolete-finder.err" "obsolete environment input DICTATE_BIN"
  assert_file_not_contains "finder_handler_obsolete_override_no_value" "$CASE_DIR/logs/obsolete-finder.err" "$guard"
  assert_equals "finder_handler_obsolete_override_no_cli" "$(wc -l <"$args_log" | tr -d ' ')" "$before_args"
  assert_equals "finder_handler_obsolete_override_no_notify" "$(cksum <"$notify_log")" "$notify_before"
  assert_path_absent "finder_handler_obsolete_override_no_log" "$CASE_DIR/logs/refused-finder.log"
  assert_path_absent "finder_handler_obsolete_override_no_legacy" "$guard_log"
}


run_transcribe_file_daemon_unavailable_round() {
  setup_transcribe_case "transcribe-no-daemon"
  export KHULUMA_DAEMON_BIN="$CASE_DIR/missing-khulumad"
  local rc=0
  "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside >/dev/null 2>"$CASE_DIR/logs/no-daemon.txt" || rc=$?
  assert_equals "transcribe_no_daemon_exit" "$rc" "2"
  assert_file_contains "transcribe_no_daemon_message" "$CASE_DIR/logs/no-daemon.txt" "Parakeet daemon unavailable: could not start khulumad"
  assert_file_not_contains "transcribe_no_daemon_fails_before_file" "$CASE_DIR/logs/no-daemon.txt" "Transcribing"
  assert_path_absent "transcribe_no_daemon_no_output" "$CASE_DIR/memos/memo.txt"
}


run_transcribe_file_write_race_round() {
  setup_case "transcribe-write-race"
  local dir="$CASE_DIR/race" rc=0
  mkdir -p "$dir"
  # A competing writer creates the destination after the existence check
  # (simulated from the chmod step), which must not be clobbered without --force.
  RACE_DIR="$dir" bash -c '
    source "$2"
    source "$1"
    transcribe_file_log() { :; }
    chmod() { printf "%s\n" "competing notes" >"$RACE_DIR/memo.txt"; }
    transcribe_file_write_output "$RACE_DIR/memo.txt" "new transcript" 0
  ' _ "$ROOT/bin/khuluma-lib/transcribe_file.sh" "$ROOT/bin/khuluma-lib/identity.sh" 2>"$CASE_DIR/logs/race.txt" || rc=$?
  assert_equals "transcribe_race_exit" "$rc" "1"
  assert_file_contains "transcribe_race_kept_existing" "$dir/memo.txt" "competing notes"
  assert_file_contains "transcribe_race_message" "$CASE_DIR/logs/race.txt" "output exists"
  if compgen -G "$dir/.khuluma-transcript.*" >/dev/null; then
    fail "transcribe_race_temp_removed"
  fi
  pass "transcribe_race_temp_removed"
}


# Live stub daemons serving one socket.
live_stub_daemons_for() {
  local want="$1" sf pid socket_path count=0
  while IFS= read -r sf; do
    unset pid socket_path
    # shellcheck disable=SC1090
    . "$sf" 2>/dev/null || true
    if [[ "${socket_path:-}" == "$want" ]] && stub_process_matches_registry "${pid:-}" "$want"; then
      count=$((count + 1))
    fi
  done < <(find "$STUB_REGISTRY_DIR" -type f -name '*.state' 2>/dev/null || true)
  printf '%s\n' "$count"
}

# True while some process holds the flock on a lifecycle lock file.
flock_held() {
  [[ -f "$1" ]] || return 1
  python3 - "$1" <<'PYEOF'
import fcntl, sys
with open(sys.argv[1], "a") as f:
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)
sys.exit(1)
PYEOF
}

json_field() {
  python3 -c 'import json, sys
v = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else v)' "$1" "$2"
}

run_daemon_lifecycle_round() {
  setup_case "daemon-lifecycle"
  local socket="$KHULUMA_SWIFT_PARAKEET_SOCKET_PATH" meta="$KHULUMA_SWIFT_PARAKEET_SOCKET_PATH.meta"
  local out a b pid meta_pid holder lock="$KHULUMA_SWIFT_PARAKEET_SOCKET_PATH.lifecycle.lock"
  mkdir -p "$CASE_DIR/memos"
  printf '%s\n' "memo" >"$CASE_DIR/memos/m.m4a"
  # Slow starts make the launchers overlap.
  export KHULUMA_TEST_STUB_START_DELAY=0.5

  # Khuluma-style warmups, a CLI transcription and a background warmup all
  # find no daemon at once: exactly one starts, and meta names it.
  "$KHULUMA_BIN" warmup --json >"$CASE_DIR/w1.json" &
  a=$!
  "$KHULUMA_BIN" warmup --json >"$CASE_DIR/w2.json" &
  b=$!
  KHULUMA_TEST_FFPROBE_DURATION_MS=3000 "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/m.m4a" -q >"$CASE_DIR/t.txt" &
  local c=$!
  "$KHULUMA_BIN" warmup --best-effort >/dev/null &
  local d=$!
  wait "$a" "$b" "$c" "$d" || fail "lifecycle_concurrent_callers_exit_ok"
  pass "lifecycle_concurrent_callers_exit_ok"
  assert_equals "lifecycle_one_daemon" "$(live_stub_daemons_for "$socket")" "1"
  out="$(cat "$CASE_DIR/w1.json")"
  assert_equals "lifecycle_warmup_json_ready" "$(json_field "$out" state)" "ready"
  assert_equals "lifecycle_warmup_json_ready_too" "$(json_field "$(cat "$CASE_DIR/w2.json")" state)" "ready"
  assert_equals "lifecycle_warmup_json_model" "$(json_field "$out" model_loaded.path)" "$KHULUMA_SWIFT_PARAKEET_MODEL_PATH"
  [[ -n "$(json_field "$out" generation)" ]] || fail "lifecycle_warmup_json_generation"
  pass "lifecycle_warmup_json_generation"
  pid="$(json_field "$out" pid)"
  meta_pid="$(awk -F= '$1 == "pid" { print $2 }' "$meta")"
  assert_equals "lifecycle_meta_names_serving_daemon" "$meta_pid" "$pid"
  assert_file_contains "lifecycle_transcribe_worked" "$CASE_DIR/t.txt" "default transcript"
  flock_held "$lock" && fail "lifecycle_lock_released"
  pass "lifecycle_lock_released"
  # The daemon must not inherit the lock (it would hold it forever).
  "$KHULUMA_BIN" warmup --json >/dev/null
  flock_held "$lock" && fail "lifecycle_daemon_does_not_hold_lock"
  pass "lifecycle_daemon_does_not_hold_lock"

  # A daemon too slow to answer is stopped before the lock is released, so
  # it can't come up later beside one someone else starts.
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"
  export KHULUMA_TEST_STUB_START_DELAY=3
  out="$(KHULUMA_DAEMON_START_WAIT_SECONDS=1 "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_slow_start_unavailable" "$(json_field "$out" state)" "unavailable"
  assert_file_contains "lifecycle_slow_start_logged" "$KHULUMA_TRANSCRIBE_LOG" "did not answer within 1s; stopping it"
  sleep 3
  assert_equals "lifecycle_slow_start_stopped" "$(live_stub_daemons_for "$socket")" "0"
  unset KHULUMA_TEST_STUB_START_DELAY
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"

  # Ready means this daemon holds this model and version.
  out="$(KHULUMA_TEST_STUB_LOADED_VERSION=v2 "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_other_version_not_ready" "$(json_field "$out" state)" "warming"
  assert_equals "lifecycle_other_version_reason" "$(json_field "$out" reason)" "model_changed"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"
  out="$(KHULUMA_TEST_STUB_NEVER_LOADS=1 "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_cold_not_ready" "$(json_field "$out" state)" "warming"
  assert_equals "lifecycle_cold_reason" "$(json_field "$out" reason)" "cold"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"

  # A daemon that accepts but never answers is never unlinked or doubled.
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"
  python3 - "$socket" "$CASE_DIR/hung.ready" <<'PYEOF' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1]); s.listen(16)
open(sys.argv[2], "w").close()
conns = []
end = time.time() + 30
while time.time() < end:
    s.settimeout(0.2)
    try:
        conns.append(s.accept()[0])
    except OSError:
        pass
PYEOF
  holder=$!
  for _ in {1..100}; do [[ -f "$CASE_DIR/hung.ready" ]] && break; sleep 0.05; done
  [[ -f "$CASE_DIR/hung.ready" ]] || fail "lifecycle_hung_daemon_started"
  out="$(KHULUMA_SWIFT_PARAKEET_PING_TIMEOUT_SECONDS=0.5 "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_hung_daemon_unavailable" "$(json_field "$out" state)" "unavailable"
  [[ -S "$socket" ]] || fail "lifecycle_hung_socket_kept"
  pass "lifecycle_hung_socket_kept"
  assert_file_contains "lifecycle_hung_logged" "$KHULUMA_TRANSCRIBE_LOG" "does not answer; not starting another"
  assert_equals "lifecycle_hung_no_second_daemon" "$(live_stub_daemons_for "$socket")" "0"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

  # A socket left by a crashed daemon (nobody accepting) is replaced.
  [[ -S "$socket" ]] || fail "lifecycle_stale_socket_left"
  out="$("$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_stale_socket_replaced" "$(json_field "$out" state)" "ready"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"

  # Someone else is mid-start: report warming instead of piling on.
  python3 - "$lock" "$CASE_DIR/lock.ready" <<'PYEOF' &
import fcntl, sys, time
f = open(sys.argv[1], "a")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)
PYEOF
  holder=$!
  for _ in {1..100}; do [[ -f "$CASE_DIR/lock.ready" ]] && break; sleep 0.05; done
  out="$(KHULUMA_DAEMON_LIFECYCLE_WAIT_SECONDS=0 "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_lock_held_warming" "$(json_field "$out" state)" "warming"
  assert_equals "lifecycle_lock_held_reason" "$(json_field "$out" reason)" "starting"
  assert_equals "lifecycle_lock_held_no_daemon" "$(live_stub_daemons_for "$socket")" "0"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  # Its holder died: the kernel released the lock.
  out="$("$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_dead_lock_reclaimed" "$(json_field "$out" state)" "ready"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"

  # A socket dir that doesn't exist yet (fresh install, custom path).
  out="$(KHULUMA_SWIFT_PARAKEET_SOCKET_PATH="$TMP_ROOT/fresh/d.sock" "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_fresh_socket_dir" "$(json_field "$out" state)" "ready"
  cleanup_stub_daemons

  out="$(KHULUMA_DAEMON_BIN="$CASE_DIR/missing-daemon" "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_missing_binary_unavailable" "$(json_field "$out" state)" "unavailable"
  assert_equals "lifecycle_missing_binary_reason" "$(json_field "$out" reason)" "no_daemon_binary"
  out="$(KHULUMA_SWIFT_PARAKEET_MODEL_PATH= "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_no_model_reason" "$(json_field "$out" reason)" "no_model"
  out="$(KHULUMA_TEST_SWIFT_DAEMON_FAIL=1 "$KHULUMA_BIN" warmup --json)"
  assert_equals "lifecycle_warmup_error_unavailable" "$(json_field "$out" state)" "unavailable"
  assert_equals "lifecycle_warmup_error_code" "$(json_field "$out" reason)" "forced_error"
  cleanup_stub_daemons
}

run_daemon_build_and_refresh_round() {
  setup_case "daemon-refresh"
  unset KHULUMA_DAEMON_BIN
  local src="$CASE_DIR/daemon-src" build="$CASE_DIR/daemon-build" build_log="$CASE_DIR/logs/swift-build.log"
  mkdir -p "$src/Sources/khulumad" "$src/Sources/KhulumaDaemonKit" "$src/Tests/KhulumaDaemonKitTests"
  printf '%s\n' '// shared runtime fixture' >"$src/Sources/KhulumaDaemonKit/Runtime.swift"
  printf '%s\n' '// swift-tools-version: 6.0' >"$src/Package.swift"
  printf '%s\n' 'print("v1")' >"$src/Sources/khulumad/main.swift"
  printf '%s\n' '// tests' >"$src/Tests/KhulumaDaemonKitTests/T.swift"
  export KHULUMA_DAEMON_SOURCE_ROOT="$src"
  export KHULUMA_DAEMON_BUILD_ROOT="$build"
  export KHULUMA_DAEMON_BACKGROUND_REFRESH=0
  export KHULUMA_DAEMON_RESTART_WAIT_SECONDS=0
  export KHULUMA_TEST_SWIFT_BUILD_LOG="$build_log"
  export KHULUMA_TEST_STUB_DAEMON="$STUB_DIR/khulumad"
  cat >"$HOME/.local/bin/swift" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "build" ]] || exit 0
printf '%s\n' "$*" >>"$KHULUMA_TEST_SWIFT_BUILD_LOG"
[[ "${KHULUMA_TEST_SWIFT_BUILD_FAIL:-0}" == "1" ]] && { echo "error: Build failed" >&2; exit 1; }
[[ -d Tests ]] || { echo "error: invalid custom path 'Tests/KhulumaDaemonKitTests'" >&2; exit 1; }
mkdir -p .build/release
cp "$KHULUMA_TEST_STUB_DAEMON" .build/release/khulumad
chmod +x .build/release/khulumad
EOF
  chmod +x "$HOME/.local/bin/swift"
  local socket="$KHULUMA_SWIFT_PARAKEET_SOCKET_PATH" meta="$KHULUMA_SWIFT_PARAKEET_SOCKET_PATH.meta"
  local builds stamp pid1 pid2 hash out

  # A first build that failed recently is reported, not retried on every call.
  date +%s >"$build.build-failed"
  out="$(KHULUMA_DAEMON_BACKGROUND_REFRESH=1 "$KHULUMA_BIN" warmup --json)"
  assert_equals "daemon_failed_build_unavailable" "$(json_field "$out" reason)" "build_failed"
  [[ -s "$build_log" ]] && fail "daemon_failed_build_not_retried"
  pass "daemon_failed_build_not_retried"
  preserve_fixture "$build.build-failed"

  # First use: sources synced into the build root, built once, daemon started.
  "$KHULUMA_BIN" warmup >/dev/null
  builds="$(grep -c . "$build_log")"
  assert_equals "daemon_first_build" "$builds" "1"
  assert_file_contains "daemon_sources_synced" "$build/Sources/khulumad/main.swift" 'print("v1")'
  [[ -d "$build/Tests" ]] || fail "daemon_tests_dir_synced"
  pass "daemon_tests_dir_synced"
  stamp="$(cat "$build/.build/khuluma-built-source-hash")"
  assert_file_contains "daemon_meta_records_build" "$meta" "source_hash=$stamp"
  pid1="$(awk -F= '$1 == "pid" { print $2 }' "$meta")"

  # Malformed renamed source must not compare as empty==empty, compile,
  # advance the stamp or stop the already serving daemon.
  mv "$src/Sources/KhulumaDaemonKit" "$CASE_DIR/kit-source-retained"
  "$KHULUMA_BIN" warmup --restart-stale >"$CASE_DIR/logs/invalid-source.txt" 2>&1 || true
  assert_equals "daemon_invalid_source_never_builds" "$(grep -c . "$build_log")" "1"
  assert_equals "daemon_invalid_source_keeps_stamp" "$(cat "$build/.build/khuluma-built-source-hash")" "$stamp"
  assert_equals "daemon_invalid_source_keeps_owner" "$(awk -F= '$1 == "pid" { print $2 }' "$meta")" "$pid1"
  python3 - "$socket" <<'PYINVALID' || fail "daemon_invalid_source_keeps_serving"
import json, socket, sys
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(2)
    client.connect(sys.argv[1])
    client.sendall(b'{"id":"invalid-source-check","op":"ping"}\n')
    assert json.loads(client.makefile("rb").readline())["ok"] is True
PYINVALID
  pass "daemon_invalid_source_keeps_serving"
  mv "$CASE_DIR/kit-source-retained" "$src/Sources/KhulumaDaemonKit"

  # Unchanged sources: no rebuild.
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_no_rebuild_when_current" "$(grep -c . "$build_log")" "1"

  # Khuluma app sources share the package but are not part of the daemon.
  mkdir -p "$src/Sources/Khuluma"
  printf '%s\n' '// app-only change' >"$src/Sources/Khuluma/AppController.swift"
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_ignores_app_sources" "$(grep -c . "$build_log")" "1"

  # A busy pipeline blocks the swap even though a new build exists.
  printf '%s\n' 'print("v2")' >"$src/Sources/khulumad/main.swift"
  mkdir -p "$KHULUMA_PROCESSING_DIR"
  printf 'pid=%s\nkind=inline\nphase=processing\n' "$$" >"$KHULUMA_PROCESSING_DIR/inline-khuluma-busy"
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_rebuilt_on_source_change" "$(grep -c . "$build_log")" "2"
  assert_equals "daemon_not_restarted_while_busy" "$(awk -F= '$1 == "pid" { print $2 }' "$meta")" "$pid1"
  assert_file_contains "daemon_busy_logged" "$KHULUMA_TRANSCRIBE_LOG" "daemon still busy"
  preserve_fixture "$KHULUMA_PROCESSING_DIR/inline-khuluma-busy"

  # A Khuluma take in any phase (recording included) keeps the old daemon.
  local take_owner
  sleep 60 &
  take_owner=$!
  mkdir -p "$KHULUMA_PROCESSING_DIR"
  printf 'pid=%s\nkind=inline\nsession_id=t1\nphase=recording\n' "$take_owner" >"$KHULUMA_PROCESSING_DIR/inline-khuluma-t1"
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_not_restarted_mid_recording" "$(awk -F= '$1 == "pid" { print $2 }' "$meta")" "$pid1"
  # A marker whose owner died (Khuluma crashed) is pruned rather than
  # blocking upgrades forever; so is one abandoned before its pid was written.
  kill "$take_owner" 2>/dev/null; wait "$take_owner" 2>/dev/null || true
  : >"$KHULUMA_PROCESSING_DIR/inline-khuluma-t2"
  touch -t 202001010000 "$KHULUMA_PROCESSING_DIR/inline-khuluma-t2"

  # Idle: the out-of-date daemon is replaced by one started from the new build.
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  pid2="$(awk -F= '$1 == "pid" { print $2 }' "$meta")"
  [[ -n "$pid2" && "$pid2" != "$pid1" ]] || fail "daemon_restarted_when_idle"
  pass "daemon_restarted_when_idle"
  assert_path_absent "daemon_dead_take_marker_pruned" "$KHULUMA_PROCESSING_DIR/inline-khuluma-t1"
  assert_path_absent "daemon_abandoned_marker_pruned" "$KHULUMA_PROCESSING_DIR/inline-khuluma-t2"
  assert_equals "daemon_meta_names_new_daemon" "$(json_field "$("$KHULUMA_BIN" warmup --json)" pid)" "$pid2"
  kill -0 "$pid1" 2>/dev/null && fail "daemon_old_process_stopped"
  pass "daemon_old_process_stopped"
  hash="$(cat "$build/.build/khuluma-built-source-hash")"
  assert_file_contains "daemon_meta_updated" "$meta" "source_hash=$hash"
  assert_equals "daemon_no_extra_build_on_restart" "$(grep -c . "$build_log")" "2"

  # Hot path with an outdated binary: start it now, never build inline.
  printf '%s\n' 'print("v3")' >"$src/Sources/khulumad/main.swift"
  kill "$pid2" 2>/dev/null || true
  wait_for_absent "$socket" 60 || preserve_fixture "$socket"
  mkdir -p "$CASE_DIR/memos"
  printf '%s\n' "memo" >"$CASE_DIR/memos/m.m4a"
  KHULUMA_TEST_FFPROBE_DURATION_MS=3000 "$KHULUMA_BIN" transcribe "$CASE_DIR/memos/m.m4a" -q >/dev/null
  assert_equals "daemon_hot_path_never_builds" "$(grep -c . "$build_log")" "2"
  assert_file_contains "daemon_hot_path_uses_stale" "$CASE_DIR/tmp/khuluma-file.transcribe.log" "out of date; using it now"
  assert_file_contains "daemon_hot_path_never_syncs" "$build/Sources/khulumad/main.swift" 'print("v2")'

  # A build lock held by a live process blocks a concurrent refresh...
  sleep 60 &
  local holder=$!
  mkdir -p "$build.build.lock"
  printf '%s\n' "$holder" >"$build.build.lock/pid"
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_live_lock_blocks_build" "$(grep -c . "$build_log")" "2"
  assert_file_contains "daemon_live_lock_logged" "$KHULUMA_TRANSCRIBE_LOG" "another khulumad build is running"
  # ...and is reclaimed once its owner is gone.
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_dead_lock_reclaimed" "$(grep -c . "$build_log")" "3"
  [[ -d "$build.build.lock" ]] && fail "daemon_lock_released"
  pass "daemon_lock_released"
  printf '%s\n' 'print("v4")' >"$src/Sources/khulumad/main.swift"

  # A failed rebuild keeps the working binary.
  KHULUMA_TEST_SWIFT_BUILD_FAIL=1 "$KHULUMA_BIN" warmup --restart-stale >/dev/null
  assert_file_contains "daemon_failed_rebuild_keeps_binary" "$KHULUMA_TRANSCRIBE_LOG" "rebuilding khulumad failed; keeping the existing binary"
  [[ -x "$build/.build/release/khulumad" ]] || fail "daemon_binary_still_present"
  pass "daemon_binary_still_present"
  [[ -s "$build.build-failed" ]] || fail "daemon_failed_build_recorded"
  pass "daemon_failed_build_recorded"

  unset KHULUMA_DAEMON_SOURCE_ROOT KHULUMA_DAEMON_BUILD_ROOT KHULUMA_DAEMON_BACKGROUND_REFRESH KHULUMA_DAEMON_RESTART_WAIT_SECONDS
  unset KHULUMA_TEST_SWIFT_BUILD_LOG KHULUMA_TEST_STUB_DAEMON
}


run_dictation_cleanup_round() {
  setup_case "dictation-cleanup"
  printf '[meta]\nconfig_version = 1\n\n[clean]\nenabled = true\nrepeats_level = 3\n' >"$KHULUMA_CONFIG_FILE"
  printf '%s\n' 'PN PM::pnpm' 'pnpm::pnpm' 'Kaluma::Khuluma' 'X code::Xcode' >"$KHULUMA_CONFIG_DIR/vocab"
  local input='Um, I think we should use PN PM. I think we should use PN PM. Then open Kaluma in X code.'
  local out
  out="$(printf '%s' "$input" | "$KHULUMA_BIN" inline cleanup --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["cleanup"]["clean"] == "1" and r["cleanup"]["repeats_level"] == "3", r
assert r["raw_text"] == "I think we should use PN PM. Then open Kaluma in X code.", r
assert r["text"] == "I think we should use pnpm. Then open Khuluma in Xcode.", r
' || fail "dictation_config_cleanup"
  pass "dictation_config_cleanup"
  out="$(KHULUMA_CLEAN=0 "$KHULUMA_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["cleanup"]["clean"] == "0"' \
    || fail "dictation_env_override"
  out="$(printf '%s' "$input" | KHULUMA_CLEAN=0 "$KHULUMA_BIN" inline cleanup --json)"
  printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["raw_text"].startswith("Um,") and r["raw_text"].count("I think") == 2, r' \
    || fail "dictation_env_disables_processing"
  pass "dictation_env_override"
  out="$("$KHULUMA_BIN" repeats 3)"
  assert_contains "dictation_repeats_level3" "$out" 'repeats_level: 3'
  out="$("$KHULUMA_BIN" status --json)"
  printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); c=r["effective_settings"]["clean"]; assert c["regex"] is True and c["repeats_level"] == 3, r' \
    || fail "dictation_status_config"
  pass "dictation_status_config"
  printf '[clean]\nenabled = "false"\n' >"$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert "clean.enabled must be true or false" in r["config"]["error"] and r["config"]["source"] == "last_good", r' \
    || fail "dictation_enabled_type_validation"
  pass "dictation_enabled_type_validation"
}

run_app_backend_round() {
  setup_case "app-backend"
  export KHULUMA_TEST_SWIFT_TEXT="codex app transcript"
  printf '%s\n' 'codex -> Codex' >"$KHULUMA_CONFIG_DIR/vocab"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local out

  out="$("$KHULUMA_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
c = json.load(sys.stdin)
assert c["schema_version"] == 1, c
assert c["hotkey"] == "ctrl+option+space", c["hotkey"]
assert set(c["sounds"]) == {"start", "stop", "process", "error", "cancel"}, c["sounds"]
assert c["sounds"]["start"]["path"].endswith("/khuluma/start.wav"), c["sounds"]["start"]
assert c["inline"]["send_mode"] in ("enter", "cmd_enter", "ctrl_j"), c["inline"]
assert c["inline"]["send_delay_ms"] == 0 and c["inline"]["activate_delay_ms"] == 0, c["inline"]
cl = c["cleanup"]
assert cl["config_dir"] and cl["vocab_clean"] == "1" and cl["british_spelling"] == "1", cl
removed = ("force_mode", "code_paragraph_min_words", "long_paragraph_min_words", "postprocess")
assert not any(key in cl for key in removed), cl
' || fail "app_config_json_shape"
  pass "app_config_json_shape"

  out="$(KHULUMA_CLEAN=1 KHULUMA_REPEATS_LEVEL=2 "$KHULUMA_BIN" app-config --json)"
  assert_contains "app_config_cleanup_env" "$out" '"clean": "1", "repeats_level": "2"'

  # An unexported LC_ALL=C from ~/.zshenv must not hide the exported UTF-8
  # LANG that grep/sed inherit: the native pipeline has to fall back.
  printf '%s\n' 'LC_ALL=C' >"$HOME/.zshenv"
  out="$(env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG=en_US.UTF-8 "$KHULUMA_BIN" app-config --json)"
  assert_contains "app_config_locale_exported_lang" "$out" '"locale_ctype": "en_US.UTF-8", "locale_collate": "en_US.UTF-8"'
  printf '%s\n' 'export LC_ALL=C' >"$HOME/.zshenv"
  out="$(env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG=en_US.UTF-8 "$KHULUMA_BIN" app-config --json)"
  assert_contains "app_config_locale_exported_c" "$out" '"locale_ctype": "C", "locale_collate": "C"'
  preserve_fixture "$HOME/.zshenv"

  out="$(printf 'um the the codex [blank audio] color\n\n' | KHULUMA_CLEAN=1 "$KHULUMA_BIN" inline cleanup --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok", r
assert r["raw_text"] == "the codex color", r["raw_text"]
assert r["text"] == "the Codex colour", r["text"]
assert r["cleanup"]["clean"] == "1", r["cleanup"]
' || { echo "$out" >&2; fail "app_inline_cleanup_json"; }
  pass "app_inline_cleanup_json"

  out="$(printf '[blank audio]' | "$KHULUMA_BIN" inline cleanup --json)"
  assert_contains "app_inline_cleanup_no_speech" "$out" '"status": "no_speech"'

  out="$(KHULUMA_APP_HOTKEY="cmd+shift+d" "$KHULUMA_BIN" app-config --json)"
  assert_contains "app_config_hotkey_override" "$out" '"hotkey": "cmd+shift+d"'
  out="$(KHULUMA_INLINE_PROCESS_SOUND=0 "$KHULUMA_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c 'import json,sys; assert json.load(sys.stdin)["inline"]["process_sound"] is False' \
    || fail "app_config_process_sound_override"
  pass "app_config_process_sound_override"

  out="$("$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --app Safari --record-ms 3000 --startup-ms 9 --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok", r
assert r["text"] == "Codex app transcript", r["text"]
assert r["raw_text"] == "codex app transcript", r["raw_text"]
assert r["delivery"]["autosend"] is True and r["delivery"]["paste_target"] == "current", r["delivery"]
assert r["timings"]["record_ms"] == 3000, r["timings"]
assert r["history_saved"] is True, r
' || { echo "$out" >&2; fail "app_process_json_ok"; }
  pass "app_process_json_ok"
  # history_saved is reported once the entry is on disk, not in the background.
  assert_equals "app_process_history_on_disk" "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" "1"
  assert_file_contains "app_process_history_text" "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json)" '"processed": "Codex app transcript"'
  assert_path_absent "app_process_no_clipboard" "$KHULUMA_TEST_PBCOPY_OUT"
  assert_path_absent "app_process_no_osascript" "$KHULUMA_TEST_OSASCRIPT_LOG"
  assert_path_absent "app_process_no_sounds" "$KHULUMA_TEST_SOUND_LOG"
  assert_file_contains "app_process_usage_recorded" "$KHULUMA_CONFIG_DIR/usage.json" '"inline": 1'
  assert_file_contains "app_process_bench_source" "$KHULUMA_CONFIG_DIR/history/bench.tsv" "app:avaudioengine"
  [[ -f "$CASE_DIR/take.wav" ]] || fail "app_process_keeps_callers_wav"
  pass "app_process_keeps_callers_wav"

  # --defer-usage: history and bench as usual, but usage waits for the app to
  # report the delivery (`inline record` usage_only), so a failed paste is
  # never counted.
  local bench_rows history_files
  bench_rows="$(wc -l <"$KHULUMA_CONFIG_DIR/history/bench.tsv" | tr -d ' ')"
  out="$("$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --app Safari --record-ms 3000 --defer-usage --json)"
  assert_equals "app_process_defer_usage_flag" "$(json_field "$out" usage_deferred)" "True"
  assert_equals "app_process_defer_usage_not_counted" "$(json_field "$("$KHULUMA_BIN" usage --json)" delivered_dictations.count)" "1"
  assert_equals "app_process_defer_usage_bench" "$(wc -l <"$KHULUMA_CONFIG_DIR/history/bench.tsv" | tr -d ' ')" "$((bench_rows + 1))"
  history_files="$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')"
  printf '%s' '{"take_id":"deferred-1","status":"ok","delivered":true,"usage_only":true,"text":"Codex app transcript",
    "record_ms":3000,"started_at_ms":1000,"delivered_at_ms":5000,"delivered_local_date":"2026-10-15"}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/usage-only.json"
  assert_file_contains "app_usage_only_recorded" "$CASE_DIR/usage-only.json" '"usage_recorded": true'
  assert_equals "app_usage_only_counted_once" "$(json_field "$("$KHULUMA_BIN" usage --json)" delivered_dictations.count)" "2"
  assert_equals "app_usage_only_no_bench_row" "$(wc -l <"$KHULUMA_CONFIG_DIR/history/bench.tsv" | tr -d ' ')" "$((bench_rows + 1))"
  assert_equals "app_usage_only_no_history" "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" "$history_files"
  assert_file_contains "app_usage_only_day" "$KHULUMA_CONFIG_DIR/usage.json" '"2026-10-15"'
  printf '%s' '{"take_id":"deferred-1","status":"ok","delivered":true,"usage_only":true,"text":"Codex app transcript"}' \
    | "$KHULUMA_BIN" inline record --json >/dev/null
  assert_equals "app_usage_only_replay_once" "$(json_field "$("$KHULUMA_BIN" usage --json)" delivered_dictations.count)" "2"

  # A history write that fails still hands the text back, but says so:
  # Khuluma then keeps the take's Quit copy instead of settling it.
  history_files="$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')"
  chmod 500 "$KHULUMA_CONFIG_DIR/history"
  out="$("$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --app Safari --record-ms 3000 --defer-usage --json)"
  chmod 700 "$KHULUMA_CONFIG_DIR/history"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok" and r["text"] == "Codex app transcript", r
assert r["history_saved"] is False, r
' || { echo "$out" >&2; fail "app_process_history_failed"; }
  pass "app_process_history_failed"
  assert_equals "app_process_history_failed_no_entry" "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" "$history_files"
}

# `inline record` dedups history/bench and usage separately: a replay after
# a crash between them never counts usage twice, and a usage write that
# failed is retried without writing history again.
run_inline_record_usage_retry_round() {
  setup_case "inline-record-usage"
  local cache="$KHULUMA_CONFIG_DIR/.cache" ledger="$KHULUMA_CONFIG_DIR/usage.json" history_files

  printf '%s' '{"take_id":"t-crash","status":"ok","delivered":true,"raw_text":"a b","text":"a b","record_ms":1000}' \
    | "$KHULUMA_BIN" inline record --json >/dev/null
  # Crash after the usage write, before the take was marked recorded.
  : >"$cache/recorded-takes"
  : >"$cache/recorded-takes-history"
  printf '%s' '{"take_id":"t-crash","status":"ok","delivered":true,"raw_text":"a b","text":"a b","record_ms":1000}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/replay.json"
  assert_file_contains "inline_record_crash_replay_usage_ok" "$CASE_DIR/replay.json" '"usage_recorded": true'
  assert_equals "inline_record_crash_replay_counted_once" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$ledger")" "1"

  # A usage write that fails (unreadable ledger): history is saved, usage is
  # retried on replay once the ledger is readable again.
  cp "$ledger" "$CASE_DIR/ledger.good"
  printf 'not json' >"$ledger"
  printf '%s' '{"take_id":"t-retry","status":"ok","delivered":true,"raw_text":"c d e","text":"c d e","record_ms":2000}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/retry-1.json" 2>/dev/null
  assert_file_contains "inline_record_usage_failed" "$CASE_DIR/retry-1.json" '"usage_recorded": false'
  assert_file_contains "inline_record_usage_failed_history" "$CASE_DIR/retry-1.json" '"history_saved": true'
  assert_file_contains "inline_record_usage_dedup_flag" "$CASE_DIR/retry-1.json" '"usage_dedup": true'
  history_files="$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')"
  mv -f "$CASE_DIR/ledger.good" "$ledger"
  printf '%s' '{"take_id":"t-retry","status":"ok","delivered":true,"raw_text":"c d e","text":"c d e","record_ms":2000}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/retry-2.json"
  assert_file_contains "inline_record_usage_retried" "$CASE_DIR/retry-2.json" '"usage_recorded": true'
  assert_equals "inline_record_usage_retry_counted" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$ledger")" "2"
  assert_equals "inline_record_usage_retry_no_second_history" \
    "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" "$history_files"
  printf '%s' '{"take_id":"t-retry","status":"ok","delivered":true,"text":"c d e"}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/retry-3.json"
  assert_file_contains "inline_record_usage_retry_then_final" "$CASE_DIR/retry-3.json" '"duplicate": true'

  # A history write that fails: usage is counted, the take isn't final, and a
  # replay saves the history without a second bench row or usage count.
  local bench_rows
  bench_rows="$(wc -l <"$KHULUMA_CONFIG_DIR/history/bench.tsv" | tr -d ' ')"
  chmod 500 "$KHULUMA_CONFIG_DIR/history"
  printf '%s' '{"take_id":"t-hist","status":"ok","delivered":true,"raw_text":"f g","text":"f g","record_ms":700}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/hist-1.json" 2>/dev/null
  chmod 700 "$KHULUMA_CONFIG_DIR/history"
  assert_file_contains "inline_record_history_failed" "$CASE_DIR/hist-1.json" '"history_saved": false'
  if grep -qxF t-hist "$cache/recorded-takes"; then fail "inline_record_history_failed_not_final"; fi
  pass "inline_record_history_failed_not_final"
  history_files="$(ls "$KHULUMA_CONFIG_DIR/history"/*.json 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' '{"take_id":"t-hist","status":"ok","delivered":true,"raw_text":"f g","text":"f g","record_ms":700}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/hist-2.json"
  assert_file_contains "inline_record_history_retried" "$CASE_DIR/hist-2.json" '"history_saved": true'
  assert_equals "inline_record_history_retry_saved" "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" "$((history_files + 1))"
  assert_equals "inline_record_history_retry_one_bench_row" "$(wc -l <"$KHULUMA_CONFIG_DIR/history/bench.tsv" | tr -d ' ')" "$((bench_rows + 1))"
  assert_equals "inline_record_history_retry_usage_once" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$ledger")" "3"
  grep -qxF t-hist "$cache/recorded-takes" || fail "inline_record_history_retry_final"
  pass "inline_record_history_retry_final"

  # No take id or delivery date (older apps): counted, on bash 3.2 too.
  printf '%s' '{"status":"ok","delivered":true,"text":"no id"}' | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/no-id.json"
  assert_file_contains "inline_record_without_take_id" "$CASE_DIR/no-id.json" '"usage_recorded": true'

  # The delivery date Khuluma sends wins over the date the record is written.
  printf '%s' '{"take_id":"t-late","status":"ok","delivered":true,"text":"late","record_ms":500,"delivered_local_date":"2026-01-02"}' \
    | "$KHULUMA_BIN" inline record --json >/dev/null
  assert_file_contains "inline_record_delivery_date_bucket" "$ledger" '"2026-01-02"'
}

# Per-day usage buckets: local-date keys, coverage when an older writer also
# records, exactly-once take ids, and `usage --json --days`.
run_usage_daily_round() {
  setup_case "usage-daily"
  local ledger="$KHULUMA_CONFIG_DIR/usage.json" out before
  usage_rec() { bash -c 'source "$1"; shift; usage_record_delivery "$@"' _ "$ROOT/bin/khuluma-lib/history.sh" "$@"; }
  ledger_check() { python3 -c "import json,sys; p=json.load(open(sys.argv[1])); $2" "$ledger" || fail "$1"; pass "$1"; }

  # A ledger from before daily buckets is upgraded on the next delivery.
  printf '%s\n' '{"schema_version":1,"tracking_started_at":"2026-09-19T06:30:53Z","delivered_dictations":{"count":80,"by_flow":{"inline":80,"tmux":0}},"processed_words":24306,"recording_duration_ms":8112000,"full_elapsed_duration_ms":8484000}' >"$ledger"
  # 21:30 UTC is already the 15th in Dubai.
  TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-14T21:30:00Z usage_rec inline "hello there zqxsentinel" 3000 3500 --take-id take-1 \
    || fail "usage_daily_record"
  ledger_check "usage_daily_upgrade" '
assert p["delivered_dictations"]["count"] == 81 and p["processed_words"] == 24309, p
d = p["daily"]
assert d["baseline_count"] == 80 and d["started_at"] == "2026-10-14T21:30:00Z", d
assert d["days"] == {"2026-10-15": {"count": 1, "inline": 1, "tmux": 0, "words": 3, "recording_ms": 3000,
    "full_elapsed_ms": 3500, "longest_recording_ms": 3000, "most_words": 3}}, d
assert p["recent_take_ids"] == {"take-1": "2026-10-15"}, p'

  before="$(cksum <"$ledger")"
  TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-14T21:31:00Z usage_rec inline "hello there zqxsentinel" 3000 3500 --take-id take-1 \
    || fail "usage_daily_replay_rc"
  assert_equals "usage_daily_replay_is_noop" "$(cksum <"$ledger")" "$before"

  # Replayed the next day with its delivery date; then a tmux take today.
  TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T08:00:00Z usage_rec inline "one two" 1000 1200 --take-id take-2 --local-date 2026-10-15
  TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T08:00:00Z usage_rec tmux "a b c d" 5000 5400
  ledger_check "usage_daily_buckets" '
days = p["daily"]["days"]
assert days["2026-10-15"]["count"] == 2 and days["2026-10-15"]["words"] == 5, days
assert days["2026-10-15"]["longest_recording_ms"] == 3000 and days["2026-10-15"]["most_words"] == 3, days
assert days["2026-10-16"] == {"count": 1, "inline": 0, "tmux": 1, "words": 4, "recording_ms": 5000,
    "full_elapsed_ms": 5400, "longest_recording_ms": 5000, "most_words": 4}, days
assert set(p["recent_take_ids"]) == {"take-1", "take-2"}, p'

  # An older CLI writing the same ledger keeps the new sections intact; its
  # delivery has no day and shows up as untracked.
  cp "$ledger" "$CASE_DIR/before-v1.json"
  bash -c 'source "$1"; source "$2"; usage_record_delivery_v1 inline "older cli" 1000 1100' _ \
    "$ROOT/bin/khuluma-lib/history.sh" "$ROOT/tests/fixtures/usage_writer_v1.sh" || fail "usage_daily_v1_writer"
  python3 - "$CASE_DIR/before-v1.json" "$ledger" <<'PYEOF' || fail "usage_daily_v1_writer_preserves"
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:])
assert b["delivered_dictations"]["count"] == a["delivered_dictations"]["count"] + 1, b
assert b["daily"] == a["daily"] and b["recent_take_ids"] == a["recent_take_ids"], b
PYEOF
  pass "usage_daily_v1_writer_preserves"

  out="$(TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T09:00:00Z "$KHULUMA_BIN" usage --json --days 7)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["command"] == "usage" and r["schema_version"] == 1, r
assert r["coverage"]["status"] == "active" and r["coverage"]["daily_tracking_started_at"] == "2026-10-14T21:30:00Z", r
d = r["daily"]
assert d["status"] == "active" and d["as_of_local_date"] == "2026-10-16", d
assert d["range"] == {"from": "2026-10-10", "to": "2026-10-16"}, d
assert d["untracked_deliveries"] == 1, d
assert [x["date"] for x in d["days"]] == ["2026-10-15", "2026-10-16"], d
assert d["days"][1] == {"date": "2026-10-16", "count": 1, "words": 4, "recording_ms": 5000, "full_elapsed_ms": 5400,
    "longest_recording_ms": 5000, "most_words": 4, "by_flow": {"inline": 0, "tmux": 1}}, d
' || { echo "$out" >&2; fail "usage_days_json"; }
  pass "usage_days_json"
  out="$(TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T09:00:00Z "$KHULUMA_BIN" usage --days 1 --json)"
  assert_equals "usage_days_slice" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["daily"]; print([x["date"] for x in d["days"]], d["untracked_deliveries"])')" "['2026-10-16'] 1"
  out="$(TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T09:00:00Z "$KHULUMA_BIN" usage --json --days all)"
  assert_equals "usage_days_all_range" "$(json_field "$out" daily.range.from)" "2026-10-15"
  out="$("$KHULUMA_BIN" usage --json)"
  assert_equals "usage_default_has_no_days" "$(json_field "$out" daily)" ""
  assert_equals "usage_default_daily_started" "$(json_field "$out" coverage.daily_tracking_started_at)" "2026-10-14T21:30:00Z"
  local bad
  for bad in "--json --days 0" "--json --days 3661" "--json --days abc" "--days 3" "--json --days"; do
    # shellcheck disable=SC2086
    if "$KHULUMA_BIN" usage $bad >/dev/null 2>&1; then fail "usage_days_rejects: $bad"; fi
  done
  pass "usage_days_rejects_bad_args"

  # Transcript-free: nothing dictated, and no stray stored key, ever leaves.
  python3 - "$ledger" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
p["daily"]["days"]["2026-10-16"]["text"] = "zqxleak"
p["daily"]["notes"] = "zqxleak"
p["history"] = "zqxleak"
json.dump(p, open(sys.argv[1], "w"))
PYEOF
  out="$("$KHULUMA_BIN" usage --json --days all)$("$KHULUMA_BIN" usage --json)"
  assert_equals "usage_days_never_leaks" "$(printf '%s' "$out" | grep -c 'zqx' || true)" "0"
  if grep -q zqxsentinel "$ledger"; then fail "usage_ledger_never_stores_text"; fi
  pass "usage_ledger_never_stores_text"

  # A malformed daily section never costs a delivery.
  python3 - "$ledger" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
p["daily"]["days"]["2026-10-16"]["count"] = "lots"
json.dump(p, open(sys.argv[1], "w"))
PYEOF
  cp "$ledger" "$CASE_DIR/before-bad.json"
  TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T10:00:00Z usage_rec inline "still counted" 1000 1000 2>"$CASE_DIR/bad.err" \
    || fail "usage_daily_malformed_rc"
  python3 - "$CASE_DIR/before-bad.json" "$ledger" <<'PYEOF' || fail "usage_daily_malformed_keeps_totals"
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:])
assert b["delivered_dictations"]["count"] == a["delivered_dictations"]["count"] + 1, b
assert b["daily"] == a["daily"], b
PYEOF
  pass "usage_daily_malformed_keeps_totals"
  assert_file_contains "usage_daily_malformed_warns" "$CASE_DIR/bad.err" "daily usage is unreadable"
  out="$(TZ=Asia/Dubai KHULUMA_USAGE_NOW=2026-10-16T10:00:00Z "$KHULUMA_BIN" usage --json --days 7)"
  # A bad bucket makes the whole section unreadable, never silently partial.
  assert_equals "usage_days_bad_bucket_unreadable" "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)["daily"]; print(d["status"], d["days"], d["started_at"])')" "unreadable [] None"
  python3 - "$ledger" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
p["daily"]["days"]["2026-10-16"] = {"count": 1}
json.dump(p, open(sys.argv[1], "w"))
PYEOF
  assert_equals "usage_days_missing_fields_unreadable" "$(json_field "$("$KHULUMA_BIN" usage --json --days 7)" daily.status)" "unreadable"
  python3 - "$ledger" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
del p["daily"]["days"]["2026-10-16"]
p["daily"]["started_at"] = "zqxleak said this"
json.dump(p, open(sys.argv[1], "w"))
PYEOF
  out="$("$KHULUMA_BIN" usage --json --days 7)$("$KHULUMA_BIN" usage --json)"
  assert_equals "usage_days_bad_started_at_never_leaks" "$(printf '%s' "$out" | grep -c 'zqx' || true)" "0"
  python3 - "$ledger" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
p["daily"] = "garbage"
json.dump(p, open(sys.argv[1], "w"))
PYEOF
  out="$("$KHULUMA_BIN" usage --json --days 7)"
  assert_equals "usage_days_unreadable_status" "$(json_field "$out" daily.status)" "unreadable"
}

# A failing cleanup stage keeps its pre-extraction semantics: under set -e it
# aborts with the stage's own status; where errexit is off (inline process
# runs the pipeline under `|| rc=$?`) the partial text carries on.
run_cleanup_stage_failure_round() {
  setup_case "cleanup-stage-failure"
  export KHULUMA_TEST_SWIFT_TEXT="stage failure transcript"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local failing_lib="$CASE_DIR/khuluma-lib-failing-sanitize.sh"
  {
    cat "$ROOT/bin/khuluma-lib.sh"
    printf '%s\n' 'khuluma_lib_sanitize_transcript_artifacts() { cat; return 7; }'
  } >"$failing_lib"
  local out rc=0
  out="$(printf 'hello there' | KHULUMA_LIB_PATH="$failing_lib" "$KHULUMA_BIN" inline cleanup --json 2>/dev/null)" || rc=$?
  assert_equals "cleanup_stage_failure_exit_status" "$rc" "7"

  out="$(KHULUMA_LIB_PATH="$failing_lib" "$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --app Safari --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok", r
assert r["raw_text"] == "stage failure transcript", r
' || { echo "$out" >&2; fail "cleanup_stage_failure_inline_process_continues"; }
  pass "cleanup_stage_failure_inline_process_continues"
}

# Khuluma's native path persists each take with `inline record` after
# delivery: the same bench/usage/history writers as `inline process`, usage
# only for delivered takes, and the [debug] keep_logs archive.
run_inline_record_round() {
  setup_case "inline-record"
  local out bench

  out="$("$KHULUMA_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
c = json.load(sys.stdin)
t = c["transcription"]
assert t["socket_path"].endswith(".sock") and t["model_path"], t
assert t["tail_pad_ms"] == "500" and t["tail_rescue"] is True and t["language"] == "en", t
assert "chunking" not in t and "silence_trim" not in t, t
assert t["processing_dir"].endswith("/processing"), t
assert c["pipeline"] == {"supervise": True}, c["pipeline"]
assert "capabilities" not in c, c
' || { echo "$out" >&2; fail "app_config_transcription_section"; }
  pass "app_config_transcription_section"
  assert_equals "app_config_supervise_default" "$(json_field "$out" pipeline.supervise)" "True"
  # Khuluma refuses takes unless the CLI speaks its contract: the two numbers
  # must move together.
  local swift_contract
  swift_contract="$(sed -nE 's/^ *public static let version = ([0-9]+).*/\1/p' "$ROOT/native/Sources/KhulumaCore/CLIModels.swift")"
  [[ -n "$swift_contract" ]] || fail "app_contract_swift_constant_found"
  assert_equals "app_config_contract_matches_khuluma" "$(json_field "$out" app_contract)" "$swift_contract"
  assert_equals "app_config_usage_path" "$(json_field "$out" usage.summary_path)" "$KHULUMA_CONFIG_DIR/usage.json"
  printf '[app]\nsupervise_daemon = false\n' >"$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json)"
  assert_equals "app_config_supervise_off" "$(json_field "$out" pipeline.supervise)" "False"
  preserve_fixture "$KHULUMA_CONFIG_FILE"

  # No locale at all is the C locale, even though Python itself coerces it to
  # C.UTF-8 in its own environment.
  out="$(env -u LC_ALL -u LC_CTYPE -u LC_COLLATE -u LANG "$KHULUMA_BIN" app-config --json)"
  assert_contains "app_config_locale_unset_is_c" "$out" '"locale_ctype": "", "locale_collate": ""'

  printf '%s' '{"take_id":"t-ok","status":"ok","delivered":true,"raw_text":"open ai","text":"OpenAI",
    "app":"Ghostty","record_ms":3000,"transcribe_ms":400,"clean_ms":3,"paste_ms":50,"total_ms":3500,"startup_ms":12,
    "started_at_ms":1000,"delivered_at_ms":4600,"capture_wav_ms":3010,"capture_wav_bytes":96364}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/record-ok.json"
  assert_file_contains "inline_record_ok_usage" "$CASE_DIR/record-ok.json" '"usage_recorded": true'
  assert_file_contains "inline_record_usage_ledger" "$KHULUMA_CONFIG_DIR/usage.json" '"inline": 1'
  assert_file_contains "inline_record_usage_elapsed" "$KHULUMA_CONFIG_DIR/usage.json" '"full_elapsed_duration_ms": 3600'
  bench="$(tail -n 1 "$KHULUMA_CONFIG_DIR/history/bench.tsv")"
  assert_contains "inline_record_bench_row" "$bench" $'\tinline\tok\t'
  assert_contains "inline_record_bench_source" "$bench" $'\t3000\t400\t3\t0\t50\t3500\t12\t0\t0\t0\tapp:native'
  python3 - "$KHULUMA_CONFIG_DIR/history" <<'PYEOF' || fail "inline_record_history"
import glob, json, os, sys
files = sorted(glob.glob(os.path.join(sys.argv[1], "*.json")))
assert len(files) == 1, files
h = json.load(open(files[0]))
assert h["raw"] == "open ai" and h["processed"] == "OpenAI" and "mode" not in h and h["app"] == "Ghostty", h
assert h["metrics"]["total_ms"] == 3500 and h["audio"]["capture_gap_to_record_ms"] == 10, h
PYEOF
  pass "inline_record_history"

  # A replayed take (Khuluma's spool after a quit timeout or crash) is
  # recorded once.
  printf '%s' '{"take_id":"t-ok","status":"ok","delivered":true,"raw_text":"open ai","text":"OpenAI"}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/record-dup.json"
  assert_file_contains "inline_record_duplicate_detected" "$CASE_DIR/record-dup.json" '"duplicate": true'
  assert_file_contains "inline_record_duplicate_usage_once" "$KHULUMA_CONFIG_DIR/usage.json" '"inline": 1'

  # A second take in the same second gets its own history file.
  printf '%s' '{"take_id":"t-ok2","status":"ok","delivered":true,"raw_text":"b","text":"b"}' \
    | "$KHULUMA_BIN" inline record --json >/dev/null
  printf '%s' '{"take_id":"t-ok3","status":"ok","delivered":true,"raw_text":"c","text":"c"}' \
    | "$KHULUMA_BIN" inline record --json >/dev/null
  python3 - "$KHULUMA_CONFIG_DIR/history" <<'PYEOF' || fail "inline_record_history_unique_names"
import glob, json, os, sys
files = glob.glob(os.path.join(sys.argv[1], "*.json"))
assert len(files) == 3, files
assert sorted(json.load(open(f))["processed"] for f in files) == ["OpenAI", "b", "c"]
PYEOF
  pass "inline_record_history_unique_names"

  # Failed delivery: a bench row, but no usage and no history.
  printf '%s' '{"take_id":"t-fail","status":"paste_failed","delivered":false,"raw_text":"x","text":"x"}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/record-fail.json"
  assert_file_contains "inline_record_failed_no_usage" "$CASE_DIR/record-fail.json" '"usage_recorded": false'
  assert_file_contains "inline_record_failed_usage_unchanged" "$KHULUMA_CONFIG_DIR/usage.json" '"inline": 3'
  [[ "$(ls "$KHULUMA_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" == "3" ]] || fail "inline_record_failed_no_history"
  pass "inline_record_failed_no_history"
  assert_contains "inline_record_failed_bench" "$(tail -n 1 "$KHULUMA_CONFIG_DIR/history/bench.tsv")" $'\tpaste_failed\t'

  printf '%s' '{"take_id":"t-none","status":"no_speech","delivered":false}' | "$KHULUMA_BIN" inline record --json >/dev/null
  assert_contains "inline_record_no_speech_bench" "$(tail -n 1 "$KHULUMA_CONFIG_DIR/history/bench.tsv")" $'\tno_speech\t'

  # [debug] keep_logs: the handed-over WAV is archived and removed.
  printf 'RIFF fake wav' >"$CASE_DIR/take-padded.wav"
  printf '{"take_id":"t-keep","status":"ok","delivered":true,"raw_text":"k","text":"k","wav_path":"%s"}' \
    "$CASE_DIR/take-padded.wav" | KHULUMA_KEEP_LOGS=1 "$KHULUMA_BIN" inline record --json >/dev/null
  assert_path_absent "inline_record_keep_logs_wav_moved" "$CASE_DIR/take-padded.wav"
  ls "$KHULUMA_CONFIG_DIR/history/inline-debug/"*t-keep.wav >/dev/null 2>&1 || fail "inline_record_keep_logs_archive_wav"
  pass "inline_record_keep_logs_archive_wav"
  ls "$KHULUMA_CONFIG_DIR/history/inline-debug/"*t-keep.meta >/dev/null 2>&1 || fail "inline_record_keep_logs_archive_meta"
  pass "inline_record_keep_logs_archive_meta"

  # A take recovered at quit (never pasted): history, no usage.
  local usage_before
  usage_before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$KHULUMA_CONFIG_DIR/usage.json")"
  printf '%s' '{"take_id":"t-recovered","status":"recovered","delivered":false,"raw_text":"saved at quit","text":"Saved at quit"}' \
    | "$KHULUMA_BIN" inline record --json >"$CASE_DIR/record-recovered.json"
  assert_file_contains "inline_record_recovered_no_usage" "$CASE_DIR/record-recovered.json" '"usage_recorded": false'
  assert_file_contains "inline_record_recovered_history" "$CASE_DIR/record-recovered.json" '"history_saved": true'
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$KHULUMA_CONFIG_DIR/usage.json")" == "$usage_before" ]] \
    || fail "inline_record_recovered_usage_unchanged"
  pass "inline_record_recovered_usage_unchanged"
  grep -rq '"processed": "Saved at quit"' "$KHULUMA_CONFIG_DIR/history/" || fail "inline_record_recovered_history_file"
  pass "inline_record_recovered_history_file"
  assert_contains "inline_record_recovered_bench" "$(tail -n 1 "$KHULUMA_CONFIG_DIR/history/bench.tsv")" $'\trecovered\t'

  # Concurrent writers on a bench at its row limit: every new row survives
  # the trims (appends and trims share one lock).
  local i
  : >"$KHULUMA_CONFIG_DIR/history/bench.tsv"
  for i in $(seq 1 30); do
    printf 'old\tinline\tok\tm\tpad%s\n' "$i" >>"$KHULUMA_CONFIG_DIR/history/bench.tsv"
  done
  for i in $(seq 1 10); do
    printf '{"take_id":"c%s","status":"ok","delivered":false,"model":"conc%s"}' "$i" "$i" \
      | KHULUMA_BENCH_MAX_ROWS=30 "$KHULUMA_BIN" inline record --json >/dev/null &
  done
  wait
  [[ "$(wc -l <"$KHULUMA_CONFIG_DIR/history/bench.tsv" | tr -d ' ')" == "30" ]] || fail "inline_record_bench_trimmed"
  pass "inline_record_bench_trimmed"
  for i in $(seq 1 10); do
    grep -q $'\tconc'"$i"$'\t' "$KHULUMA_CONFIG_DIR/history/bench.tsv" || fail "inline_record_concurrent_bench_row_$i"
  done
  pass "inline_record_concurrent_bench_rows"
  assert_path_absent "inline_record_bench_lock_released" "$KHULUMA_CONFIG_DIR/history/bench.tsv.lock.d"

  local rc=0
  printf 'not json' | "$KHULUMA_BIN" inline record --json >/dev/null 2>&1 || rc=$?
  [[ "$rc" != "0" ]] || fail "inline_record_rejects_bad_payload"
  pass "inline_record_rejects_bad_payload"
}

# A malformed config.toml (e.g. half-saved mid-edit) falls back to the last
# valid copy, not to the defaults, which would turn autosend back on.
run_config_last_good_round() {
  setup_case "config-last-good"
  # Earlier rounds export inline overrides; this round tests config.toml itself.
  unset KHULUMA_AUTOSEND KHULUMA_INLINE_SEND_MODE
  export KHULUMA_TEST_SWIFT_TEXT="config fallback transcript"
  export KHULUMA_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local out
  printf '[meta]\nconfig_version = 1\n\n[inline]\nautosend = false\nsend_mode = "cmd_enter"\n' >"$KHULUMA_CONFIG_FILE"

  out="$("$KHULUMA_BIN" app-config --json)"
  assert_contains "config_valid_status" "$out" '"config": {"error": null, "source": "file"}'
  assert_contains "config_valid_autosend_off" "$out" '"autosend": false'
  [[ -f "$(dirname "$KHULUMA_CONFIG_FILE")/.config.toml.last-good" ]] || fail "config_last_good_saved"
  pass "config_last_good_saved"

  printf '[meta]\nconfig_version = 1\n\n[inline]\nautosend = fal' >"$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
c = json.load(sys.stdin)
assert c["config"]["error"] and c["config"]["source"] == "last_good", c["config"]
assert c["inline"]["autosend"] is False and c["inline"]["send_mode"] == "cmd_enter", c["inline"]
' || { echo "$out" >&2; fail "config_invalid_uses_last_good"; }
  pass "config_invalid_uses_last_good"

  out="$("$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --app Safari --json)"
  assert_contains "config_invalid_inline_process_last_good" "$out" '"autosend": false'
  out="$("$KHULUMA_BIN" doctor 2>&1 || true)"
  assert_contains "config_invalid_doctor_says_last_good" "$out" "the last valid copy of config.toml"

  # Snapshots that parse but aren't trustworthy are invalid too, and never
  # replace the copy: an empty file (e.g. mid-write) and a non-boolean switch.
  local copy
  copy="$(dirname "$KHULUMA_CONFIG_FILE")/.config.toml.last-good"
  : >"$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json)"
  assert_contains "config_empty_uses_last_good" "$out" '"source": "last_good"'
  assert_contains "config_empty_keeps_autosend_off" "$out" '"autosend": false'
  printf '[inline]\nautosend = "false"\n' >"$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json)"
  assert_contains "config_string_bool_rejected" "$out" 'inline.autosend must be true or false'
  assert_contains "config_string_bool_keeps_autosend_off" "$out" '"autosend": false'
  assert_file_contains "config_copy_not_replaced" "$copy" 'autosend = false'

  # An unreadable file recovers from the copy too.
  printf '[inline]\nautosend = true\n' >"$KHULUMA_CONFIG_FILE"
  chmod 000 "$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json 2>/dev/null || true)"
  chmod 600 "$KHULUMA_CONFIG_FILE"
  assert_contains "config_unreadable_uses_last_good" "$out" '"source": "last_good"'
  assert_contains "config_unreadable_keeps_autosend_off" "$out" '"autosend": false'

  # No trustworthy settings at all: defaults, but never sending, in every flow.
  preserve_fixture "$copy"
  printf '[inline\nautosend = fal' >"$KHULUMA_CONFIG_FILE"
  out="$("$KHULUMA_BIN" app-config --json)"
  assert_contains "config_invalid_no_copy_reports_defaults" "$out" '"source": "defaults"'
  assert_contains "config_invalid_no_copy_inline_autosend_off" "$out" '"autosend": false'
  [[ ! -e "$copy" ]] || fail "config_invalid_never_creates_copy"
  pass "config_invalid_never_creates_copy"

  # config_set writes atomically through a symlinked config.toml.
  local real="$CASE_DIR/dotfiles-config.toml"
  printf '[meta]\nconfig_version = 1\n\n[inline]\nautosend = true\n' >"$real"
  ln -sf "$real" "$KHULUMA_CONFIG_FILE"
  "$KHULUMA_BIN" autosend off >/dev/null
  [[ -L "$KHULUMA_CONFIG_FILE" ]] || fail "config_set_keeps_symlink"
  pass "config_set_keeps_symlink"
  assert_file_contains "config_set_updates_target" "$real" 'autosend = false'
  unset KHULUMA_TEST_SWIFT_TEXT KHULUMA_TEST_FFPROBE_DURATION_MS
}

run_app_backend_failure_round() {
  setup_case "app-backend-failure"
  export KHULUMA_TEST_SWIFT_DAEMON_FAIL=1
  export KHULUMA_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local out rc=0
  out="$("$KHULUMA_BIN" inline process "$CASE_DIR/take.wav" --json)" || rc=$?
  assert_equals "app_process_failure_exit_zero" "$rc" "0"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] is False and r["status"] == "failed", r
assert r["text"] == "" and r["message"], r
assert r["history_saved"] is False, r
' || { echo "$out" >&2; fail "app_process_failure_json"; }
  pass "app_process_failure_json"
  assert_path_absent "app_process_failure_no_usage" "$KHULUMA_CONFIG_DIR/usage.json"
  unset KHULUMA_TEST_SWIFT_DAEMON_FAIL
}

write_stubs
run_inline_keep_logs_archive_round
run_inline_audio_retention_round
run_inline_swift_round
run_inline_swift_tail_rescue_round
run_status_model_mode_round
run_status_backend_round
run_transcribe_file_raw_round
run_transcribe_file_outputs_round
run_transcribe_file_errors_round
run_transcribe_file_no_speech_round
run_transcribe_file_long_round
run_transcribe_file_no_tail_rescue_round
run_transcribe_file_daemon_unavailable_round
run_transcribe_file_write_race_round
run_daemon_lifecycle_round
run_daemon_build_and_refresh_round
run_app_backend_round
run_dictation_cleanup_round
run_app_backend_failure_round
run_config_last_good_round
run_inline_record_round
run_inline_record_usage_retry_round
run_usage_daily_round
run_cleanup_stage_failure_round
run_finder_quick_action_round
run_finder_handler_round

assert_registered_stub_process
cleanup_stub_daemons
assert_no_registered_stub_processes

echo "Flow parity tests passed."
