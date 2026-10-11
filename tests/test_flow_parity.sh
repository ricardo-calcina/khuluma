#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DICTATE_BIN="$ROOT/bin/tmux-whisper"
TMP_ROOT="$(mktemp -d)"
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
      [[ -n "${wav:-}" ]] && rm -f "$wav" 2>/dev/null || true
    done < <(find "$TMP_ROOT" -type f -name '*.state' 2>/dev/null || true)
    rm -rf "$TMP_ROOT"
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

assert_refresh_count_at_least() {
  local name="$1"
  local expected="$2"
  local actual=0
  if [[ -f "${DICTATE_SWIFTBAR_REFRESH_LOG:-}" ]]; then
    actual="$(grep -c 'refresh plugin=tmux-whisper-status.0.2s.sh' "$DICTATE_SWIFTBAR_REFRESH_LOG" 2>/dev/null || true)"
  fi
  assert_number_ge "$name" "$actual" "$expected"
}

wait_for_refresh_count_at_least() {
  local expected="$1"
  local tries="${2:-120}"
  local i actual
  for ((i = 0; i < tries; i++)); do
    actual=0
    if [[ -f "${DICTATE_SWIFTBAR_REFRESH_LOG:-}" ]]; then
      actual="$(grep -c 'refresh plugin=tmux-whisper-status.0.2s.sh' "$DICTATE_SWIFTBAR_REFRESH_LOG" 2>/dev/null || true)"
    fi
    if (( actual >= expected )); then
      return 0
    fi
    sleep 0.05
  done
  return 1
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
  [[ -n "${DICTATE_TEST_FFMPEG_LIST_LOG:-}" ]] && printf 'list_devices\n' >>"$DICTATE_TEST_FFMPEG_LIST_LOG"
  cat >&2 <<'OUT'
[AVFoundation input device @ 0x0] AVFoundation audio devices:
[AVFoundation input device @ 0x0] [0] MacBook Air Microphone
[AVFoundation input device @ 0x0] AVFoundation video devices:
[AVFoundation input device @ 0x0] [0] FaceTime HD Camera
OUT
  exit 0
fi

if [[ -n "${DICTATE_TEST_FFMPEG_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$DICTATE_TEST_FFMPEG_LOG"
fi

# Simulate a device that can't be opened by name (renamed/unplugged). Real
# ffmpeg takes 0.2-0.8s to give up, well past a bare "is it running" check.
if [[ "${DICTATE_TEST_FFMPEG_FAIL_NAME:-0}" == "1" && "$*" == *"-i :MacBook Air Microphone"* ]]; then
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

if [[ "${DICTATE_TEST_FFMPEG_HOLD:-0}" == "1" && ( "$out" == *"whisper-dictate-"* || "$out" == *"dictate-inline-"* ) ]]; then
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

duration_ms="${DICTATE_TEST_FFPROBE_DURATION_MS:-}"
if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
  awk -v ms="$duration_ms" 'BEGIN { printf "%.6f\n", ms/1000 }'
  exit 0
fi

exit 1
EOF

  cat >"$STUB_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${DICTATE_TEST_TMUX_LOG:-}"
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
        printf '%s\n' "${DICTATE_TEST_TMUX_PANE:-%1}"
        ;;
      '#{pane_current_path}')
        printf '%s\n' "${DICTATE_TEST_TMUX_PATH:-/tmp/project}"
        ;;
      '#{pane_title}')
        printf '%s\n' "${DICTATE_TEST_TMUX_TITLE:-main}"
        ;;
      '#{pane_current_command}')
        printf '%s\n' "${DICTATE_TEST_TMUX_PANE_CMD:-bash}"
        ;;
      '#{pane_tty}')
        printf '%s\n' "${DICTATE_TEST_TMUX_TTY:-}"
        ;;
      '#{pane_pid}')
        printf '%s\n' "${DICTATE_TEST_TMUX_PANE_PID:-}"
        ;;
    esac
    ;;
esac
exit 0
EOF

  cat >"$STUB_DIR/pbcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >"${DICTATE_TEST_PBCOPY_OUT:-/tmp/dictate-test-pbcopy.out}"
EOF

  cat >"$STUB_DIR/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [[ -n "${DICTATE_TEST_OSASCRIPT_LOG:-}" ]]; then
  printf '%s\n' "$joined" >>"$DICTATE_TEST_OSASCRIPT_LOG"
fi
if [[ "$joined" == *"get name of first process whose frontmost is true"* ]]; then
  printf '%s\n' "${DICTATE_TEST_FRONT_APP:-Ghostty}"
fi
exit 0
EOF

  cat >"$STUB_DIR/afplay" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DICTATE_TEST_SOUND_LOG:-}" ]]; then
  printf '%s\n' "${1:-}" >>"$DICTATE_TEST_SOUND_LOG"
fi
exit 0
EOF

  cat >"$STUB_DIR/tmux-whisperd" <<'EOF'
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
    registry_dir="${DICTATE_TEST_STUB_REGISTRY_DIR:-}"
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
    os.unlink(socket_path)
except FileNotFoundError:
    pass

import time, uuid
time.sleep(float(os.environ.get("DICTATE_TEST_STUB_START_DELAY", "0") or 0))
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(5)
transcribe_count = 0
generation = str(uuid.uuid4())
loaded = None
delay_values = [s.strip() for s in os.environ.get("DICTATE_TEST_SWIFT_DELAY_SEQUENCE", "").split("|")]
text_values = [s for s in os.environ.get("DICTATE_TEST_SWIFT_TEXT_SEQUENCE", "").split("|")]

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
        elif os.environ.get("DICTATE_TEST_SWIFT_DAEMON_FAIL", "0") == "1":
            resp = {
                "id": req.get("id"),
                "ok": False,
                "engine": "swift_parakeet",
                "error_code": "forced_error",
                "message": "forced daemon failure",
            }
        else:
            if req.get("op") == "transcribe" and req.get("flow") != "warmup":
                if os.environ.get("DICTATE_TEST_SWIFT_REJECT_SUBSECOND", "0") == "1":
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
                text_value = os.environ.get("DICTATE_TEST_SWIFT_TEXT", "swift transcript")
                if idx < len(text_values) and text_values[idx]:
                    text_value = text_values[idx]
            elif req.get("op") == "transcribe":
                text_value = ""
            else:
                text_value = os.environ.get("DICTATE_TEST_SWIFT_TEXT", "swift transcript")
            if req.get("model_path") and os.environ.get("DICTATE_TEST_STUB_NEVER_LOADS", "0") != "1":
                loaded = {"path": req["model_path"],
                          "version": os.environ.get("DICTATE_TEST_STUB_LOADED_VERSION") or req.get("model_version") or "v3"}
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
    printf '%s\n' "tmux-whisperd test-stub"
    ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 2
    ;;
esac
EOF

  chmod +x "$STUB_DIR/ffmpeg" "$STUB_DIR/ffprobe" "$STUB_DIR/tmux" "$STUB_DIR/pbcopy" "$STUB_DIR/osascript" "$STUB_DIR/afplay" "$STUB_DIR/tmux-whisperd"
}

CASE_DIR=""

setup_case() {
  local name="$1"
  local socket_tag
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"/{home,tmp,logs,tmux-jobs,swift-model}
  mkdir -p "$CASE_DIR/config/modes/base" "$CASE_DIR/config/modes/chat" "$CASE_DIR/config/modes/code" "$CASE_DIR/config/modes/long"

  # Keep the stub daemon socket short enough for macOS AF_UNIX limits.
  socket_tag="$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
  [[ -n "$socket_tag" ]] || socket_tag="dictatetest"

  printf '%s\n' "code" >"$CASE_DIR/config/current-mode"
  : >"$CASE_DIR/config/modes/base/prompt"
  : >"$CASE_DIR/config/modes/chat/prompt"
  : >"$CASE_DIR/config/modes/code/prompt"
  : >"$CASE_DIR/config/modes/long/prompt"
  printf '%s\n' "inline" >"$CASE_DIR/config/modes/base/flows"
  printf '%s\n' "Messages" >"$CASE_DIR/config/modes/chat/apps"
  printf '%s\n' "inline" >"$CASE_DIR/config/modes/chat/flows"
  : >"$CASE_DIR/config/vocab"

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
  mkdir -p "$HOME/.local/share/sounds/dictate"
  : >"$HOME/.local/share/sounds/dictate/start.wav"
  : >"$HOME/.local/share/sounds/dictate/stop.wav"
  : >"$HOME/.local/share/sounds/dictate/process.wav"
  : >"$HOME/.local/share/sounds/dictate/error.wav"
  : >"$HOME/.local/share/sounds/dictate/cancel.wav"

  export DICTATE_CONFIG_DIR="$CASE_DIR/config"
  export DICTATE_CONFIG_FILE="$CASE_DIR/config/config.toml"
  export DICTATE_LIB_PATH="$ROOT/bin/dictate-lib.sh"
  export DICTATE_STATE_FILE="$CASE_DIR/tmux.state"
  export DICTATE_INLINE_STATE_FILE="$CASE_DIR/inline.state"
  export DICTATE_PROCESSING_DIR="$CASE_DIR/processing"
  export DICTATE_PROCESSED_FLAG="$CASE_DIR/processed.flag"
  export DICTATE_CANCEL_FLAG="$CASE_DIR/cancelled.flag"
  export DICTATE_PROCESSING_LONG_FLAG="$CASE_DIR/processing-long.flag"
  export DICTATE_TMPDIR="$CASE_DIR/tmp"
  export DICTATE_RECORD_LOG="$CASE_DIR/logs/record.log"
  export DICTATE_TRANSCRIBE_LOG="$CASE_DIR/logs/transcribe.log"
  export DICTATE_TMUX_JOBS_DIR="$CASE_DIR/tmux-jobs"
  export DICTATE_SWIFTBAR_REFRESH_LOG="$CASE_DIR/logs/swiftbar-refresh.log"
  export DICTATE_TMUX_WHISPERD_BIN="$STUB_DIR/tmux-whisperd"
  export DICTATE_TEST_STUB_REGISTRY_DIR="$STUB_REGISTRY_DIR"
  export DICTATE_SWIFT_PARAKEET_MODEL_PATH="$CASE_DIR/swift-model"
  export DICTATE_SWIFT_PARAKEET_SOCKET_PATH="$TMP_ROOT/${socket_tag}.sock"
  export DICTATE_KEEP_LOGS=1
  unset DICTATE_HISTORY_AUDIO_RETENTION_DAYS
  export DICTATE_AUDIO_INDEX=0
  export DICTATE_TMUX_AUTOSEND=1
  export DICTATE_TMUX_SEND_DELAY_MS=0
  export DICTATE_TMUX_CODEX_TAB_DELAY_MS=0
  export DICTATE_INLINE_ACTIVATE_DELAY_MS=0
  export DICTATE_INLINE_SEND_DELAY_MS=0
  export DICTATE_INLINE_PASTE_TARGET=current
  unset DICTATE_SWIFT_PARAKEET_MODEL_VERSION

  export DICTATE_TEST_FFMPEG_LOG="$CASE_DIR/logs/ffmpeg.log"
  export DICTATE_TEST_TMUX_LOG="$CASE_DIR/logs/tmux.log"
  export DICTATE_TEST_OSASCRIPT_LOG="$CASE_DIR/logs/osascript.log"
  export DICTATE_TEST_PBCOPY_OUT="$CASE_DIR/logs/pbcopy.txt"
  export DICTATE_TEST_SOUND_LOG="$CASE_DIR/logs/sounds.log"
  export DICTATE_TEST_TMUX_PANE="%1"
  export DICTATE_TEST_TMUX_PANE_CMD="bash"
  export DICTATE_TEST_FFMPEG_HOLD=0
  export DICTATE_TEST_SWIFT_TEXT="default transcript"
  unset DICTATE_TEST_SWIFT_DAEMON_FAIL
  unset DICTATE_TEST_SWIFT_DELAY_SEQUENCE
  unset DICTATE_TEST_SWIFT_TEXT_SEQUENCE
  unset DICTATE_TEST_SWIFT_REJECT_SUBSECOND
  unset DICTATE_TEST_FFPROBE_DURATION_MS
  unset DICTATE_TRANSCRIBE_FILE_LOG
  unset DICTATE_SWIFT_PARAKEET_TAIL_RESCUE
  unset DICTATE_SWIFT_PARAKEET_TAIL_RESCUE_MS
  unset DICTATE_SWIFT_PARAKEET_TAIL_RESCUE_MIN_MS
  unset DICTATE_SWIFT_PARAKEET_CHUNKING
  unset DICTATE_SWIFT_PARAKEET_CHUNK_THRESHOLD_MS
  unset DICTATE_SWIFT_PARAKEET_CHUNK_MS
  unset DICTATE_SWIFT_PARAKEET_CHUNK_OVERLAP_MS

  unset CEREBRAS_API_KEY
  unset TMUX
  unset TMUX_PANE
}

