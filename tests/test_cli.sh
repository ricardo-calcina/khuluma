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
mkdir -p "$BIN_DIR" "$HOME_DIR"
OPLOG="$TMP_ROOT/daemon-ops.log"

install_test_runtime() {
  local dest_bin="$1"
  mkdir -p "$dest_bin"
  cp "$ROOT/bin/khuluma" "$dest_bin/khuluma"
  cp "$ROOT/bin/khuluma-lib.sh" "$dest_bin/khuluma-lib.sh"
  preserve_fixture "$dest_bin/khuluma-lib"
  mkdir -p "$dest_bin/khuluma-lib"
  cp -R "$ROOT/bin/khuluma-lib/." "$dest_bin/khuluma-lib/"
  chmod +x "$dest_bin/khuluma" "$dest_bin/khuluma-lib.sh"
}

install_test_runtime "$BIN_DIR"

# Ensure the default ~/.local/bin path is unavailable and fallback-to-sibling works.
output="$(HOME="$HOME_DIR" PATH="$BIN_DIR:/usr/bin:/bin" KHULUMA_LIB_PATH= "$BIN_DIR/khuluma" --help)"

if [[ "$output" != *"khuluma: the back end for Khuluma (the menu-bar dictation app) and file transcription"* ]]; then
  echo "Expected help output from khuluma command" >&2
  exit 1
fi
if [[ "$output" != *"KHULUMA_TRANSCRIBE_TAIL_PAD_MS=500"* ]]; then
  echo "Expected help output to document transcription tail padding" >&2
  exit 1
fi
if [[ "$output" != *"KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE=0|1"* ]]; then
  echo "Expected help output to document Swift tail rescue tuning" >&2
  exit 1
fi
if [[ "$output" != *"khuluma last [--json]"* ]]; then
  echo "Expected help output to document the last command" >&2
  exit 1
fi
if [[ "$output" != *"khuluma status [--json] [--preset compact]"* ]]; then
  echo "Expected help output to document compact status preset" >&2
  exit 1
fi
if [[ "$output" != *"khuluma history list [N] [--json]"* ]]; then
  echo "Expected help output to document history list JSON output" >&2
  exit 1
fi
if [[ "$output" != *"khuluma history search <query> [N] [--json]"* ]]; then
  echo "Expected help output to document history search" >&2
  exit 1
fi
if [[ "$output" != *"khuluma history export [N|all] [--json]"* ]]; then
  echo "Expected help output to document history export" >&2
  exit 1
fi
if [[ "$output" != *"khuluma history sessions [N] [--json]"* ]]; then
  echo "Expected help output to document history sessions" >&2
  exit 1
fi
if [[ "$output" != *"khuluma transcribe <file>..."* ]]; then
  echo "Expected help output to document file transcription" >&2
  exit 1
fi
transcribe_help="$(HOME="$HOME_DIR" PATH="$BIN_DIR:/usr/bin:/bin" KHULUMA_LIB_PATH= "$BIN_DIR/khuluma" transcribe --help)"
if [[ "$transcribe_help" != *"usage: khuluma transcribe <file|->..."* || "$transcribe_help" != *"--beside"* ]]; then
  echo "Expected transcribe --help to describe inputs and output options" >&2
  exit 1
fi
transcribe_rc=0
HOME="$HOME_DIR" PATH="$BIN_DIR:/usr/bin:/bin" KHULUMA_LIB_PATH= "$BIN_DIR/khuluma" transcribe >/dev/null 2>&1 || transcribe_rc=$?
if [[ "$transcribe_rc" != "2" ]]; then
  echo "Expected transcribe without inputs to exit 2 (got $transcribe_rc)" >&2
  exit 1
fi
if [[ "$output" != *"khuluma usage [--json]"* ]]; then
  echo "Expected help output to document durable usage summary" >&2
  exit 1
fi
if [[ "$output" != *"KHULUMA_HISTORY_RETENTION_DAYS=7"* ]]; then
  echo "Expected help output to document history JSON retention" >&2
  exit 1
