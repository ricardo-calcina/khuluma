#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME/home"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME"

assert_file() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "Missing file: $path" >&2
    exit 1
  }
}

assert_exec() {
  local path="$1"
  [[ -x "$path" ]] || {
    echo "Missing executable bit: $path" >&2
    exit 1
  }
}

install_output="$("$ROOT/install.sh" --with-sounds)"

install_help="$("$ROOT/install.sh" --help)"
if [[ "$install_help" != *"Installs Tmux Whisper into ~/.local/bin"* ]]; then
  echo "Expected install help to describe Tmux Whisper branding" >&2
  exit 1
fi

assert_exec "$HOME/.local/bin/tmux-whisper"
assert_exec "$HOME/.local/bin/dictate-lib.sh"
assert_file "$HOME/.local/bin/tmux-whisper-lib/history.sh"
assert_file "$HOME/.local/bin/tmux-whisper-lib/diagnostics.sh"
assert_file "$HOME/.config/dictate/config.toml"
assert_file "$HOME/.config/dictate/vocab"
assert_file "$HOME/.config/dictate/install-receipt.env"
assert_file "$HOME/.local/share/sounds/dictate/start.wav"
assert_file "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Package.swift"
assert_file "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Package.resolved"
assert_file "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Tests/TmuxWhisperKitTests/ProtocolTests.swift"
assert_file "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Sources/TmuxWhisperKit/ASREngine.swift"
assert_exec "$HOME/.local/share/tmux-whisper/integrations/finder/tmux-whisper-transcribe.sh"
if [[ ! -d "$HOME/.local/share/tmux-whisper/models" ]]; then
  echo "Expected install to create tmux-whisper Parakeet models dir" >&2
  exit 1
fi
if ! rg -q '^\[swift_parakeet\]$' "$HOME/.config/dictate/config.toml"; then
  echo "Expected fresh install config to include swift_parakeet settings" >&2
  exit 1
fi
if ! rg -q '^[[:space:]]*paste_target = "current"$' "$HOME/.config/dictate/config.toml"; then
  echo "Expected fresh install config to include inline.paste_target" >&2
  exit 1
fi
if [[ -e "$HOME/.config/dictate/modes" || -e "$HOME/.config/dictate/current-mode" ]]; then
  echo "Expected a fresh install to have no modes/ or current-mode" >&2
  exit 1
fi
if ! rg -q '^at saw slash::@src/$' "$HOME/.config/dictate/vocab"; then
  echo "Expected the default vocab to include the old base mode's path rules" >&2
  exit 1
fi
if [[ "$install_output" != *"Warmup:"* ]]; then
  echo "Expected install to report warmup status" >&2
  exit 1
fi
if [[ "$install_output" != *"Run: tmux-whisper doctor"* ]]; then
  echo "Expected install output to point users at tmux-whisper doctor" >&2
  exit 1
fi
if [[ "$install_output" != *"Paths kept for now: config=$HOME/.config/dictate sounds=$HOME/.local/share/sounds/dictate"* ]]; then
  echo "Expected install output to clarify the intentional dictate config/sound paths" >&2
  exit 1
fi
if [[ "$install_output" != *"Install receipt: $HOME/.config/dictate/install-receipt.env"* ]]; then
  echo "Expected install output to report the install receipt path" >&2
  exit 1
fi
if ! rg -q '^install_source=local$' "$HOME/.config/dictate/install-receipt.env"; then
  echo "Expected local install receipt source" >&2
  exit 1
fi
if ! rg -q "^bin_path=$HOME/\\.local/bin/tmux-whisper$" "$HOME/.config/dictate/install-receipt.env"; then
  echo "Expected install receipt to record installed binary path" >&2
  exit 1
fi

# Non-force install should preserve user-edited config.
printf '%s\n' '# user-edit' >> "$HOME/.config/dictate/config.toml"
"$ROOT/install.sh" --with-sounds
if ! rg -q '# user-edit' "$HOME/.config/dictate/config.toml"; then
  echo "Expected user config edit to be preserved without --force" >&2
  exit 1
fi