run_tmux_round() {
  local mode="$1"
  setup_case "tmux-${mode}"
  export TMUX="1"
  export TMUX_PANE="%1"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TMUX_SEND_MODE="$mode"
  export DICTATE_TEST_SWIFT_TEXT="tmux round ${mode}"

  local start_out
  start_out="$("$DICTATE_BIN" toggle)"
  assert_contains "tmux_start_${mode}" "$start_out" "RECORDING"
  assert_refresh_count_at_least "tmux_start_refresh_${mode}" 1
  wait_for_file_contains "$DICTATE_TEST_FFMPEG_LOG" "aresample=async=1000:first_pts=0" || fail "tmux_capture_async_resampler_${mode}"
  pass "tmux_capture_async_resampler_${mode}"

  # shellcheck disable=SC1090
  . "$DICTATE_STATE_FILE"
  local job_file="$DICTATE_TMUX_JOBS_DIR/$job_id"
  assert_file_contains "tmux_job_recording_${mode}" "$job_file" "status=recording"

  local status_out
  status_out="$("$DICTATE_BIN" status)"
  assert_contains "tmux_queue_status_${mode}" "$status_out" "tmux queue: total=1 recording=1 processing=0"

  local stop_out
  stop_out="$("$DICTATE_BIN" stop)"
  assert_contains "tmux_stop_${mode}" "$stop_out" "STOPPED"
  assert_refresh_count_at_least "tmux_stop_refresh_${mode}" 3

  wait_for_file_contains "$DICTATE_TEST_TMUX_LOG" "tmux delete-buffer" || fail "tmux_background_complete_${mode}"
  wait_for_refresh_count_at_least 4 || fail "tmux_complete_refresh_wait_${mode}"
  assert_refresh_count_at_least "tmux_complete_refresh_${mode}" 4
  wait_for_absent "$job_file" || fail "tmux_job_removed_${mode}"

  assert_file_contains "tmux_paste_${mode}" "$DICTATE_TEST_TMUX_LOG" "tmux paste-buffer"
  assert_file_contains "tmux_send_enter_${mode}" "$DICTATE_TEST_TMUX_LOG" "tmux send-keys -t %1 Enter"
  if [[ "$mode" == "enter" ]]; then
    assert_file_not_contains "tmux_no_codex_tab_${mode}" "$DICTATE_TEST_TMUX_LOG" "tmux send-keys -t %1 C-i"
  else
    assert_file_contains "tmux_codex_tab_${mode}" "$DICTATE_TEST_TMUX_LOG" "tmux send-keys -t %1 C-i"
  fi

  # This reads the durable ledger after a real successful tmux delivery, not
  # transcript history. The production write happens before job completion.
  local usage_json
  usage_json="$("$DICTATE_BIN" usage --json)"
  assert_contains "tmux_usage_delivery_${mode}" "$usage_json" '"tmux": 1'
}

run_inline_vocab_round() {
  setup_case "inline-vocab"
  export DICTATE_TEST_SWIFT_TEXT="codex and tmux"
  export DICTATE_INLINE_SEND_MODE="ctrl_j"
  export DICTATE_AUTOSEND=1

  printf '%s\n' 'codex -> Codex' >"$DICTATE_CONFIG_DIR/vocab"
  printf '%s\n' 'tmux -> Tmux' >"$DICTATE_CONFIG_DIR/modes/code/vocab"

  local out
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_sent_ctrl_j" "$out" "Sent (Ctrl+J)"
  assert_file_contains "inline_osascript_paste" "$DICTATE_TEST_OSASCRIPT_LOG" 'keystroke "v" using command down'
  assert_file_contains "inline_osascript_send_ctrl_j" "$DICTATE_TEST_OSASCRIPT_LOG" 'keystroke "j" using control down'

  local copied
  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_vocab_corrections" "$copied" "Codex and Tmux"

  # Foreground inline delivery returns only after the confirmed-delivery ledger
  # update; the history write is deliberately still asynchronous.
  local usage_json
  usage_json="$("$DICTATE_BIN" usage --json)"
  assert_contains "inline_usage_delivery" "$usage_json" '"inline": 1'
}

run_inline_cmd_enter_round() {
  setup_case "inline-cmd-enter"
  export DICTATE_TEST_SWIFT_TEXT="hello from inline"
  export DICTATE_INLINE_SEND_MODE="cmd_enter"
  export DICTATE_AUTOSEND=1

  local out
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_sent_cmd_enter" "$out" "Sent (Cmd+Enter)"
  assert_file_contains "inline_osascript_send_cmd_enter" "$DICTATE_TEST_OSASCRIPT_LOG" "key code 36 using command down"
}

run_inline_auto_mode_round() {
  setup_case "inline-auto-mode"
  printf '%s\n' "auto" >"$DICTATE_CONFIG_DIR/current-mode"
  printf '%s\n' 'plain dictation -> Plain dictation' >"$DICTATE_CONFIG_DIR/modes/base/vocab"
  printf "%s\n" "what's up -> WhatsApp style" >"$DICTATE_CONFIG_DIR/modes/chat/vocab"
  export DICTATE_AUTOSEND=1
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="plain dictation|what's up"

  export DICTATE_TEST_FRONT_APP="Preview"
  local out copied
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_auto_base_sent" "$out" "Sent"
  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_auto_base_vocab" "$copied" "Plain dictation"

  export DICTATE_TEST_FRONT_APP="Messages"
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_auto_chat_sent" "$out" "Sent"
  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_auto_chat_vocab" "$copied" "WhatsApp style"
}

run_inline_toggle_round() {
  setup_case "inline-toggle"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline background transcript"
  export DICTATE_AUTOSEND=1

  local start_out
  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_toggle_start" "$start_out" "RECORDING"
  assert_refresh_count_at_least "inline_toggle_start_refresh" 1
  wait_for_file_contains "$DICTATE_TEST_FFMPEG_LOG" "aresample=async=1000:first_pts=0" || fail "inline_toggle_async_resampler"
  pass "inline_toggle_async_resampler"

  [[ -f "$DICTATE_INLINE_STATE_FILE" ]] || fail "inline_toggle_state_created"
  pass "inline_toggle_state_created"

  local stop_out
  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_toggle_stop" "$stop_out" "STOPPED"
  assert_refresh_count_at_least "inline_toggle_stop_refresh" 3

  wait_for_absent "$DICTATE_INLINE_STATE_FILE" || fail "inline_toggle_state_removed"
  wait_for_file_contains "$DICTATE_TEST_PBCOPY_OUT" "inline background transcript" || fail "inline_toggle_background_complete"
  wait_for_refresh_count_at_least 4 || fail "inline_toggle_complete_refresh_wait"
  assert_refresh_count_at_least "inline_toggle_complete_refresh" 4
  wait_for_file_contains "$DICTATE_TEST_OSASCRIPT_LOG" 'keystroke "v" using command down' || fail "inline_toggle_osascript_paste"
  pass "inline_toggle_osascript_paste"
  wait_for_file_contains "$DICTATE_TEST_OSASCRIPT_LOG" 'key code 36' || fail "inline_toggle_send_enter"
  pass "inline_toggle_send_enter"
}

run_inline_toggle_grace_override_round() {
  setup_case "inline-toggle-grace-override"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline grace override transcript"
  export DICTATE_STOP_GRACE_MS=5
  export DICTATE_INLINE_STOP_GRACE_MS=123
  export DICTATE_AUTOSEND=1

  local start_out stop_out inline_record_log
  inline_record_log="$CASE_DIR/tmp/whisper-dictate-inline.record.log"

  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_toggle_grace_start" "$start_out" "RECORDING"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_toggle_grace_stop" "$stop_out" "STOPPED"

  assert_file_contains "inline_toggle_grace_record_log" "$inline_record_log" "grace_ms=123"
  assert_file_contains "inline_toggle_grace_quit_stop" "$inline_record_log" "exit_after_q"
}

run_inline_toggle_process_sound_immediate_round() {
  setup_case "inline-toggle-process-sound"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline process sound transcript"
  export DICTATE_AUTOSEND=1

  local start_out stop_out inline_record_log
  inline_record_log="$CASE_DIR/tmp/whisper-dictate-inline.record.log"

  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_toggle_process_sound_start" "$start_out" "RECORDING"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_toggle_process_sound_stop" "$stop_out" "STOPPED"

  wait_for_file_contains "$DICTATE_TEST_SOUND_LOG" "process.wav" || fail "inline_toggle_process_sound_logged"
  assert_file_contains "inline_toggle_process_sound_record_log" "$inline_record_log" "inline_process_sound: immediate_on_stop"

  local process_line stop_line
  process_line="$(grep -n 'inline_process_sound: immediate_on_stop' "$inline_record_log" | head -n 1 | cut -d: -f1)"
  stop_line="$(grep -n 'stop_recording:' "$inline_record_log" | head -n 1 | cut -d: -f1)"
  [[ -n "$process_line" && -n "$stop_line" && "$process_line" -lt "$stop_line" ]] || fail "inline_toggle_process_sound_before_grace"
  pass "inline_toggle_process_sound_before_grace"
}

run_inline_cancel_refresh_round() {
  setup_case "inline-cancel-refresh"
  export DICTATE_TEST_FFMPEG_HOLD=1

  # Cancellation must not initialize or change the transcript-free usage
  # ledger. Snapshot the public CLI result around a real recording/cancel
  # cycle so this covers the primary inline path end to end.
  local start_out cancel_out usage_before usage_after
  usage_before="$("$DICTATE_BIN" usage --json)"
  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_cancel_refresh_start" "$start_out" "RECORDING"

  cancel_out="$("$DICTATE_BIN" cancel)"
  assert_contains "inline_cancel_refresh_cancelled" "$cancel_out" "CANCELLED"
  usage_after="$("$DICTATE_BIN" usage --json)"
  assert_equals "inline_cancel_usage_unchanged" "$usage_after" "$usage_before"
  [[ -f "${DICTATE_CANCEL_FLAG:-/tmp/dictate-cancelled.flag}" ]] || fail "inline_cancel_refresh_flag"
  pass "inline_cancel_refresh_flag"
  assert_refresh_count_at_least "inline_cancel_refresh_requested" 2
}

run_inline_processing_marker_until_paste_round() {
  setup_case "inline-processing-marker-until-paste"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline marker transcript"
  export DICTATE_TEST_SWIFT_DELAY_SEQUENCE="1.5"
  export DICTATE_AUTOSEND=1

  local start_out stop_out marker marker_pid swiftbar_out
  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_processing_marker_start" "$start_out" "RECORDING"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_processing_marker_stop" "$stop_out" "STOPPED"

  wait_for_matching_file "$DICTATE_PROCESSING_DIR" 'inline-*' || fail "inline_processing_marker_created"
  marker="$(find "$DICTATE_PROCESSING_DIR" -name 'inline-*' -type f | head -n 1)"
  assert_file_contains "inline_processing_marker_kind" "$marker" "kind=inline"
  marker_pid="$(sed -n 's/^pid=//p' "$marker" | head -n 1)"
  [[ "$marker_pid" =~ ^[0-9]+$ ]] || fail "inline_processing_marker_pid_present"
  kill -0 "$marker_pid" 2>/dev/null || fail "inline_processing_marker_pid_live"
  pass "inline_processing_marker_pid_live"
  swiftbar_out="$(DICTATE_BIN="$DICTATE_BIN" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
  assert_contains "inline_processing_marker_swiftbar_state" "$swiftbar_out" "Processing (1)"

  wait_for_file_contains "$DICTATE_TEST_PBCOPY_OUT" "inline marker transcript" 240 || fail "inline_processing_marker_paste_done"
  wait_for_no_matching_file "$DICTATE_PROCESSING_DIR" 'inline-*' || fail "inline_processing_marker_removed_after_paste"
  [[ -f "$DICTATE_PROCESSED_FLAG" ]] || fail "inline_processing_marker_processed_flag"
  pass "inline_processing_marker_processed_flag"
}

