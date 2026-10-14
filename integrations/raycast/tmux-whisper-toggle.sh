#!/usr/bin/env bash

# @raycast.schemaVersion 1
# @raycast.title Tmux Whisper Toggle (tmux)
# @raycast.mode silent
# @raycast.packageName Tmux Whisper
# @raycast.description Toggle recording → paste+Enter into tmux pane
# tmux-whisper.adapter: raycast-toggle
# tmux-whisper.adapter-version: 2

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export DICTATE_CLEAN=1

if [[ -f "$HOME/.zshenv" ]]; then
  # Load XDG vars + SOUNDS_DIR for Raycast environment
  source "$HOME/.zshenv"
fi

# Raycast often runs without interactive shell env; load API key similarly
# to the inline path so tmux postprocess can run reliably.
if [[ -z "${CEREBRAS_API_KEY:-}" && -f "${ZDOTDIR:-$HOME}/.zshrc" ]]; then
  eval "$(grep '^export CEREBRAS_API_KEY=' "${ZDOTDIR:-$HOME}/.zshrc" 2>/dev/null || true)"
fi

DICTATE_SOUNDS_DIR="${SOUNDS_DIR:-}/dictate"
CONFIG_TOML="$HOME/.config/dictate/config.toml"
DICTATE_BIN="${DICTATE_BIN:-$(command -v tmux-whisper 2>/dev/null || true)}"
DICTATE_BIN="${DICTATE_BIN:-$HOME/.local/bin/tmux-whisper}"

notify() {
  local msg="${1:-Tmux Whisper error}"
  local escaped="${msg//\"/\\\"}"
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$escaped\" with title \"Tmux Whisper\"" 2>/dev/null || true
}

die_with_notice() {
  local msg="${1:-Unknown error}"
  echo "tmux-whisper-toggle: $msg" >&2
  notify "$msg"
  exit 1
}

expand_sound_path() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  if [[ "$p" == "~"* ]]; then
    p="$HOME${p:1}"
  fi
  if [[ -n "${SOUNDS_DIR:-}" ]]; then
    p="${p//\$\{SOUNDS_DIR\}/$SOUNDS_DIR}"
    p="${p//\$SOUNDS_DIR/$SOUNDS_DIR}"
  fi
  printf "%s" "$p"
}

load_config_sounds() {
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$CONFIG_TOML" ]] || return 0
  eval "$(
    python3 - "$CONFIG_TOML" <<'PYEOF'
import os, shlex, sys, tomllib

path = os.path.expanduser(sys.argv[1])
with open(path, "rb") as f:
  cfg = tomllib.load(f) or {}

def get_raw(path, default=None):
  cur = cfg
  for part in path.split("."):
    if not isinstance(cur, dict) or part not in cur:
      return default
    cur = cur[part]
  return cur

def get_str(path, default=""):
  v = get_raw(path, default)
  return "" if v is None else str(v)

def b(v, default=True):
  if v is None:
    return default
  if isinstance(v, bool):
    return v
  s = str(v).strip().lower()
  if s in ("1", "true", "yes", "on"):
    return True
  if s in ("0", "false", "no", "off"):
    return False
  return default

out = {
  "CFG_AUDIO_SOUNDS_START": get_str("audio.sounds.start", ""),
  "CFG_AUDIO_SOUNDS_STOP": get_str("audio.sounds.stop", ""),
  "CFG_AUDIO_SOUNDS_ENABLED": "1" if b(get_raw("audio.sounds.enabled", True), True) else "0",
  "CFG_AUDIO_SOUNDS_START_ENABLED": "1" if b(get_raw("audio.sounds.start_enabled", True), True) else "0",
  "CFG_AUDIO_SOUNDS_STOP_ENABLED": "1" if b(get_raw("audio.sounds.stop_enabled", True), True) else "0",
}

for k, v in out.items():
  print(f"{k}={shlex.quote(v)}")
PYEOF
  )"
}

sound_path() {
  local event="${1:-}"
  local cfg=""
  [[ "${CFG_AUDIO_SOUNDS_ENABLED:-1}" == "1" ]] || return 0
  case "$event" in
    start)
      [[ "${CFG_AUDIO_SOUNDS_START_ENABLED:-1}" == "1" ]] || return 0
      cfg="${CFG_AUDIO_SOUNDS_START:-}"
      ;;
    stop)
      [[ "${CFG_AUDIO_SOUNDS_STOP_ENABLED:-1}" == "1" ]] || return 0
      cfg="${CFG_AUDIO_SOUNDS_STOP:-}"
      ;;
    *) return 0 ;;
  esac

  if [[ -n "$cfg" ]]; then
    cfg="$(expand_sound_path "$cfg")"
  else
    cfg="$DICTATE_SOUNDS_DIR/$event.wav"
  fi

  [[ -f "$cfg" ]] && printf "%s" "$cfg"
}

load_config_sounds

STATE_FILE="/tmp/whisper-dictate.state"

if [[ ! -x "$DICTATE_BIN" ]]; then
  die_with_notice "Tmux Whisper binary not found. Install via brew or ./install.sh --force."
fi

if ! command -v tmux >/dev/null 2>&1; then
  die_with_notice "tmux not found in PATH."
fi

if ! tmux list-sessions &>/dev/null; then
  notify "No tmux session running."
  exit 1
fi

PANE="$(tmux display-message -p '#{pane_id}' 2>/dev/null || tmux list-panes -F '#{pane_id}' | head -1)"
export DICTATE_TARGET_PANE="$PANE"

if [[ -f "$STATE_FILE" ]]; then
  # Stopping - just play sound
  "$DICTATE_BIN" toggle 2>/tmp/dictate-raycast.log
  # Stop sound is played by Tmux Whisper after transcription/paste completes.
else
  # Starting - just play sound
  "$DICTATE_BIN" toggle 2>/tmp/dictate-raycast.log
  p="$(sound_path start)"
  # Raycast can terminate background children when the script exits; play synchronously.
  [[ -n "$p" ]] && afplay "$p" 2>/dev/null
fi
