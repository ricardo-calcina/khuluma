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
assert_file "$HOME/.config/dictate/current-mode"
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
if ! rg -q '^[[:space:]]*budget_long_words_threshold = 120$' "$HOME/.config/dictate/config.toml"; then
  echo "Expected fresh install config to include budget_long_words_threshold" >&2
  exit 1
fi
if [[ "$(tr -d '[:space:]' < "$HOME/.config/dictate/current-mode")" != "auto" ]]; then
  echo "Expected fresh install current-mode to default to auto" >&2
  exit 1
fi
if [[ "$install_output" != *"Warmup:"* ]]; then
  echo "Expected install to report warmup status" >&2
  exit 1
fi
if [[ "$install_output" != *"Run: tmux-whisper debug"* ]]; then
  echo "Expected install output to point users at tmux-whisper debug" >&2
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

# Force install should preserve user-edited config and local mode customizations.
printf '%s\n' "my custom code prompt" > "$HOME/.config/dictate/modes/code/prompt"
rm -rf "$HOME/.config/dictate/modes/email"
"$ROOT/install.sh" --force --with-sounds
if ! rg -q '# user-edit' "$HOME/.config/dictate/config.toml"; then
  echo "Expected --force to preserve config.toml" >&2
  exit 1
fi
if ! rg -q 'my custom code prompt' "$HOME/.config/dictate/modes/code/prompt"; then
  echo "Expected --force to preserve local mode prompt" >&2
  exit 1
fi
if [[ -e "$HOME/.config/dictate/modes/email" ]]; then
  echo "Expected --force to preserve local mode set (email should stay removed)" >&2
  exit 1
fi

# Legacy local mode folder should migrate from short -> code without clobbering contents.
mv "$HOME/.config/dictate/modes/code" "$HOME/.config/dictate/modes/short"
printf '%s\n' "short" > "$HOME/.config/dictate/current-mode"
printf '%s\n' "legacy code prompt" > "$HOME/.config/dictate/modes/short/prompt"
tmp_cfg="$(mktemp)"
awk '
  BEGIN { in_tmux=0 }
  /^\[/ { in_tmux = ($0 ~ /^\[tmux\][[:space:]]*$/) }
  {
    line = $0
    if (in_tmux && line ~ /^[[:space:]]*mode[[:space:]]*=/) {
      sub(/"code"/, "\"short\"", line)
    }
    print line
  }
' "$HOME/.config/dictate/config.toml" > "$tmp_cfg"
mv "$tmp_cfg" "$HOME/.config/dictate/config.toml"
"$ROOT/install.sh" --force --with-sounds
if [[ -d "$HOME/.config/dictate/modes/short" ]]; then
  echo "Expected legacy short mode folder to be migrated to code" >&2
  exit 1
fi
if [[ ! -f "$HOME/.config/dictate/modes/code/prompt" ]]; then
  echo "Expected code mode folder after migration" >&2
  exit 1
fi
if ! rg -q 'legacy code prompt' "$HOME/.config/dictate/modes/code/prompt"; then
  echo "Expected migrated code mode prompt to preserve local content" >&2
  exit 1
fi
if [[ "$(tr -d '[:space:]' < "$HOME/.config/dictate/current-mode")" != "code" ]]; then
  echo "Expected current-mode short to migrate to code" >&2
  exit 1
fi
if ! rg -q '^[[:space:]]*mode = "code"$' "$HOME/.config/dictate/config.toml"; then
  echo "Expected [tmux] mode short to migrate to code" >&2
  exit 1
fi

# Legacy local base/fast mode should migrate from fast -> base without clobbering contents.
mv "$HOME/.config/dictate/modes/base" "$HOME/.config/dictate/modes/fast"
printf '%s\n' "fast" > "$HOME/.config/dictate/current-mode"
printf '%s\n' "legacy base prompt" > "$HOME/.config/dictate/modes/fast/prompt"
"$ROOT/install.sh" --force --with-sounds
if [[ -d "$HOME/.config/dictate/modes/fast" ]]; then
  echo "Expected legacy fast mode folder to be migrated to base" >&2
  exit 1
fi
if [[ ! -f "$HOME/.config/dictate/modes/base/prompt" ]]; then
  echo "Expected base mode folder after migration" >&2
  exit 1
fi
if ! rg -q 'legacy base prompt' "$HOME/.config/dictate/modes/base/prompt"; then
  echo "Expected migrated base mode prompt to preserve local content" >&2
  exit 1
fi
if [[ "$(tr -d '[:space:]' < "$HOME/.config/dictate/current-mode")" != "base" ]]; then
  echo "Expected current-mode fast to migrate to base" >&2
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