run_inline_processing_marker_immediate_after_stop_round() {
  setup_case "inline-processing-marker-immediate"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline immediate marker transcript"
  export DICTATE_TEST_SWIFT_DELAY_SEQUENCE="0.35"
  export DICTATE_INLINE_STOP_GRACE_MS=1200
  export DICTATE_AUTOSEND=1

  local start_out stop_out_file stop_pid marker marker_pid swiftbar_out
  stop_out_file="$CASE_DIR/logs/stop.out"
  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_processing_immediate_start" "$start_out" "RECORDING"

  "$DICTATE_BIN" inline toggle >"$stop_out_file" 2>&1 &
  stop_pid="$!"

  wait_for_absent "$DICTATE_INLINE_STATE_FILE" || fail "inline_processing_immediate_state_removed"
  wait_for_matching_file "$DICTATE_PROCESSING_DIR" 'inline-*' || fail "inline_processing_immediate_marker_created"
  marker="$(find "$DICTATE_PROCESSING_DIR" -name 'inline-*' -type f | head -n 1)"
  assert_file_contains "inline_processing_immediate_marker_kind" "$marker" "kind=inline"
  marker_pid="$(sed -n 's/^pid=//p' "$marker" | head -n 1)"
  [[ "$marker_pid" =~ ^[0-9]+$ ]] || fail "inline_processing_immediate_marker_pid_present"
  kill -0 "$marker_pid" 2>/dev/null || fail "inline_processing_immediate_marker_pid_live"
  pass "inline_processing_immediate_marker_pid_live"
  swiftbar_out="$(DICTATE_BIN="$DICTATE_BIN" bash "$ROOT/integrations/tmux-whisper-status.0.2s.sh")"
  assert_contains "inline_processing_immediate_swiftbar_state" "$swiftbar_out" "Processing"

  wait "$stop_pid"
  assert_file_contains "inline_processing_immediate_stop_output" "$stop_out_file" "STOPPED"
  wait_for_file_contains "$DICTATE_TEST_PBCOPY_OUT" "inline immediate marker transcript" || fail "inline_processing_immediate_paste_done"
}

write_stale_mac_audio_cache() {
  cat >"$CASE_DIR/config/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "mac"
mac_name = "MacBook Air Microphone"
EOF
  mkdir -p "$CASE_DIR/config/.cache"
  cat >"$CASE_DIR/config/.cache/audio-index.sh" <<'EOF'
CACHED_AUDIO_KEY=source=mac\;preferred=MacBook\ Air\ Microphone\;mac=MacBook\ Air\ Microphone\;iphone=
CACHED_AUDIO_NAME=MacBook\ Air\ Microphone
CACHED_AUDIO_MATCH=mac
CACHED_AUDIO_INDEX=1
CACHED_AUDIO_AT=2026-03-20T08:47:56Z
EOF
  touch -t 202603200847 "$CASE_DIR/config/.cache/audio-index.sh" 2>/dev/null || true
}

run_inline_by_name_skips_device_lookup_round() {
  setup_case "inline-by-name-no-lookup"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline by name transcript"
  export DICTATE_AUTOSEND=1
  export DICTATE_TEST_FFMPEG_LIST_LOG="$CASE_DIR/logs/ffmpeg-list.log"
  unset DICTATE_AUDIO_INDEX
  # A stale cache used to force a device enumeration (seconds) at start.
  write_stale_mac_audio_cache
  local cache_file="$CASE_DIR/config/.cache/audio-index.sh" before start_out stop_out
  before="$(cat "$cache_file")"

  start_out="$(DICTATE_AUDIO_CACHE_SKIP_VALIDATE=0 "$DICTATE_BIN" inline toggle)"
  assert_contains "inline_by_name_start" "$start_out" "RECORDING"
  assert_file_contains "inline_by_name_ffmpeg_selector" "$DICTATE_TEST_FFMPEG_LOG" "avfoundation -i :MacBook Air Microphone"
  [[ -e "$DICTATE_TEST_FFMPEG_LIST_LOG" ]] && fail "inline_by_name_no_device_enumeration"
  pass "inline_by_name_no_device_enumeration"
  assert_equals "inline_by_name_cache_untouched" "$(cat "$cache_file")" "$before"
  assert_contains "inline_by_name_startup_source" "$(. "$DICTATE_INLINE_STATE_FILE"; printf '%s' "$startup_audio_source")" "name:source(mac):name(MacBook Air Microphone)"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_by_name_stop" "$stop_out" "STOPPED"
  unset DICTATE_TEST_FFMPEG_LIST_LOG
}

run_inline_by_name_failure_falls_back_to_index_round() {
  setup_case "inline-by-name-fallback"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline fallback transcript"
  export DICTATE_AUTOSEND=1
  export DICTATE_TEST_FFMPEG_FAIL_NAME=1
  unset DICTATE_AUDIO_INDEX
  write_stale_mac_audio_cache

  local start_out stop_out inline_record_log
  inline_record_log="$CASE_DIR/tmp/whisper-dictate-inline.record.log"
  start_out="$(DICTATE_AUDIO_CACHE_SKIP_VALIDATE=0 "$DICTATE_BIN" inline toggle)"
  assert_contains "inline_fallback_start" "$start_out" "RECORDING"
  # The name failed, so the index was re-resolved (stale cache replaced) and used.
  assert_file_contains "inline_fallback_index_selector" "$DICTATE_TEST_FFMPEG_LOG" "avfoundation -i :0"
  assert_file_contains "inline_fallback_cache_note" "$inline_record_log" "audio cache: stale cache invalidated: cached idx=1 name=MacBook Air Microphone match=mac at=2026-03-20T08:47:56Z; re-resolved idx=0 match=mac name=MacBook Air Microphone"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_fallback_stop" "$stop_out" "STOPPED"
  unset DICTATE_TEST_FFMPEG_FAIL_NAME
}

run_inline_keep_logs_archive_round() {
  setup_case "inline-keep-logs-archive"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline archive transcript"
  export DICTATE_AUTOSEND=1

  local start_out stop_out archive_dir wav_archive meta_archive transcribe_archive
  archive_dir="$CASE_DIR/config/history/inline-debug"

  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_archive_start" "$start_out" "RECORDING"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_archive_stop" "$stop_out" "STOPPED"

  wait_for_file_contains "$DICTATE_TEST_PBCOPY_OUT" "inline archive transcript" || fail "inline_archive_complete"
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
  assert_file_contains "inline_archive_meta_stop_grace" "$meta_archive" "stop_grace_ms="
  assert_file_contains "inline_archive_meta_capture_bytes" "$meta_archive" "capture_wav_bytes="
  assert_file_contains "inline_archive_meta_archive_bytes" "$meta_archive" "archive_wav_bytes="
  assert_file_contains "inline_archive_meta_retention_days" "$meta_archive" "wav_retention_days=2"
  assert_file_contains "inline_archive_meta_retention_note" "$meta_archive" "retention_note="
  assert_file_contains "inline_archive_record_snapshot" "${meta_archive%.meta}.record.log" "inline_capture_snapshot:"
  assert_file_contains "inline_archive_stop_after_grace_logged" "${meta_archive%.meta}.record.log" "after_grace"
}

run_inline_audio_retention_round() {
  setup_case "inline-audio-retention"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_TEST_SWIFT_TEXT="inline retention transcript"
  export DICTATE_AUTOSEND=1
  export DICTATE_HISTORY_AUDIO_RETENTION_DAYS=0

  local start_out stop_out archive_dir wav_archive meta_archive history_file
  archive_dir="$CASE_DIR/config/history/inline-debug"

  start_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_audio_retention_start" "$start_out" "RECORDING"

  stop_out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_audio_retention_stop" "$stop_out" "STOPPED"

  wait_for_file_contains "$DICTATE_TEST_PBCOPY_OUT" "inline retention transcript" || fail "inline_audio_retention_complete"
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
  export DICTATE_TEST_SWIFT_TEXT="swift backend transcript"
  export DICTATE_AUTOSEND=1

  local out
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_swift_sent" "$out" "Sent"

  local copied
  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_swift_transcript" "$copied" "swift backend transcript"
  assert_file_contains "inline_swift_async_resampler" "$DICTATE_TEST_FFMPEG_LOG" "aresample=async=1000:first_pts=0"
  assert_file_contains "inline_swift_tail_pad_ffmpeg" "$DICTATE_TEST_FFMPEG_LOG" "anullsrc=r=16000:cl=mono"
}

run_inline_swift_tail_rescue_round() {
  setup_case "inline-swift-tail-rescue"
  export DICTATE_AUTOSEND=1
  export DICTATE_TEST_FFPROBE_DURATION_MS=20591
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="section by section review and then we'll go back|And we'll go back down and break down each section and then potentially rewrite then"

  local out copied inline_transcribe_log
  inline_transcribe_log="$CASE_DIR/tmp/whisper-dictate-inline.transcribe.log"
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_swift_tail_rescue_sent" "$out" "Sent"

  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_swift_tail_rescue_merged" "$copied" "section by section review and then we'll go back down and break down each section and then potentially rewrite then"
  assert_file_contains "inline_swift_tail_rescue_log" "$inline_transcribe_log" "swift_parakeet_tail_rescue:"
}

run_inline_swift_chunked_round() {
  setup_case "inline-swift-chunked"
  export DICTATE_AUTOSEND=1
  export DICTATE_SWIFT_PARAKEET_CHUNKING=1
  export DICTATE_TEST_FFPROBE_DURATION_MS=65000
  export DICTATE_SWIFT_PARAKEET_CHUNK_THRESHOLD_MS=1000
  export DICTATE_SWIFT_PARAKEET_CHUNK_MS=30000
  export DICTATE_SWIFT_PARAKEET_CHUNK_OVERLAP_MS=2000
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="first chunk shared words|shared words final chunk|final chunk tail"

  local out copied inline_transcribe_log
  inline_transcribe_log="$CASE_DIR/tmp/whisper-dictate-inline.transcribe.log"
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_swift_chunked_sent" "$out" "Sent"

  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_swift_chunked_merged" "$copied" "first chunk shared words final chunk tail"
  assert_file_contains "inline_swift_chunked_log" "$inline_transcribe_log" "swift_parakeet_chunked:"
  assert_file_contains "inline_swift_chunked_chunk_log" "$inline_transcribe_log" "swift_parakeet_chunk: index=1"
}

run_inline_swift_chunking_default_off_round() {
  setup_case "inline-swift-chunking-default-off"
  export DICTATE_AUTOSEND=1
  export DICTATE_TEST_FFPROBE_DURATION_MS=65000
  export DICTATE_SWIFT_PARAKEET_CHUNK_THRESHOLD_MS=1000
  export DICTATE_TEST_SWIFT_TEXT="unchunked long default"

  local out copied inline_transcribe_log
  inline_transcribe_log="$CASE_DIR/tmp/whisper-dictate-inline.transcribe.log"
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_swift_chunking_default_off_sent" "$out" "Sent"

  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_swift_chunking_default_off_transcript" "$copied" "unchunked long default"
  assert_file_not_contains "inline_swift_chunking_default_off_no_chunk_log" "$inline_transcribe_log" "swift_parakeet_chunked:"
}