fi
if [[ "$output" != *"KHULUMA_HISTORY_AUDIO_RETENTION_DAYS=2"* ]]; then
  echo "Expected help output to document history audio retention" >&2
  exit 1
fi
if [[ "$output" != *"khuluma config defaults"* ]]; then
  echo "Expected help output to document config defaults" >&2
  exit 1
fi
if [[ "$output" != *"khuluma config [--json]"* ]]; then
  echo "Expected help output to document config JSON output" >&2
  exit 1
fi
if [[ "$output" != *"khuluma config path [--json]"* ]]; then
  echo "Expected help output to document config path JSON output" >&2
  exit 1
fi
if [[ "$output" != *"khuluma config get <path> [--json]"* ]]; then
  echo "Expected help output to document config get" >&2
  exit 1
fi
if [[ "$output" != *"khuluma config repair [--dry-run]"* ]]; then
  echo "Expected help output to document config repair" >&2
  exit 1
fi
if [[ "$output" != *"khuluma bench [N|all] [--json]"* ]]; then
  echo "Expected help output to document bench JSON output" >&2
  exit 1
fi
if [[ "$output" != *"khuluma bench export [N|all] [--json]"* ]]; then
  echo "Expected help output to document bench export" >&2
  exit 1
fi
if [[ "$output" != *"khuluma vocab import [--dry-run] <file>"* ]]; then
  echo "Expected help output to document vocab import dry-run" >&2
  exit 1
fi
if [[ "$output" != *"khuluma vocab rm [--dry-run] [--regex] \"pattern\""* ]]; then
  echo "Expected help output to document safer vocab removal" >&2
  exit 1
fi
if [[ "$output" != *"CONFIG FILES (under ~/.config/khuluma/ by default):"* ]]; then
  echo "Expected help output to explain the canonical Khuluma config path" >&2
  exit 1
fi

default_output="$(HOME="$HOME_DIR" PATH="$BIN_DIR:/usr/bin:/bin" KHULUMA_LIB_PATH= "$BIN_DIR/khuluma" config defaults)"
repo_default="$(cat "$ROOT/config/config.toml")"
if [[ "$default_output" != "$repo_default" ]]; then
  echo "Expected config defaults output to match repo default config" >&2
  exit 1
fi
if [[ -e "$HOME_DIR/.config/khuluma/config.toml" ]]; then
  echo "Expected config defaults to avoid creating a live config file" >&2
  exit 1
fi

MODEL_DIR="$TMP_ROOT/parakeet-tdt-0.6b-v3-coreml"
CONFIG_DIR="$HOME_DIR/.config/khuluma"
mkdir -p "$MODEL_DIR" "$CONFIG_DIR"
cat >"$CONFIG_DIR/config.toml" <<EOF
[meta]
config_version = 1

[audio]
source = "auto"

[swift_parakeet]
model_path = "$MODEL_DIR"
socket_path = "$TMP_ROOT/khulumad.sock"
EOF

cat >"$BIN_DIR/khulumad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "serve" || "${2:-}" != "--socket" || -z "${3:-}" ]]; then
  echo "usage: khulumad serve --socket <path>" >&2
  exit 2
fi
socket_path="$3"
python3 - "$socket_path" <<'PYEOF'
import json
import os
import socket
import sys

socket_path = sys.argv[1]
try:
    os.rename(socket_path, socket_path + ".retained." + __import__("uuid").uuid4().hex)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(8)
log_path = os.environ.get("KHULUMA_TEST_CLI_OPLOG", "")

