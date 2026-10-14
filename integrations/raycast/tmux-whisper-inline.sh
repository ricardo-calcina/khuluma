#!/usr/bin/env bash

# @raycast.schemaVersion 1
# @raycast.title Tmux Whisper Inline
# @raycast.mode silent
# @raycast.packageName Tmux Whisper
# @raycast.description Toggle recording → paste into frontmost app
# tmux-whisper.adapter: raycast-inline
# tmux-whisper.adapter-version: 2

set -euo pipefail

LOG="/tmp/dictate-raycast-inline.log"
exec >> "$LOG" 2>&1
echo "=== $(date) ==="

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export DICTATE_CLEAN=1
INLINE_STATE_FILE="/tmp/whisper-dictate-inline.state"
DICTATE_ZSHENV_LOADED="0"

load_zshenv_once() {
  [[ "$DICTATE_ZSHENV_LOADED" == "1" ]] && return 0
  [[ -f "$HOME/.zshenv" ]] || return 0
  source "$HOME/.zshenv"
  DICTATE_ZSHENV_LOADED="1"
}

resolve_dictate_bin() {
  local candidate=""
  if [[ -n "${DICTATE_BIN:-}" ]]; then
    printf '%s\n' "${DICTATE_BIN}"
    return 0
  fi

  candidate="$HOME/.local/bin/tmux-whisper"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(command -v tmux-whisper 2>/dev/null || true)"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  load_zshenv_once
  candidate="${DICTATE_BIN:-$HOME/.local/bin/tmux-whisper}"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(command -v tmux-whisper 2>/dev/null || true)"
  printf '%s\n' "$candidate"
}

maybe_load_inline_api_key() {
  # The API key is only needed on stop/transcribe paths. Skip this on start
  # so the hotkey path stays as close to instant as possible.
  [[ -f "$INLINE_STATE_FILE" ]] || return 0
  [[ -n "${CEREBRAS_API_KEY:-}" ]] && return 0

  load_zshenv_once
  [[ -n "${CEREBRAS_API_KEY:-}" ]] && return 0

  if [[ -f "${ZDOTDIR:-$HOME}/.zshrc" ]]; then
    eval "$(grep '^export CEREBRAS_API_KEY=' "${ZDOTDIR:-$HOME}/.zshrc" 2>/dev/null || true)"
  fi
}

maybe_load_inline_api_key
DICTATE_BIN="$(resolve_dictate_bin)"

notify_inline_error() {
  local msg="${1:-Tmux Whisper inline error}"
  local escaped="${msg//\"/\\\"}"
  echo "ERROR: $msg"
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$escaped\" with title \"Tmux Whisper Inline\"" 2>/dev/null || true
}

if [[ ! -x "$DICTATE_BIN" ]]; then
  notify_inline_error "Tmux Whisper binary not found. Install via brew or ./install.sh --force."
  exit 1
fi

if ! "$DICTATE_BIN" inline toggle; then
  notify_inline_error "Tmux Whisper inline failed. Check $LOG."
  exit 1
fi