run_inline_swift_chunked_tail_boundary_round() {
  setup_case "inline-swift-chunked-tail-boundary"
  export DICTATE_AUTOSEND=1
  export DICTATE_SWIFT_PARAKEET_CHUNKING=1
  export DICTATE_TEST_FFPROBE_DURATION_MS=84521
  export DICTATE_SWIFT_PARAKEET_CHUNK_THRESHOLD_MS=45000
  export DICTATE_SWIFT_PARAKEET_CHUNK_MS=30000
  export DICTATE_SWIFT_PARAKEET_CHUNK_OVERLAP_MS=2000
  export DICTATE_TEST_SWIFT_REJECT_SUBSECOND=1
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="boundary first shared words|shared words middle bridge|middle bridge final"

  local out copied inline_transcribe_log
  inline_transcribe_log="$CASE_DIR/tmp/whisper-dictate-inline.transcribe.log"
  out="$("$DICTATE_BIN" inline)"
  assert_contains "inline_swift_chunked_tail_boundary_sent" "$out" "Sent"

  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_swift_chunked_tail_boundary_merged" "$copied" "boundary first shared words middle bridge final"
  assert_file_contains "inline_swift_chunked_tail_boundary_log" "$inline_transcribe_log" "swift_parakeet_chunk: index=2"
  assert_file_contains "inline_swift_chunked_tail_boundary_skip_log" "$inline_transcribe_log" "swift_parakeet_chunk_skip: index=3"
  assert_file_not_contains "inline_swift_chunked_tail_boundary_no_fourth_transcribe" "$inline_transcribe_log" "swift_parakeet_chunk: index=3"
  assert_file_not_contains "inline_swift_chunked_tail_boundary_no_daemon_error" "$inline_transcribe_log" "Invalid audio data provided"
}

run_inline_swift_superseded_round() {
  setup_case "inline-swift-superseded"
  export DICTATE_SWIFT_PARAKEET_SOCKET_PATH="$TMP_ROOT/iss.sock"
  export DICTATE_TEST_FFMPEG_HOLD=1
  export DICTATE_AUTOSEND=1
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="first cold transcript|second fresh transcript"
  export DICTATE_TEST_SWIFT_DELAY_SEQUENCE="0.35|0"

  local out
  out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_swift_superseded_start_first" "$out" "RECORDING"
  out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_swift_superseded_stop_first" "$out" "STOPPED"

  out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_swift_superseded_start_second" "$out" "RECORDING"
  out="$("$DICTATE_BIN" inline toggle)"
  assert_contains "inline_swift_superseded_stop_second" "$out" "STOPPED"

  wait_for_file_contains "$DICTATE_TEST_PBCOPY_OUT" "second fresh transcript" || fail "inline_swift_superseded_second_complete"
  sleep 0.5

  local copied paste_count send_count
  copied="$(cat "$DICTATE_TEST_PBCOPY_OUT")"
  assert_contains "inline_swift_superseded_final_clipboard" "$copied" "second fresh transcript"
  if [[ "$copied" == *"first cold transcript"* ]]; then
    fail "inline_swift_superseded_old_clipboard_suppressed"
  fi
  pass "inline_swift_superseded_old_clipboard_suppressed"

  paste_count="$(grep -c 'keystroke "v" using command down' "$DICTATE_TEST_OSASCRIPT_LOG" 2>/dev/null || true)"
  send_count="$(grep -c 'key code 36' "$DICTATE_TEST_OSASCRIPT_LOG" 2>/dev/null || true)"
  assert_equals "inline_swift_superseded_single_paste" "$paste_count" "1"
  assert_equals "inline_swift_superseded_single_send" "$send_count" "1"
}

run_tmux_audio_cache_note_round() {
  setup_case "tmux-audio-cache"
  export TMUX="1"
  export TMUX_PANE="%1"
  export DICTATE_TEST_FFMPEG_HOLD=1
  unset DICTATE_AUDIO_INDEX

  cat >"$CASE_DIR/config/config.toml" <<'EOF'
[meta]
config_version = 1

[audio]
source = "mac"
mac_name = "MacBook Air Microphone"
EOF

  mkdir -p "$CASE_DIR/config/.cache"
  cat >"$CASE_DIR/config/.cache/audio-index.sh" <<'EOF'
CACHED_AUDIO_KEY=source=mac\;preferred=MacBook\ Air\ Microphone\;mac=MacBook\ Air\ Microphone\;iphone=
CACHED_AUDIO_NAME=MacBook\ Air\ Microphone
CACHED_AUDIO_MATCH=mac
CACHED_AUDIO_INDEX=1
CACHED_AUDIO_AT=2026-03-20T08:47:56Z
EOF

  local start_out stop_out
  start_out="$(DICTATE_AUDIO_CACHE_SKIP_VALIDATE=0 "$DICTATE_BIN" toggle)"
  assert_contains "tmux_audio_cache_start" "$start_out" "RECORDING"
  assert_file_contains "tmux_audio_cache_log_note" "$DICTATE_RECORD_LOG" "audio cache: stale cache invalidated: cached idx=1 name=MacBook Air Microphone match=mac at=2026-03-20T08:47:56Z; re-resolved idx=0 match=mac name=MacBook Air Microphone"
  assert_file_contains "tmux_audio_cache_rewritten_index" "$CASE_DIR/config/.cache/audio-index.sh" "CACHED_AUDIO_INDEX=0"

  stop_out="$("$DICTATE_BIN" stop)"
  assert_contains "tmux_audio_cache_stop" "$stop_out" "STOPPED"
}

run_status_postprocess_round() {
  setup_case "status-postprocess"
  export DICTATE_POSTPROCESS=1
  export DICTATE_TMUX_POSTPROCESS=1

  local out
  out="$("$DICTATE_BIN" status)"
  assert_contains "status_summary_ready" "$out" "state: ready"
  assert_contains "status_summary_backend_cold" "$out" "backend_readiness: cold"
  assert_contains "status_post_inline_off" "$out" "postprocess.inline: OFF"
  assert_contains "status_post_tmux_off" "$out" "postprocess.tmux: OFF"
  assert_contains "status_mode_prompt_inline_inactive" "$out" "mode_prompt.inline: inactive"
  assert_contains "status_mode_prompt_tmux_inactive" "$out" "mode_prompt.tmux: inactive"
  assert_contains "status_budget_profile_short" "$out" "budget_profile.short:"
  assert_contains "status_budget_auto_threshold" "$out" "budget.auto_long_words_threshold:"
  assert_contains "status_post_note" "$out" "postprocess.note: disabled at runtime (CEREBRAS_API_KEY missing)"
}

run_status_model_mode_round() {
  setup_case "status-model-mode"
  export DICTATE_TMUX_MODE="long"

  local out
  out="$("$DICTATE_BIN" status)"
  assert_contains "status_backend_swift" "$out" "backend: swift_parakeet"
  assert_contains "status_mode_tmux_long" "$out" "mode.tmux: long"
  assert_contains "status_model_swift_path" "$out" "swift_parakeet.model: $CASE_DIR/swift-model (v3)"
}

run_status_backend_round() {
  setup_case "status-backend"
  local out
  out="$("$DICTATE_BIN" status)"
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
  export DICTATE_TEST_FFPROBE_DURATION_MS=5000
  export DICTATE_TRANSCRIBE_FILE_LOG="$CASE_DIR/logs/transcribe-file.log"
  mkdir -p "$CASE_DIR/memos"
  printf '%s\n' "original memo bytes" >"$CASE_DIR/memos/memo.m4a"
  cp "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memo.orig"
}

run_transcribe_file_raw_round() {
  setup_transcribe_case "transcribe-raw"
  # Dictation cleanup that must NOT apply to file transcripts.
  printf '%s\n' 'codex -> Codex' >"$DICTATE_CONFIG_DIR/vocab"
  export DICTATE_TEST_SWIFT_TEXT="codex picked a color um [BLANK_AUDIO]"
  local out
  out="$("$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" 2>"$CASE_DIR/logs/stderr.txt")"

  assert_equals "transcribe_raw_stdout" "$out" "codex picked a color um"
  assert_file_contains "transcribe_raw_progress_stderr" "$CASE_DIR/logs/stderr.txt" "Transcribing $CASE_DIR/memos/memo.m4a (5s)"
  cmp -s "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memo.orig" || fail "transcribe_raw_original_untouched"
  pass "transcribe_raw_original_untouched"
  assert_file_contains "transcribe_raw_ffmpeg_input" "$DICTATE_TEST_FFMPEG_LOG" "$CASE_DIR/memos/memo.m4a -vn"
  assert_file_contains "transcribe_raw_ffmpeg_format" "$DICTATE_TEST_FFMPEG_LOG" "ac 1 -ar 16000 -c:a pcm_s16le"
  assert_file_not_contains "transcribe_raw_ffmpeg_never_writes_input" "$DICTATE_TEST_FFMPEG_LOG" "pcm_s16le $CASE_DIR/memos/memo.m4a"
  assert_path_absent "transcribe_raw_no_clipboard" "$DICTATE_TEST_PBCOPY_OUT"
  assert_path_absent "transcribe_raw_no_usage_ledger" "$DICTATE_CONFIG_DIR/usage.json"
  assert_path_absent "transcribe_raw_no_history" "$DICTATE_CONFIG_DIR/history"
  assert_path_absent "transcribe_raw_no_sounds" "$DICTATE_TEST_SOUND_LOG"
  assert_path_absent "transcribe_raw_no_swiftbar_refresh" "$DICTATE_SWIFTBAR_REFRESH_LOG"
  assert_path_absent "transcribe_raw_no_osascript" "$DICTATE_TEST_OSASCRIPT_LOG"
  if compgen -G "$CASE_DIR/tmp/tmux-whisper-transcribe.*" >/dev/null; then
    fail "transcribe_raw_temp_cleaned"
  fi
  pass "transcribe_raw_temp_cleaned"
}

run_transcribe_file_outputs_round() {
  setup_transcribe_case "transcribe-outputs"
  export DICTATE_TEST_SWIFT_TEXT="file transcript text"
  local out rc

  out="$("$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside -q)"
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
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside -q 2>"$CASE_DIR/logs/exists.txt" || rc=$?
  assert_equals "transcribe_beside_exists_exit" "$rc" "1"
  assert_file_contains "transcribe_beside_exists_message" "$CASE_DIR/logs/exists.txt" "use --force to overwrite"
  assert_file_not_contains "transcribe_exists_fails_before_decode" "$CASE_DIR/logs/exists.txt" "Transcribing"

  printf '%s\n' "stale" >"$CASE_DIR/memos/memo.txt"
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside --force -q
  assert_file_contains "transcribe_beside_force" "$CASE_DIR/memos/memo.txt" "file transcript text"
  assert_file_not_contains "transcribe_beside_force_replaced" "$CASE_DIR/memos/memo.txt" "stale"

  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -o "$CASE_DIR/out/one.txt" -q
  assert_file_contains "transcribe_output_file" "$CASE_DIR/out/one.txt" "file transcript text"
  if compgen -G "$CASE_DIR/memos/.tmux-whisper-transcript.*" >/dev/null || compgen -G "$CASE_DIR/out/.tmux-whisper-transcript.*" >/dev/null; then
    fail "transcribe_no_temp_files_in_output_dirs"
  fi
  pass "transcribe_no_temp_files_in_output_dirs"

  cp "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memos/second.mp3"
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memos/second.mp3" --out-dir "$CASE_DIR/out-dir" --format json -q
  assert_file_contains "transcribe_out_dir_json_first" "$CASE_DIR/out-dir/memo.json" '"text": "file transcript text"'
  assert_file_contains "transcribe_out_dir_json_duration" "$CASE_DIR/out-dir/second.json" '"audio_duration_ms": 5000'

  out="$("$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memos/second.mp3" -q -c)"
  assert_contains "transcribe_multi_header_first" "$out" "==> $CASE_DIR/memos/memo.m4a <=="
  assert_contains "transcribe_multi_header_second" "$out" "==> $CASE_DIR/memos/second.mp3 <=="
  assert_file_contains "transcribe_clipboard_combined" "$DICTATE_TEST_PBCOPY_OUT" "file transcript text"

  out="$("$DICTATE_BIN" transcribe - --format json -q <"$CASE_DIR/memos/memo.m4a")"
  assert_contains "transcribe_stdin_json_file" "$out" '"file": "stdin"'
  assert_contains "transcribe_stdin_json_engine" "$out" '"engine": "swift_parakeet"'
}

