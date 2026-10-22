#!/usr/bin/env bash
# khuluma.adapter: finder-transcribe
# khuluma.adapter-version: 1
#
# Finder Quick Action handler: transcribe the selected audio files with
# `khuluma transcribe`, write <name>.txt next to each one, copy the
# transcript to the clipboard, and post a notification.
#
# Automator/Shortcuts pass the selected files as arguments and run with a
# minimal PATH, so resolve the CLI explicitly.

set -uo pipefail

# This installed handler has no imported CLI library. Refuse obsolete inputs
# before writing logs, notifying or invoking a transcription command.
for variable in "${!DICTATE_@}" LOWKEY_KEYCHAIN LOWKEY_SIGNING_IDENTITY; do
  if declare -p "$variable" >/dev/null 2>&1; then
    printf 'khuluma: obsolete environment input %s; remove it and use supported KHULUMA_* settings\n' "$variable" >&2
    exit 2
  fi
done
LOG="${KHULUMA_FINDER_TRANSCRIBE_LOG:-${KHULUMA_TMPDIR:-/tmp}/khuluma-finder.log}"
EXPLICIT_BIN="${KHULUMA_CLI:-${KHULUMA_BIN:-}}"

# Fire-and-forget: the first notification from a Quick Action can wait on a
# macOS permission prompt, which must never hold up the transcription.
notify() {
  local message="$1"
  if [[ -n "${KHULUMA_FINDER_NOTIFY_LOG:-}" ]]; then
    printf '%s\n' "$message" >>"$KHULUMA_FINDER_NOTIFY_LOG"
    return 0
  fi
  /usr/bin/osascript - "$message" <<'APPLESCRIPT' >/dev/null 2>&1 &
on run argv
  display notification (item 1 of argv) with title "Khuluma"
end run
APPLESCRIPT
}

resolve_bin() {
  local candidate
  if [[ -n "$EXPLICIT_BIN" ]]; then
    [[ -f "$EXPLICIT_BIN" && -x "$EXPLICIT_BIN" ]] || return 1
    printf '%s\n' "$EXPLICIT_BIN"
    return 0
  fi
  # Resolve only canonical commands; an old real CLI is never a fallback writer.
  for candidate in \
    "$HOME/.local/bin/khuluma" \
    /opt/homebrew/bin/khuluma \
    /usr/local/bin/khuluma
  do
    [[ -f "$candidate" && -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

if (( $# == 0 )); then
  notify "No files selected."
  exit 0
fi

BIN="$(resolve_bin)" || {
  if [[ -n "$EXPLICIT_BIN" ]]; then
    notify "Configured Khuluma CLI is not executable: $EXPLICIT_BIN"
  else
    notify "Khuluma not found. Install it first."
  fi
  exit 0
}

count=$#
if (( count == 1 )); then
  notify "Transcribing $(basename "$1")..."
else
  notify "Transcribing $count files..."
fi

{
  printf '\n[%s] transcribe %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$count"
} >>"$LOG" 2>/dev/null

if "$BIN" transcribe --beside --clipboard "$@" >>"$LOG" 2>&1; then
  if (( count == 1 )); then
    notify "Saved $(basename "${1%.*}").txt and copied it to the clipboard."
  else
    notify "Saved $count transcripts and copied them to the clipboard."
  fi
  exit 0
fi

reason="$(grep -E '^khuluma: ' "$LOG" 2>/dev/null | tail -1 | sed 's/^khuluma: //')"
notify "Transcription failed: ${reason:-see $LOG}"
# The notification reports the failure; a non-zero exit would also make Finder
# show a generic Automator error alert.
exit 0