# Force install should preserve user-edited config and vocab, and fold an
# older install's modes/*/vocab into vocab, archiving modes/ and current-mode.
CFG="$HOME/.config/dictate"
printf '%s\n' 'my word -> MyWord' >> "$CFG/vocab"
mkdir -p "$CFG/modes/code" "$CFG/modes/email"
printf '%s\n' 'Ghostty' > "$CFG/modes/code/apps"
printf '%s\n' 'tmux' > "$CFG/modes/code/flows"
printf '%s\n' 'at  saw slash::@src/' 'kuber net ease::Kubernetes' 'my word::Other' > "$CFG/modes/code/vocab"
printf '%s\n' 'kind regards -> Kind regards,' > "$CFG/modes/email/vocab"
printf '%s\n' 'auto' > "$CFG/current-mode"
migrate_output="$("$ROOT/install.sh" --force --with-sounds)"
if ! rg -q '# user-edit' "$CFG/config.toml"; then
  echo "Expected --force to preserve config.toml" >&2
  exit 1
fi
if [[ -e "$CFG/modes" || -e "$CFG/current-mode" ]]; then
  echo "Expected install to move modes/ and current-mode out of the config dir" >&2
  exit 1
fi
archives=("$CFG"/modes-archive/*-modes-removed)
if [[ "${#archives[@]}" -ne 1 || ! -f "${archives[0]}/modes/code/apps" || ! -f "${archives[0]}/current-mode" ]]; then
  echo "Expected one archive holding modes/ and current-mode: ${archives[*]}" >&2
  exit 1
fi
if ! rg -q '^my word -> MyWord$' "${archives[0]}/vocab.before-migrate"; then
  echo "Expected the archive to keep the vocab as it was before the merge" >&2
  exit 1
fi
for rule in 'my word -> MyWord' 'kuber net ease::Kubernetes' 'kind regards -> Kind regards,'; do
  if [[ "$(rg -cxF "$rule" "$CFG/vocab")" != "1" ]]; then
    echo "Expected vocab to hold '$rule' once" >&2
    exit 1
  fi
done
if rg -q 'at  saw slash|my word::Other' "$CFG/vocab"; then
  echo "Expected duplicate and conflicting mode rules to be skipped" >&2
  exit 1
fi
if [[ "$migrate_output" != *"Added 1 rule(s) from modes/code/vocab (1 already in vocab)"* || "$migrate_output" != *"skipped, vocab already corrects this differently: my word::Other"* ]]; then
  echo "Expected install to report the merge: $migrate_output" >&2
  exit 1
fi
vocab_before="$(cat "$CFG/vocab")"
"$ROOT/install.sh" --force --with-sounds >/dev/null
archives=("$CFG"/modes-archive/*-modes-removed)
if [[ "${#archives[@]}" -ne 1 || "$(cat "$CFG/vocab")" != "$vocab_before" ]]; then
  echo "Expected a second install to leave vocab and the archive alone" >&2
  exit 1
fi

# Force install should replace native sources cleanly so removed Swift files do not linger.
mkdir -p "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Sources/tmux-whisperd"
printf '%s\n' 'stale native file' > "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Sources/tmux-whisperd/main.swift"
"$ROOT/install.sh" --force --with-sounds
if [[ -e "$HOME/.local/share/tmux-whisper/native/tmux-whisperd/Sources/tmux-whisperd/main.swift" ]]; then
  echo "Expected --force to remove stale native source files" >&2
  exit 1
fi

# Force install should not overwrite existing custom sounds unless explicitly requested.
printf '%s\n' 'custom-start-sound' > "$HOME/.local/share/sounds/dictate/start.wav"
"$ROOT/install.sh" --force --with-sounds
if ! rg -q 'custom-start-sound' "$HOME/.local/share/sounds/dictate/start.wav"; then
  echo "Expected existing sounds to be preserved without --replace-sounds" >&2
  exit 1
fi

"$ROOT/install.sh" --force --with-sounds --replace-sounds
if rg -q 'custom-start-sound' "$HOME/.local/share/sounds/dictate/start.wav"; then
  echo "Expected --replace-sounds to refresh sound files" >&2
  exit 1
fi

echo "Install smoke tests passed."