run_transcribe_file_errors_round() {
  setup_transcribe_case "transcribe-errors"
  local rc out

  rc=0
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/missing.m4a" >/dev/null 2>"$CASE_DIR/logs/missing.txt" || rc=$?
  assert_equals "transcribe_missing_exit" "$rc" "2"
  assert_file_contains "transcribe_missing_message" "$CASE_DIR/logs/missing.txt" "not a readable file"

  rc=0
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" "$CASE_DIR/memo.orig" -o "$CASE_DIR/x.txt" >/dev/null 2>&1 || rc=$?
  assert_equals "transcribe_output_single_input_exit" "$rc" "2"

  rc=0
  "$DICTATE_BIN" transcribe - --beside </dev/null >/dev/null 2>&1 || rc=$?
  assert_equals "transcribe_stdin_beside_rejected" "$rc" "2"

  export DICTATE_TEST_SWIFT_DAEMON_FAIL=1
  rc=0
  out="$("$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside -q 2>"$CASE_DIR/logs/daemon.txt")" || rc=$?
  assert_equals "transcribe_daemon_fail_exit" "$rc" "1"
  assert_equals "transcribe_daemon_fail_no_stdout" "$out" ""
  assert_file_contains "transcribe_daemon_fail_message" "$CASE_DIR/logs/daemon.txt" "transcription failed"
  assert_path_absent "transcribe_daemon_fail_no_output_file" "$CASE_DIR/memos/memo.txt"
}

run_transcribe_file_no_speech_round() {
  setup_transcribe_case "transcribe-no-speech"
  export DICTATE_TEST_SWIFT_TEXT="[BLANK_AUDIO]"
  local rc=0
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -q >/dev/null 2>"$CASE_DIR/logs/silent.txt" || rc=$?
  assert_equals "transcribe_no_speech_exit" "$rc" "1"
  assert_file_contains "transcribe_no_speech_message" "$CASE_DIR/logs/silent.txt" "no speech detected"
}

run_transcribe_file_long_round() {
  setup_transcribe_case "transcribe-long"
  # Files rely on FluidAudio's own chunking; the quarantined bash chunker must
  # not engage even when enabled for dictation.
  export DICTATE_SWIFT_PARAKEET_CHUNKING=1
  export DICTATE_TEST_FFPROBE_DURATION_MS=1200000
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="alpha beta gamma delta epsilon zeta|epsilon zeta eta theta"
  local out
  out="$("$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -q)"
  assert_equals "transcribe_long_tail_rescue_merge" "$out" "alpha beta gamma delta epsilon zeta eta theta"
  assert_file_contains "transcribe_long_tail_rescue_logged" "$DICTATE_TRANSCRIBE_FILE_LOG" "swift_parakeet_tail_rescue: duration_ms=1200000"
  assert_file_not_contains "transcribe_long_no_bash_chunker" "$DICTATE_TRANSCRIBE_FILE_LOG" "swift_parakeet_chunked"
  assert_path_absent "transcribe_long_dictation_log_untouched" "$DICTATE_TRANSCRIBE_LOG"
}

run_transcribe_file_no_tail_rescue_round() {
  setup_transcribe_case "transcribe-no-tail"
  export DICTATE_TEST_FFPROBE_DURATION_MS=1200000
  export DICTATE_TEST_SWIFT_TEXT_SEQUENCE="only the main pass|should not appear"
  local out
  out="$("$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" -q --no-tail-rescue)"
  assert_equals "transcribe_no_tail_rescue" "$out" "only the main pass"
  assert_file_not_contains "transcribe_no_tail_rescue_logged" "$DICTATE_TRANSCRIBE_FILE_LOG" "swift_parakeet_tail_rescue"
}


run_finder_quick_action_round() {
  setup_case "finder-quick-action"
  local services="$CASE_DIR/services" workflow out
  workflow="$services/Transcribe with Tmux Whisper.workflow"

  out="$(DICTATE_SERVICES_DIR="$services" "$DICTATE_BIN" finder install)"
  assert_contains "finder_install_message" "$out" "Installed Finder Quick Action: Transcribe with Tmux Whisper"
  assert_contains "finder_install_handler" "$out" "handler: $ROOT/integrations/finder/tmux-whisper-transcribe.sh"
  WORKFLOW="$workflow" HANDLER="$ROOT/integrations/finder/tmux-whisper-transcribe.sh" python3 - <<'PYEOF2'
import os, plistlib
wf = os.environ["WORKFLOW"]
info = plistlib.load(open(os.path.join(wf, "Contents/Info.plist"), "rb"))
service = info["NSServices"][0]
assert service["NSMenuItem"]["default"] == "Transcribe with Tmux Whisper"
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

  out="$(DICTATE_SERVICES_DIR="$services" "$DICTATE_BIN" finder status)"
  assert_contains "finder_status_installed" "$out" "(installed)"
  out="$(DICTATE_SERVICES_DIR="$services" "$DICTATE_BIN" finder remove)"
  assert_contains "finder_remove_message" "$out" "Removed Finder Quick Action"
  assert_path_absent "finder_remove_workflow" "$workflow"
}

run_finder_handler_round() {
  setup_case "finder-handler"
  local stub="$CASE_DIR/stub-cli" args_log="$CASE_DIR/logs/cli-args.txt" notify_log="$CASE_DIR/logs/notify.txt"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit "${STUB_CLI_EXIT:-0}"\n' "$args_log" >"$stub"
  chmod +x "$stub"
  mkdir -p "$CASE_DIR/memos"
  : >"$CASE_DIR/memos/idea one.m4a"

  DICTATE_BIN="$stub" DICTATE_FINDER_NOTIFY_LOG="$notify_log" DICTATE_FINDER_TRANSCRIBE_LOG="$CASE_DIR/logs/finder.log" \
    bash "$ROOT/integrations/finder/tmux-whisper-transcribe.sh" "$CASE_DIR/memos/idea one.m4a"
  assert_file_contains "finder_handler_cli_args" "$args_log" "transcribe --beside --clipboard $CASE_DIR/memos/idea one.m4a"
  assert_file_contains "finder_handler_notify_start" "$notify_log" "Transcribing idea one.m4a..."
  assert_file_contains "finder_handler_notify_done" "$notify_log" "Saved idea one.txt and copied it to the clipboard."

  local rc=0
  printf 'tmux-whisper: output exists (use --force to overwrite): x.txt\n' >>"$CASE_DIR/logs/finder.log"
  STUB_CLI_EXIT=1 DICTATE_BIN="$stub" DICTATE_FINDER_NOTIFY_LOG="$notify_log" DICTATE_FINDER_TRANSCRIBE_LOG="$CASE_DIR/logs/finder.log" \
    bash "$ROOT/integrations/finder/tmux-whisper-transcribe.sh" "$CASE_DIR/memos/idea one.m4a" || rc=$?
  assert_equals "finder_handler_failure_exit_clean" "$rc" "0"
  assert_file_contains "finder_handler_notify_failure" "$notify_log" "Transcription failed: output exists"
}


run_transcribe_file_daemon_unavailable_round() {
  setup_transcribe_case "transcribe-no-daemon"
  export DICTATE_TMUX_WHISPERD_BIN="$CASE_DIR/missing-tmux-whisperd"
  local rc=0
  "$DICTATE_BIN" transcribe "$CASE_DIR/memos/memo.m4a" --beside >/dev/null 2>"$CASE_DIR/logs/no-daemon.txt" || rc=$?
  assert_equals "transcribe_no_daemon_exit" "$rc" "2"
  assert_file_contains "transcribe_no_daemon_message" "$CASE_DIR/logs/no-daemon.txt" "Parakeet daemon unavailable: could not start tmux-whisperd"
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
    source "$1"
    transcribe_file_log() { :; }
    chmod() { printf "%s\n" "competing notes" >"$RACE_DIR/memo.txt"; }
    transcribe_file_write_output "$RACE_DIR/memo.txt" "new transcript" 0
  ' _ "$ROOT/bin/tmux-whisper-lib/transcribe_file.sh" 2>"$CASE_DIR/logs/race.txt" || rc=$?
  assert_equals "transcribe_race_exit" "$rc" "1"
  assert_file_contains "transcribe_race_kept_existing" "$dir/memo.txt" "competing notes"
  assert_file_contains "transcribe_race_message" "$CASE_DIR/logs/race.txt" "output exists"
  if compgen -G "$dir/.tmux-whisper-transcript.*" >/dev/null; then
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
  local socket="$DICTATE_SWIFT_PARAKEET_SOCKET_PATH" meta="$DICTATE_SWIFT_PARAKEET_SOCKET_PATH.meta"
  local out a b pid meta_pid holder lock="$DICTATE_SWIFT_PARAKEET_SOCKET_PATH.lifecycle.lock"
  mkdir -p "$CASE_DIR/memos"
  printf '%s\n' "memo" >"$CASE_DIR/memos/m.m4a"
  # Slow starts make the launchers overlap.
  export DICTATE_TEST_STUB_START_DELAY=0.5

  # Lowkey-style warmups, a CLI transcription and a background warmup all
  # find no daemon at once: exactly one starts, and meta names it.
  "$DICTATE_BIN" warmup --json >"$CASE_DIR/w1.json" &
  a=$!
  "$DICTATE_BIN" warmup --json >"$CASE_DIR/w2.json" &
  b=$!
  DICTATE_TEST_FFPROBE_DURATION_MS=3000 "$DICTATE_BIN" transcribe "$CASE_DIR/memos/m.m4a" -q >"$CASE_DIR/t.txt" &
  local c=$!
  "$DICTATE_BIN" warmup --best-effort >/dev/null &
  local d=$!
  wait "$a" "$b" "$c" "$d" || fail "lifecycle_concurrent_callers_exit_ok"
  pass "lifecycle_concurrent_callers_exit_ok"
  assert_equals "lifecycle_one_daemon" "$(live_stub_daemons_for "$socket")" "1"
  out="$(cat "$CASE_DIR/w1.json")"
  assert_equals "lifecycle_warmup_json_ready" "$(json_field "$out" state)" "ready"
  assert_equals "lifecycle_warmup_json_ready_too" "$(json_field "$(cat "$CASE_DIR/w2.json")" state)" "ready"
  assert_equals "lifecycle_warmup_json_model" "$(json_field "$out" model_loaded.path)" "$DICTATE_SWIFT_PARAKEET_MODEL_PATH"
  [[ -n "$(json_field "$out" generation)" ]] || fail "lifecycle_warmup_json_generation"
  pass "lifecycle_warmup_json_generation"
  pid="$(json_field "$out" pid)"
  meta_pid="$(awk -F= '$1 == "pid" { print $2 }' "$meta")"
  assert_equals "lifecycle_meta_names_serving_daemon" "$meta_pid" "$pid"
  assert_file_contains "lifecycle_transcribe_worked" "$CASE_DIR/t.txt" "default transcript"
  flock_held "$lock" && fail "lifecycle_lock_released"
  pass "lifecycle_lock_released"
  # The daemon must not inherit the lock (it would hold it forever).
  "$DICTATE_BIN" warmup --json >/dev/null
  flock_held "$lock" && fail "lifecycle_daemon_does_not_hold_lock"
  pass "lifecycle_daemon_does_not_hold_lock"

  # A daemon too slow to answer is stopped before the lock is released, so
  # it can't come up later beside one someone else starts.
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || rm -f "$socket"
  export DICTATE_TEST_STUB_START_DELAY=3
  out="$(DICTATE_DAEMON_START_WAIT_SECONDS=1 "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_slow_start_unavailable" "$(json_field "$out" state)" "unavailable"
  assert_file_contains "lifecycle_slow_start_logged" "$DICTATE_TRANSCRIBE_LOG" "did not answer within 1s; stopping it"
  sleep 3
  assert_equals "lifecycle_slow_start_stopped" "$(live_stub_daemons_for "$socket")" "0"
  unset DICTATE_TEST_STUB_START_DELAY
  wait_for_absent "$socket" 60 || rm -f "$socket"

  # Ready means this daemon holds this model and version.
  out="$(DICTATE_TEST_STUB_LOADED_VERSION=v2 "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_other_version_not_ready" "$(json_field "$out" state)" "warming"
  assert_equals "lifecycle_other_version_reason" "$(json_field "$out" reason)" "model_changed"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || rm -f "$socket"
  out="$(DICTATE_TEST_STUB_NEVER_LOADS=1 "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_cold_not_ready" "$(json_field "$out" state)" "warming"
  assert_equals "lifecycle_cold_reason" "$(json_field "$out" reason)" "cold"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || rm -f "$socket"

  # A daemon that accepts but never answers is never unlinked or doubled.
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || rm -f "$socket"
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
  out="$(DICTATE_SWIFT_PARAKEET_PING_TIMEOUT_SECONDS=0.5 "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_hung_daemon_unavailable" "$(json_field "$out" state)" "unavailable"
  [[ -S "$socket" ]] || fail "lifecycle_hung_socket_kept"
  pass "lifecycle_hung_socket_kept"
  assert_file_contains "lifecycle_hung_logged" "$DICTATE_TRANSCRIBE_LOG" "does not answer; not starting another"
  assert_equals "lifecycle_hung_no_second_daemon" "$(live_stub_daemons_for "$socket")" "0"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

  # A socket left by a crashed daemon (nobody accepting) is replaced.
  [[ -S "$socket" ]] || fail "lifecycle_stale_socket_left"
  out="$("$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_stale_socket_replaced" "$(json_field "$out" state)" "ready"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || rm -f "$socket"

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
  out="$(DICTATE_DAEMON_LIFECYCLE_WAIT_SECONDS=0 "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_lock_held_warming" "$(json_field "$out" state)" "warming"
  assert_equals "lifecycle_lock_held_reason" "$(json_field "$out" reason)" "starting"
  assert_equals "lifecycle_lock_held_no_daemon" "$(live_stub_daemons_for "$socket")" "0"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  # Its holder died: the kernel released the lock.
  out="$("$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_dead_lock_reclaimed" "$(json_field "$out" state)" "ready"
  cleanup_stub_daemons
  wait_for_absent "$socket" 60 || rm -f "$socket"

  # A socket dir that doesn't exist yet (fresh install, custom path).
  out="$(DICTATE_SWIFT_PARAKEET_SOCKET_PATH="$TMP_ROOT/fresh/d.sock" "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_fresh_socket_dir" "$(json_field "$out" state)" "ready"
  cleanup_stub_daemons

  out="$(DICTATE_TMUX_WHISPERD_BIN="$CASE_DIR/missing-daemon" "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_missing_binary_unavailable" "$(json_field "$out" state)" "unavailable"
  assert_equals "lifecycle_missing_binary_reason" "$(json_field "$out" reason)" "no_daemon_binary"
  out="$(DICTATE_SWIFT_PARAKEET_MODEL_PATH= "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_no_model_reason" "$(json_field "$out" reason)" "no_model"
  out="$(DICTATE_TEST_SWIFT_DAEMON_FAIL=1 "$DICTATE_BIN" warmup --json)"
  assert_equals "lifecycle_warmup_error_unavailable" "$(json_field "$out" state)" "unavailable"
  assert_equals "lifecycle_warmup_error_code" "$(json_field "$out" reason)" "forced_error"
  cleanup_stub_daemons

  # Cancelling a CLI recording clears the CLI's markers, never Lowkey's.
  mkdir -p "$DICTATE_PROCESSING_DIR"
  printf 'pid=%s\nkind=inline\nphase=processing\n' "$$" >"$DICTATE_PROCESSING_DIR/inline-lowkey-keep"
  printf 'pid=%s\nkind=inline\n' "$$" >"$DICTATE_PROCESSING_DIR/inline-12345"
  printf 'started=1\n' >"$DICTATE_INLINE_STATE_FILE"
  "$DICTATE_BIN" cancel >/dev/null
  assert_path_absent "cancel_clears_cli_marker" "$DICTATE_PROCESSING_DIR/inline-12345"
  [[ -f "$DICTATE_PROCESSING_DIR/inline-lowkey-keep" ]] || fail "cancel_keeps_lowkey_marker"
  pass "cancel_keeps_lowkey_marker"
  rm -f "$DICTATE_PROCESSING_DIR/inline-lowkey-keep"
}