while True:
    conn, _ = server.accept()
    try:
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        raw = data.split(b"\n", 1)[0]
        request = json.loads(raw.decode("utf-8"))
        op = request.get("op")
        if log_path:
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(f"{op}\n")
        if op == "ping":
            response = {
                "id": request.get("id", "stub"),
                "ok": True,
                "engine": "swift_parakeet",
                "duration_ms": 0,
                "message": "ok",
            }
        elif op == "warmup":
            response = {
                "id": request.get("id", "stub"),
                "ok": True,
                "engine": "swift_parakeet",
                "model": os.path.basename(request.get("model_path", "")),
                "duration_ms": 12,
                "message": "warmed",
            }
        elif op == "transcribe":
            wav_path = request.get("wav_path", "")
            if not wav_path or not os.path.exists(wav_path):
                raise SystemExit("missing warmup wav_path")
            import wave
            with wave.open(wav_path, "rb") as wav_file:
                frames = wav_file.getnframes()
                sample_rate = wav_file.getframerate()
            if sample_rate != 16000:
                raise SystemExit(f"warmup prime sample rate mismatch: {sample_rate}")
            duration_ms = int((frames / sample_rate) * 1000)
            if duration_ms < 1000:
                raise SystemExit(f"warmup prime audio too short: {duration_ms}ms")
            response = {
                "id": request.get("id", "stub"),
                "ok": True,
                "engine": "swift_parakeet",
                "model": os.path.basename(request.get("model_path", "")),
                "text": "",
                "duration_ms": 4,
                "message": None,
            }
        else:
            response = {
                "id": request.get("id", "stub"),
                "ok": False,
                "engine": "swift_parakeet",
                "error_code": "unsupported_operation",
                "message": op or "unknown",
            }
        conn.sendall(json.dumps(response).encode("utf-8") + b"\n")
        if op == "transcribe":
            break
    finally:
        conn.close()

server.close()
try:
    os.rename(socket_path, socket_path + ".retained." + __import__("uuid").uuid4().hex)
except FileNotFoundError:
    pass
PYEOF
EOF
chmod +x "$BIN_DIR/khulumad"

warmup_output="$(HOME="$HOME_DIR" PATH="$BIN_DIR:/usr/bin:/bin" KHULUMA_LIB_PATH= KHULUMA_CONFIG_DIR="$CONFIG_DIR" KHULUMA_CONFIG_FILE="$CONFIG_DIR/config.toml" KHULUMA_DAEMON_BIN="$BIN_DIR/khulumad" KHULUMA_TEST_CLI_OPLOG="$OPLOG" "$BIN_DIR/khuluma" warmup)"

if [[ "$warmup_output" != *"Warmup: ready (model=parakeet-tdt-0.6b-v3-coreml, duration=12ms)"* ]]; then
  echo "Expected warmup output from khuluma command" >&2
  echo "$warmup_output" >&2
  exit 1
fi

if ! grep -Fxq "warmup" "$OPLOG" || ! grep -Fxq "transcribe" "$OPLOG"; then
  echo "Expected warmup command to prime with a synthetic transcribe" >&2
  cat "$OPLOG" >&2 || true
  exit 1
fi

preserve_fixture "$OPLOG"

warmup_output="$(HOME="$HOME_DIR" PATH="$BIN_DIR:/usr/bin:/bin" KHULUMA_LIB_PATH= KHULUMA_CONFIG_DIR="$CONFIG_DIR" KHULUMA_CONFIG_FILE="$CONFIG_DIR/config.toml" KHULUMA_DAEMON_BIN="$BIN_DIR/khulumad" KHULUMA_TEST_CLI_OPLOG="$OPLOG" KHULUMA_WARMUP_PRIME_MS=0800 "$BIN_DIR/khuluma" warmup)"

if [[ "$warmup_output" != *"Warmup: ready (model=parakeet-tdt-0.6b-v3-coreml, duration=12ms)"* ]]; then
  echo "Expected warmup output with leading-zero prime duration override" >&2
  echo "$warmup_output" >&2
  exit 1
fi

if ! grep -Fxq "warmup" "$OPLOG" || ! grep -Fxq "transcribe" "$OPLOG"; then
  echo "Expected warmup command with leading-zero override to complete prime transcribe" >&2
  cat "$OPLOG" >&2 || true
  exit 1
fi

echo "CLI relocation smoke test passed."