run_daemon_build_and_refresh_round() {
  setup_case "daemon-refresh"
  unset DICTATE_TMUX_WHISPERD_BIN
  local src="$CASE_DIR/whisperd-src" build="$CASE_DIR/whisperd-build" build_log="$CASE_DIR/logs/swift-build.log"
  mkdir -p "$src/Sources/tmux-whisperd" "$src/Tests/TmuxWhisperKitTests"
  printf '%s\n' '// swift-tools-version: 6.0' >"$src/Package.swift"
  printf '%s\n' 'print("v1")' >"$src/Sources/tmux-whisperd/main.swift"
  printf '%s\n' '// tests' >"$src/Tests/TmuxWhisperKitTests/T.swift"
  export DICTATE_TMUX_WHISPERD_ROOT="$src"
  export DICTATE_TMUX_WHISPERD_BUILD_ROOT="$build"
  export DICTATE_DAEMON_BACKGROUND_REFRESH=0
  export DICTATE_DAEMON_RESTART_WAIT_SECONDS=0
  export DICTATE_TEST_SWIFT_BUILD_LOG="$build_log"
  export DICTATE_TEST_STUB_DAEMON="$STUB_DIR/tmux-whisperd"
  cat >"$HOME/.local/bin/swift" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "build" ]] || exit 0
printf '%s\n' "$*" >>"$DICTATE_TEST_SWIFT_BUILD_LOG"
[[ "${DICTATE_TEST_SWIFT_BUILD_FAIL:-0}" == "1" ]] && { echo "error: Build failed" >&2; exit 1; }
[[ -d Tests ]] || { echo "error: invalid custom path 'Tests/TmuxWhisperKitTests'" >&2; exit 1; }
mkdir -p .build/release
cp "$DICTATE_TEST_STUB_DAEMON" .build/release/tmux-whisperd
chmod +x .build/release/tmux-whisperd
EOF
  chmod +x "$HOME/.local/bin/swift"
  local socket="$DICTATE_SWIFT_PARAKEET_SOCKET_PATH" meta="$DICTATE_SWIFT_PARAKEET_SOCKET_PATH.meta"
  local builds stamp pid1 pid2 hash out

  # A first build that failed recently is reported, not retried on every call.
  date +%s >"$build.build-failed"
  out="$(DICTATE_DAEMON_BACKGROUND_REFRESH=1 "$DICTATE_BIN" warmup --json)"
  assert_equals "daemon_failed_build_unavailable" "$(json_field "$out" reason)" "build_failed"
  [[ -s "$build_log" ]] && fail "daemon_failed_build_not_retried"
  pass "daemon_failed_build_not_retried"
  rm -f "$build.build-failed"

  # First use: sources synced into the build root, built once, daemon started.
  "$DICTATE_BIN" warmup >/dev/null
  builds="$(grep -c . "$build_log")"
  assert_equals "daemon_first_build" "$builds" "1"
  assert_file_contains "daemon_sources_synced" "$build/Sources/tmux-whisperd/main.swift" 'print("v1")'
  [[ -d "$build/Tests" ]] || fail "daemon_tests_dir_synced"
  pass "daemon_tests_dir_synced"
  stamp="$(cat "$build/.build/tmux-whisper-built-source-hash")"
  assert_file_contains "daemon_meta_records_build" "$meta" "source_hash=$stamp"
  pid1="$(awk -F= '$1 == "pid" { print $2 }' "$meta")"

  # Unchanged sources: no rebuild.
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_no_rebuild_when_current" "$(grep -c . "$build_log")" "1"

  # Lowkey app sources share the package but are not part of the daemon.
  mkdir -p "$src/Sources/Lowkey"
  printf '%s\n' '// app-only change' >"$src/Sources/Lowkey/AppController.swift"
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_ignores_app_sources" "$(grep -c . "$build_log")" "1"

  # A busy pipeline blocks the swap even though a new build exists.
  printf '%s\n' 'print("v2")' >"$src/Sources/tmux-whisperd/main.swift"
  : >"$DICTATE_INLINE_STATE_FILE"
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_rebuilt_on_source_change" "$(grep -c . "$build_log")" "2"
  assert_equals "daemon_not_restarted_while_busy" "$(awk -F= '$1 == "pid" { print $2 }' "$meta")" "$pid1"
  assert_file_contains "daemon_busy_logged" "$DICTATE_TRANSCRIBE_LOG" "daemon still busy"
  rm -f "$DICTATE_INLINE_STATE_FILE"

  # A Lowkey take in any phase (recording included) keeps the old daemon.
  local take_owner
  sleep 60 &
  take_owner=$!
  mkdir -p "$DICTATE_PROCESSING_DIR"
  printf 'pid=%s\nkind=inline\nsession_id=t1\nphase=recording\n' "$take_owner" >"$DICTATE_PROCESSING_DIR/inline-lowkey-t1"
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_not_restarted_mid_recording" "$(awk -F= '$1 == "pid" { print $2 }' "$meta")" "$pid1"
  # A marker whose owner died (Lowkey crashed) is pruned rather than
  # blocking upgrades forever; so is one abandoned before its pid was written.
  kill "$take_owner" 2>/dev/null; wait "$take_owner" 2>/dev/null || true
  : >"$DICTATE_PROCESSING_DIR/inline-lowkey-t2"
  touch -t 202001010000 "$DICTATE_PROCESSING_DIR/inline-lowkey-t2"

  # Idle: the out-of-date daemon is replaced by one started from the new build.
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  pid2="$(awk -F= '$1 == "pid" { print $2 }' "$meta")"
  [[ -n "$pid2" && "$pid2" != "$pid1" ]] || fail "daemon_restarted_when_idle"
  pass "daemon_restarted_when_idle"
  assert_path_absent "daemon_dead_take_marker_pruned" "$DICTATE_PROCESSING_DIR/inline-lowkey-t1"
  assert_path_absent "daemon_abandoned_marker_pruned" "$DICTATE_PROCESSING_DIR/inline-lowkey-t2"
  assert_equals "daemon_meta_names_new_daemon" "$(json_field "$("$DICTATE_BIN" warmup --json)" pid)" "$pid2"
  kill -0 "$pid1" 2>/dev/null && fail "daemon_old_process_stopped"
  pass "daemon_old_process_stopped"
  hash="$(cat "$build/.build/tmux-whisper-built-source-hash")"
  assert_file_contains "daemon_meta_updated" "$meta" "source_hash=$hash"
  assert_equals "daemon_no_extra_build_on_restart" "$(grep -c . "$build_log")" "2"

  # Hot path with an outdated binary: start it now, never build inline.
  printf '%s\n' 'print("v3")' >"$src/Sources/tmux-whisperd/main.swift"
  kill "$pid2" 2>/dev/null || true
  wait_for_absent "$socket" 60 || rm -f "$socket"
  mkdir -p "$CASE_DIR/memos"
  printf '%s\n' "memo" >"$CASE_DIR/memos/m.m4a"
  DICTATE_TEST_FFPROBE_DURATION_MS=3000 "$DICTATE_BIN" transcribe "$CASE_DIR/memos/m.m4a" -q >/dev/null
  assert_equals "daemon_hot_path_never_builds" "$(grep -c . "$build_log")" "2"
  assert_file_contains "daemon_hot_path_uses_stale" "$CASE_DIR/tmp/tmux-whisper-file.transcribe.log" "out of date; using it now"
  assert_file_contains "daemon_hot_path_never_syncs" "$build/Sources/tmux-whisperd/main.swift" 'print("v2")'

  # A build lock held by a live process blocks a concurrent refresh...
  sleep 60 &
  local holder=$!
  mkdir -p "$build.build.lock"
  printf '%s\n' "$holder" >"$build.build.lock/pid"
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_live_lock_blocks_build" "$(grep -c . "$build_log")" "2"
  assert_file_contains "daemon_live_lock_logged" "$DICTATE_TRANSCRIBE_LOG" "another tmux-whisperd build is running"
  # ...and is reclaimed once its owner is gone.
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_equals "daemon_dead_lock_reclaimed" "$(grep -c . "$build_log")" "3"
  [[ -d "$build.build.lock" ]] && fail "daemon_lock_released"
  pass "daemon_lock_released"
  printf '%s\n' 'print("v4")' >"$src/Sources/tmux-whisperd/main.swift"

  # A failed rebuild keeps the working binary.
  DICTATE_TEST_SWIFT_BUILD_FAIL=1 "$DICTATE_BIN" warmup --restart-stale >/dev/null
  assert_file_contains "daemon_failed_rebuild_keeps_binary" "$DICTATE_TRANSCRIBE_LOG" "rebuilding tmux-whisperd failed; keeping the existing binary"
  [[ -x "$build/.build/release/tmux-whisperd" ]] || fail "daemon_binary_still_present"
  pass "daemon_binary_still_present"
  [[ -s "$build.build-failed" ]] || fail "daemon_failed_build_recorded"
  pass "daemon_failed_build_recorded"

  unset DICTATE_TMUX_WHISPERD_ROOT DICTATE_TMUX_WHISPERD_BUILD_ROOT DICTATE_DAEMON_BACKGROUND_REFRESH DICTATE_DAEMON_RESTART_WAIT_SECONDS
  unset DICTATE_TEST_SWIFT_BUILD_LOG DICTATE_TEST_STUB_DAEMON
}


run_app_backend_round() {
  setup_case "app-backend"
  export DICTATE_TEST_SWIFT_TEXT="codex app transcript"
  printf '%s\n' 'codex -> Codex' >"$DICTATE_CONFIG_DIR/vocab"
  export DICTATE_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local out

  out="$("$DICTATE_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
c = json.load(sys.stdin)
assert c["schema_version"] == 1, c
assert c["hotkey"] == "ctrl+option+space", c["hotkey"]
assert set(c["sounds"]) == {"start", "stop", "process", "error", "cancel"}, c["sounds"]
assert c["sounds"]["start"]["path"].endswith("/dictate/start.wav"), c["sounds"]["start"]
assert c["inline"]["send_mode"] in ("enter", "cmd_enter", "ctrl_j"), c["inline"]
assert c["inline"]["send_delay_ms"] == 0 and c["inline"]["activate_delay_ms"] == 0, c["inline"]
cl = c["cleanup"]
assert cl["config_dir"] and cl["vocab_clean"] == "1" and cl["british_spelling"] == "1", cl
assert cl["code_paragraph_min_words"] == "70" and cl["long_paragraph_min_words"] == "55", cl
assert cl["force_mode"] is None and cl["postprocess"] is False, cl
' || fail "app_config_json_shape"
  pass "app_config_json_shape"

  out="$(DICTATE_CLEAN=1 DICTATE_REPEATS_LEVEL=2 "$DICTATE_BIN" app-config --json)"
  assert_contains "app_config_cleanup_env" "$out" '"clean": "1", "repeats_level": "2"'

  # An unexported LC_ALL=C from ~/.zshenv must not hide the exported UTF-8
  # LANG that grep/sed inherit: the native pipeline has to fall back.
  printf '%s\n' 'LC_ALL=C' >"$HOME/.zshenv"
  out="$(env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG=en_US.UTF-8 "$DICTATE_BIN" app-config --json)"
  assert_contains "app_config_locale_exported_lang" "$out" '"locale_ctype": "en_US.UTF-8", "locale_collate": "en_US.UTF-8"'
  printf '%s\n' 'export LC_ALL=C' >"$HOME/.zshenv"
  out="$(env -u LC_ALL -u LC_CTYPE -u LC_COLLATE LANG=en_US.UTF-8 "$DICTATE_BIN" app-config --json)"
  assert_contains "app_config_locale_exported_c" "$out" '"locale_ctype": "C", "locale_collate": "C"'
  rm -f "$HOME/.zshenv"

  out="$(printf 'um the the codex [blank audio] color\n\n' | DICTATE_CLEAN=1 "$DICTATE_BIN" inline cleanup --app Safari --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok", r
assert r["raw_text"] == "the codex color", r["raw_text"]
assert r["text"] == "the Codex colour", r["text"]
assert r["cleanup"]["clean"] == "1", r["cleanup"]
' || { echo "$out" >&2; fail "app_inline_cleanup_json"; }
  pass "app_inline_cleanup_json"

  out="$(printf '[blank audio]' | "$DICTATE_BIN" inline cleanup --app Safari --json)"
  assert_contains "app_inline_cleanup_no_speech" "$out" '"status": "no_speech"'

  out="$(DICTATE_APP_HOTKEY="cmd+shift+d" "$DICTATE_BIN" app-config --json)"
  assert_contains "app_config_hotkey_override" "$out" '"hotkey": "cmd+shift+d"'

  out="$("$DICTATE_BIN" inline process "$CASE_DIR/take.wav" --app Safari --record-ms 3000 --startup-ms 9 --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok", r
assert r["text"] == "Codex app transcript", r["text"]
assert r["raw_text"] == "codex app transcript", r["raw_text"]
assert r["delivery"]["autosend"] is True and r["delivery"]["paste_target"] == "current", r["delivery"]
assert r["timings"]["record_ms"] == 3000, r["timings"]
' || { echo "$out" >&2; fail "app_process_json_ok"; }
  pass "app_process_json_ok"
  assert_path_absent "app_process_no_clipboard" "$DICTATE_TEST_PBCOPY_OUT"
  assert_path_absent "app_process_no_osascript" "$DICTATE_TEST_OSASCRIPT_LOG"
  assert_path_absent "app_process_no_sounds" "$DICTATE_TEST_SOUND_LOG"
  assert_file_contains "app_process_usage_recorded" "$DICTATE_CONFIG_DIR/usage.json" '"inline": 1'
  assert_file_contains "app_process_bench_source" "$DICTATE_CONFIG_DIR/history/bench.tsv" "app:avaudioengine"
  [[ -f "$CASE_DIR/take.wav" ]] || fail "app_process_keeps_callers_wav"
  pass "app_process_keeps_callers_wav"
}

# A failing cleanup stage keeps its pre-extraction semantics: under set -e it
# aborts with the stage's own status; where errexit is off (inline process
# runs the pipeline under `|| rc=$?`) the partial text carries on.
run_cleanup_stage_failure_round() {
  setup_case "cleanup-stage-failure"
  export DICTATE_TEST_SWIFT_TEXT="stage failure transcript"
  export DICTATE_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local failing_lib="$CASE_DIR/dictate-lib-failing-sanitize.sh"
  {
    cat "$ROOT/bin/dictate-lib.sh"
    printf '%s\n' 'dictate_lib_sanitize_transcript_artifacts() { cat; return 7; }'
  } >"$failing_lib"
  local out rc=0
  out="$(printf 'hello there' | DICTATE_LIB_PATH="$failing_lib" "$DICTATE_BIN" inline cleanup --app Safari --json 2>/dev/null)" || rc=$?
  assert_equals "cleanup_stage_failure_exit_status" "$rc" "7"

  out="$(DICTATE_LIB_PATH="$failing_lib" "$DICTATE_BIN" inline process "$CASE_DIR/take.wav" --app Safari --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] and r["status"] == "ok", r
assert r["raw_text"] == "stage failure transcript", r
' || { echo "$out" >&2; fail "cleanup_stage_failure_inline_process_continues"; }
  pass "cleanup_stage_failure_inline_process_continues"
}

# Lowkey's native path persists each take with `inline record` after
# delivery: the same bench/usage/history writers as `inline process`, usage
# only for delivered takes, and the [debug] keep_logs archive.
run_inline_record_round() {
  setup_case "inline-record"
  export DICTATE_ERROR_FLAG="$CASE_DIR/error.flag"
  local out bench

  out="$("$DICTATE_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
c = json.load(sys.stdin)
t = c["transcription"]
assert t["socket_path"].endswith(".sock") and t["model_path"], t
assert t["tail_pad_ms"] == "500" and t["tail_rescue"] is True and t["language"] == "en", t
assert t["chunking"] is False and t["silence_trim"] is False, t
assert t["processing_dir"].endswith("/processing"), t
assert c["pipeline"] == {"native": True, "verify": True, "supervise": True}, c["pipeline"]
' || { echo "$out" >&2; fail "app_config_transcription_section"; }
  pass "app_config_transcription_section"
  out="$(DICTATE_APP_NATIVE_PIPELINE=0 "$DICTATE_BIN" app-config --json)"
  assert_contains "app_config_native_pipeline_off" "$out" '"pipeline": {"native": false'
  assert_equals "app_config_supervise_default" "$(json_field "$out" pipeline.supervise)" "True"
  assert_contains "app_config_capabilities" "$out" '"capabilities": ["take_markers", "lifecycle_lock", "warmup_json"]'
  printf '[app]\nsupervise_daemon = false\n' >"$DICTATE_CONFIG_FILE"
  out="$("$DICTATE_BIN" app-config --json)"
  assert_equals "app_config_supervise_off" "$(json_field "$out" pipeline.supervise)" "False"
  rm -f "$DICTATE_CONFIG_FILE"

  # No locale at all is the C locale, even though Python itself coerces it to
  # C.UTF-8 in its own environment.
  out="$(env -u LC_ALL -u LC_CTYPE -u LC_COLLATE -u LANG "$DICTATE_BIN" app-config --json)"
  assert_contains "app_config_locale_unset_is_c" "$out" '"locale_ctype": "", "locale_collate": ""'

  printf '%s' '{"take_id":"t-ok","status":"ok","delivered":true,"raw_text":"open ai","text":"OpenAI","mode":"code",
    "app":"Ghostty","record_ms":3000,"transcribe_ms":400,"clean_ms":3,"paste_ms":50,"total_ms":3500,"startup_ms":12,
    "started_at_ms":1000,"delivered_at_ms":4600,"capture_wav_ms":3010,"capture_wav_bytes":96364}' \
    | "$DICTATE_BIN" inline record --json >"$CASE_DIR/record-ok.json"
  assert_file_contains "inline_record_ok_usage" "$CASE_DIR/record-ok.json" '"usage_recorded": true'
  assert_file_contains "inline_record_usage_ledger" "$DICTATE_CONFIG_DIR/usage.json" '"inline": 1'
  assert_file_contains "inline_record_usage_elapsed" "$DICTATE_CONFIG_DIR/usage.json" '"full_elapsed_duration_ms": 3600'
  bench="$(tail -n 1 "$DICTATE_CONFIG_DIR/history/bench.tsv")"
  assert_contains "inline_record_bench_row" "$bench" $'\tinline\tok\t'
  assert_contains "inline_record_bench_source" "$bench" $'\t3000\t400\t3\t0\t50\t3500\t12\t0\t0\t0\tapp:native'
  [[ -f "$DICTATE_PROCESSED_FLAG" ]] || fail "inline_record_signals_processed"
  pass "inline_record_signals_processed"
  python3 - "$DICTATE_CONFIG_DIR/history" <<'PYEOF' || fail "inline_record_history"
import glob, json, os, sys
files = sorted(glob.glob(os.path.join(sys.argv[1], "*.json")))
assert len(files) == 1, files
h = json.load(open(files[0]))
assert h["raw"] == "open ai" and h["processed"] == "OpenAI" and h["mode"] == "code" and h["app"] == "Ghostty", h
assert h["metrics"]["total_ms"] == 3500 and h["audio"]["capture_gap_to_record_ms"] == 10, h
PYEOF
  pass "inline_record_history"

  # A replayed take (Lowkey's spool after a quit timeout or crash) is
  # recorded once.
  printf '%s' '{"take_id":"t-ok","status":"ok","delivered":true,"raw_text":"open ai","text":"OpenAI","mode":"code"}' \
    | "$DICTATE_BIN" inline record --json >"$CASE_DIR/record-dup.json"
  assert_file_contains "inline_record_duplicate_detected" "$CASE_DIR/record-dup.json" '"duplicate": true'
  assert_file_contains "inline_record_duplicate_usage_once" "$DICTATE_CONFIG_DIR/usage.json" '"inline": 1'

  # A second take in the same second gets its own history file.
  printf '%s' '{"take_id":"t-ok2","status":"ok","delivered":true,"raw_text":"b","text":"b","mode":"code"}' \
    | "$DICTATE_BIN" inline record --json >/dev/null
  printf '%s' '{"take_id":"t-ok3","status":"ok","delivered":true,"raw_text":"c","text":"c","mode":"code"}' \
    | "$DICTATE_BIN" inline record --json >/dev/null
  python3 - "$DICTATE_CONFIG_DIR/history" <<'PYEOF' || fail "inline_record_history_unique_names"
import glob, json, os, sys
files = glob.glob(os.path.join(sys.argv[1], "*.json"))
assert len(files) == 3, files
assert sorted(json.load(open(f))["processed"] for f in files) == ["OpenAI", "b", "c"]
PYEOF
  pass "inline_record_history_unique_names"

  # Failed delivery: bench row and error flag, but no usage and no history.
  printf '%s' '{"take_id":"t-fail","status":"paste_failed","delivered":false,"raw_text":"x","text":"x","mode":"code"}' \
    | "$DICTATE_BIN" inline record --json >"$CASE_DIR/record-fail.json"
  assert_file_contains "inline_record_failed_no_usage" "$CASE_DIR/record-fail.json" '"usage_recorded": false'
  assert_file_contains "inline_record_failed_usage_unchanged" "$DICTATE_CONFIG_DIR/usage.json" '"inline": 3'
  [[ "$(ls "$DICTATE_CONFIG_DIR/history"/*.json | wc -l | tr -d ' ')" == "3" ]] || fail "inline_record_failed_no_history"
  pass "inline_record_failed_no_history"
  assert_contains "inline_record_failed_bench" "$(tail -n 1 "$DICTATE_CONFIG_DIR/history/bench.tsv")" $'\tpaste_failed\t'
  [[ -f "$DICTATE_ERROR_FLAG" ]] || fail "inline_record_failed_error_flag"
  pass "inline_record_failed_error_flag"

  printf '%s' '{"take_id":"t-none","status":"no_speech","delivered":false}' | "$DICTATE_BIN" inline record --json >/dev/null
  assert_contains "inline_record_no_speech_bench" "$(tail -n 1 "$DICTATE_CONFIG_DIR/history/bench.tsv")" $'\tno_speech\t'

  # [debug] keep_logs: the handed-over WAV is archived and removed.
  printf 'RIFF fake wav' >"$CASE_DIR/take-padded.wav"
  printf '{"take_id":"t-keep","status":"ok","delivered":true,"raw_text":"k","text":"k","mode":"code","wav_path":"%s"}' \
    "$CASE_DIR/take-padded.wav" | DICTATE_KEEP_LOGS=1 "$DICTATE_BIN" inline record --json >/dev/null
  assert_path_absent "inline_record_keep_logs_wav_moved" "$CASE_DIR/take-padded.wav"
  ls "$DICTATE_CONFIG_DIR/history/inline-debug/"*t-keep.wav >/dev/null 2>&1 || fail "inline_record_keep_logs_archive_wav"
  pass "inline_record_keep_logs_archive_wav"
  ls "$DICTATE_CONFIG_DIR/history/inline-debug/"*t-keep.meta >/dev/null 2>&1 || fail "inline_record_keep_logs_archive_meta"
  pass "inline_record_keep_logs_archive_meta"

  # A take recovered at quit (never pasted): history, no usage.
  local usage_before
  usage_before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$DICTATE_CONFIG_DIR/usage.json")"
  printf '%s' '{"take_id":"t-recovered","status":"recovered","delivered":false,"raw_text":"saved at quit","text":"Saved at quit","mode":"code"}' \
    | "$DICTATE_BIN" inline record --json >"$CASE_DIR/record-recovered.json"
  assert_file_contains "inline_record_recovered_no_usage" "$CASE_DIR/record-recovered.json" '"usage_recorded": false'
  assert_file_contains "inline_record_recovered_history" "$CASE_DIR/record-recovered.json" '"history_saved": true'
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["delivered_dictations"]["count"])' "$DICTATE_CONFIG_DIR/usage.json")" == "$usage_before" ]] \
    || fail "inline_record_recovered_usage_unchanged"
  pass "inline_record_recovered_usage_unchanged"
  grep -rq '"processed": "Saved at quit"' "$DICTATE_CONFIG_DIR/history/" || fail "inline_record_recovered_history_file"
  pass "inline_record_recovered_history_file"
  assert_contains "inline_record_recovered_bench" "$(tail -n 1 "$DICTATE_CONFIG_DIR/history/bench.tsv")" $'\trecovered\t'

  # Concurrent writers on a bench at its row limit: every new row survives
  # the trims (appends and trims share one lock).
  local i
  : >"$DICTATE_CONFIG_DIR/history/bench.tsv"
  for i in $(seq 1 30); do
    printf 'old\tinline\tok\tm\tpad%s\n' "$i" >>"$DICTATE_CONFIG_DIR/history/bench.tsv"
  done
  for i in $(seq 1 10); do
    printf '{"take_id":"c%s","status":"ok","delivered":false,"mode":"conc%s"}' "$i" "$i" \
      | DICTATE_BENCH_MAX_ROWS=30 "$DICTATE_BIN" inline record --json >/dev/null &
  done
  wait
  [[ "$(wc -l <"$DICTATE_CONFIG_DIR/history/bench.tsv" | tr -d ' ')" == "30" ]] || fail "inline_record_bench_trimmed"
  pass "inline_record_bench_trimmed"
  for i in $(seq 1 10); do
    grep -q $'\tconc'"$i"$'\t' "$DICTATE_CONFIG_DIR/history/bench.tsv" || fail "inline_record_concurrent_bench_row_$i"
  done
  pass "inline_record_concurrent_bench_rows"
  assert_path_absent "inline_record_bench_lock_released" "$DICTATE_CONFIG_DIR/history/bench.tsv.lock.d"

  local rc=0
  printf 'not json' | "$DICTATE_BIN" inline record --json >/dev/null 2>&1 || rc=$?
  [[ "$rc" != "0" ]] || fail "inline_record_rejects_bad_payload"
  pass "inline_record_rejects_bad_payload"
  unset DICTATE_ERROR_FLAG
}

# A malformed config.toml (e.g. half-saved mid-edit) falls back to the last
# valid copy, not to the defaults, which would turn autosend back on.
run_config_last_good_round() {
  setup_case "config-last-good"
  # Earlier rounds export inline overrides; this round tests config.toml itself.
  unset DICTATE_AUTOSEND DICTATE_INLINE_SEND_MODE
  export DICTATE_TEST_SWIFT_TEXT="config fallback transcript"
  export DICTATE_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local out
  printf '[meta]\nconfig_version = 1\n\n[inline]\nautosend = false\nsend_mode = "cmd_enter"\n' >"$DICTATE_CONFIG_FILE"

  out="$("$DICTATE_BIN" app-config --json)"
  assert_contains "config_valid_status" "$out" '"config": {"error": null, "source": "file"}'
  assert_contains "config_valid_autosend_off" "$out" '"autosend": false'
  [[ -f "$(dirname "$DICTATE_CONFIG_FILE")/.config.toml.last-good" ]] || fail "config_last_good_saved"
  pass "config_last_good_saved"

  printf '[meta]\nconfig_version = 1\n\n[inline]\nautosend = fal' >"$DICTATE_CONFIG_FILE"
  out="$("$DICTATE_BIN" app-config --json)"
  printf '%s' "$out" | python3 -c '
import json, sys
c = json.load(sys.stdin)
assert c["config"]["error"] and c["config"]["source"] == "last_good", c["config"]
assert c["inline"]["autosend"] is False and c["inline"]["send_mode"] == "cmd_enter", c["inline"]
' || { echo "$out" >&2; fail "config_invalid_uses_last_good"; }
  pass "config_invalid_uses_last_good"

  out="$("$DICTATE_BIN" inline process "$CASE_DIR/take.wav" --app Safari --json)"
  assert_contains "config_invalid_inline_process_last_good" "$out" '"autosend": false'
  out="$("$DICTATE_BIN" doctor 2>&1 || true)"
  assert_contains "config_invalid_doctor_says_last_good" "$out" "the last valid copy of config.toml"

  # Snapshots that parse but aren't trustworthy are invalid too, and never
  # replace the copy: an empty file (e.g. mid-write) and a non-boolean switch.
  local copy
  copy="$(dirname "$DICTATE_CONFIG_FILE")/.config.toml.last-good"
  : >"$DICTATE_CONFIG_FILE"
  out="$("$DICTATE_BIN" app-config --json)"
  assert_contains "config_empty_uses_last_good" "$out" '"source": "last_good"'
  assert_contains "config_empty_keeps_autosend_off" "$out" '"autosend": false'
  printf '[inline]\nautosend = "false"\n' >"$DICTATE_CONFIG_FILE"
  out="$("$DICTATE_BIN" app-config --json)"
  assert_contains "config_string_bool_rejected" "$out" 'inline.autosend must be true or false'
  assert_contains "config_string_bool_keeps_autosend_off" "$out" '"autosend": false'
  assert_file_contains "config_copy_not_replaced" "$copy" 'autosend = false'

  # An unreadable file recovers from the copy too.
  printf '[inline]\nautosend = true\n' >"$DICTATE_CONFIG_FILE"
  chmod 000 "$DICTATE_CONFIG_FILE"
  out="$("$DICTATE_BIN" app-config --json 2>/dev/null || true)"
  chmod 600 "$DICTATE_CONFIG_FILE"
  assert_contains "config_unreadable_uses_last_good" "$out" '"source": "last_good"'
  assert_contains "config_unreadable_keeps_autosend_off" "$out" '"autosend": false'

  # No trustworthy settings at all: defaults, but never sending, in every flow.
  rm -f "$copy"
  printf '[inline\nautosend = fal' >"$DICTATE_CONFIG_FILE"
  out="$("$DICTATE_BIN" app-config --json)"
  assert_contains "config_invalid_no_copy_reports_defaults" "$out" '"source": "defaults"'
  assert_contains "config_invalid_no_copy_inline_autosend_off" "$out" '"autosend": false'
  out="$("$DICTATE_BIN" debug 2>&1 || true)"
  assert_contains "config_invalid_no_copy_tmux_autosend_off" "$out" "tmux.autosend=0"
  [[ ! -e "$copy" ]] || fail "config_invalid_never_creates_copy"
  pass "config_invalid_never_creates_copy"

  # config_set writes atomically through a symlinked config.toml.
  local real="$CASE_DIR/dotfiles-config.toml"
  printf '[meta]\nconfig_version = 1\n\n[inline]\nautosend = true\n' >"$real"
  ln -sf "$real" "$DICTATE_CONFIG_FILE"
  "$DICTATE_BIN" autosend off >/dev/null
  [[ -L "$DICTATE_CONFIG_FILE" ]] || fail "config_set_keeps_symlink"
  pass "config_set_keeps_symlink"
  assert_file_contains "config_set_updates_target" "$real" 'autosend = false'
  unset DICTATE_TEST_SWIFT_TEXT DICTATE_TEST_FFPROBE_DURATION_MS
}

run_app_backend_failure_round() {
  setup_case "app-backend-failure"
  export DICTATE_TEST_SWIFT_DAEMON_FAIL=1
  export DICTATE_TEST_FFPROBE_DURATION_MS=3000
  printf '%s\n' "app take" >"$CASE_DIR/take.wav"
  local out rc=0
  out="$("$DICTATE_BIN" inline process "$CASE_DIR/take.wav" --json)" || rc=$?
  assert_equals "app_process_failure_exit_zero" "$rc" "0"
  printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["ok"] is False and r["status"] == "failed", r
assert r["text"] == "" and r["message"], r
' || { echo "$out" >&2; fail "app_process_failure_json"; }
  pass "app_process_failure_json"
  assert_path_absent "app_process_failure_no_usage" "$DICTATE_CONFIG_DIR/usage.json"
  unset DICTATE_TEST_SWIFT_DAEMON_FAIL
}

write_stubs
run_tmux_round "enter"
run_tmux_round "codex"
run_inline_vocab_round
run_inline_cmd_enter_round
run_inline_auto_mode_round
run_inline_toggle_round
run_inline_toggle_grace_override_round
run_inline_toggle_process_sound_immediate_round
run_inline_cancel_refresh_round
run_inline_processing_marker_immediate_after_stop_round
run_inline_processing_marker_until_paste_round
run_inline_by_name_skips_device_lookup_round
run_inline_by_name_failure_falls_back_to_index_round
run_inline_keep_logs_archive_round
run_inline_audio_retention_round
run_inline_swift_round
run_inline_swift_tail_rescue_round
run_inline_swift_chunked_round
run_inline_swift_chunking_default_off_round
run_inline_swift_chunked_tail_boundary_round
run_inline_swift_superseded_round
run_tmux_audio_cache_note_round
run_status_postprocess_round
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
run_app_backend_failure_round
run_config_last_good_round
run_inline_record_round
run_cleanup_stage_failure_round
run_finder_quick_action_round
run_finder_handler_round

assert_registered_stub_process
cleanup_stub_daemons
assert_no_registered_stub_processes

echo "Flow parity tests passed."
