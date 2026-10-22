#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(cd "$(mktemp -d)" && pwd -P)"
KHULUMA_TEST_FIXTURE_ROOT="$TMP_HOME"
source "$ROOT/tests/fixture_helpers.sh"
trap report_fixture_root EXIT

export HOME="$TMP_HOME/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export KHULUMA_INSTALL_WARMUP=0
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
if [[ "$install_help" != *"Installs Khuluma's CLI into ~/.local/bin"* ]]; then
  echo "Expected install help to describe Khuluma branding" >&2
  exit 1
fi

assert_exec "$HOME/.local/bin/khuluma"
assert_exec "$HOME/.local/bin/khuluma-lib.sh"
assert_file "$HOME/.local/bin/khuluma-lib/history.sh"
assert_file "$HOME/.local/bin/khuluma-lib/diagnostics.sh"
assert_file "$HOME/.config/khuluma/config.toml"
assert_file "$HOME/.config/khuluma/vocab"
assert_file "$HOME/.config/khuluma/install-receipt.env"
assert_file "$HOME/.local/share/sounds/khuluma/start.wav"
assert_file "$HOME/.local/share/khuluma/native/khulumad/Package.swift"
assert_file "$HOME/.local/share/khuluma/native/khulumad/Package.resolved"
assert_file "$HOME/.local/share/khuluma/native/khulumad/Tests/KhulumaDaemonKitTests/ProtocolTests.swift"
assert_file "$HOME/.local/share/khuluma/native/khulumad/Sources/KhulumaDaemonKit/ASREngine.swift"
assert_exec "$HOME/.local/share/khuluma/integrations/finder/khuluma-transcribe.sh"
if [[ ! -d "$HOME/.local/share/khuluma/models" ]]; then
  echo "Expected install to create khuluma Parakeet models dir" >&2
  exit 1
fi
if ! rg -q '^\[swift_parakeet\]$' "$HOME/.config/khuluma/config.toml"; then
  echo "Expected fresh install config to include swift_parakeet settings" >&2
  exit 1
fi
if ! rg -q '^[[:space:]]*paste_target = "current"$' "$HOME/.config/khuluma/config.toml"; then
  echo "Expected fresh install config to include inline.paste_target" >&2
  exit 1
fi
if [[ -e "$HOME/.config/khuluma/modes" || -e "$HOME/.config/khuluma/current-mode" ]]; then
  echo "Expected a fresh install to have no modes/ or current-mode" >&2
  exit 1
fi
if ! rg -q '^at saw slash::@src/$' "$HOME/.config/khuluma/vocab"; then
  echo "Expected the default vocab to include the old base mode's path rules" >&2
  exit 1
fi
if [[ "$install_output" != *"Warmup:"* ]]; then
  echo "Expected install to report warmup status" >&2
  exit 1
fi
if [[ "$install_output" != *"Run: khuluma doctor"* ]]; then
  echo "Expected install output to point users at khuluma doctor" >&2
  exit 1
fi
if [[ "$install_output" != *"Config path: $HOME/.config/khuluma"* ]]; then
  echo "Expected install output to clarify the canonical Khuluma config/sound paths" >&2
  exit 1
fi
if [[ "$install_output" != *"Install receipt: $HOME/.config/khuluma/install-receipt.env"* ]]; then
  echo "Expected install output to report the install receipt path" >&2
  exit 1
fi
if ! rg -q '^install_source=local$' "$HOME/.config/khuluma/install-receipt.env"; then
  echo "Expected local install receipt source" >&2
  exit 1
fi
if ! rg -q "^bin_path=$HOME/\\.local/bin/khuluma$" "$HOME/.config/khuluma/install-receipt.env"; then
  echo "Expected install receipt to record installed binary path" >&2
  exit 1
fi

# Non-force install should preserve user-edited config.
printf '%s\n' '# user-edit' >> "$HOME/.config/khuluma/config.toml"
"$ROOT/install.sh" --with-sounds
if ! rg -q '# user-edit' "$HOME/.config/khuluma/config.toml"; then
  echo "Expected user config edit to be preserved without --force" >&2
  exit 1
fi

# Force install should preserve user-edited config and vocab, and fold an
# older install's modes/*/vocab into vocab, archiving modes/ and current-mode.
CFG="$HOME/.config/khuluma"
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

# With no vocab yet, the old mode rules win over the bundled defaults:
# migration runs before the default vocab is seeded.
mv "$CFG/vocab" "$HOME/vocab.saved"
mkdir -p "$CFG/modes/code"
printf '%s\n' 'at saw slash::@mine/' > "$CFG/modes/code/vocab"
"$ROOT/install.sh" --force --with-sounds >/dev/null
if ! rg -qxF 'at saw slash::@mine/' "$CFG/vocab" || rg -qF '@src/' "$CFG/vocab"; then
  echo "Expected the mode rule, not the bundled default, in a vocab created by migration" >&2
  exit 1
fi

migrate() {
  KHULUMA_CONFIG_DIR="$CFG" KHULUMA_CONFIG_FILE="$CFG/config.toml" "$HOME/.local/bin/khuluma" migrate-modes "$@"
}

# A symlinked vocab is written through, so the link keeps working; a rule is
# split on LF only, as the corrector reads it (U+2028 stays inside the rule).
mv "$HOME/vocab.saved" "$HOME/vocab.real"
preserve_fixture "$CFG/vocab"
ln -s "$HOME/vocab.real" "$CFG/vocab"
mkdir -p "$CFG/modes/code"
printf 'hello\xe2\x80\xa8world::HelloWorld\n' > "$CFG/modes/code/vocab"
migrate >/dev/null
rule_2028="$(printf 'hello\xe2\x80\xa8world::HelloWorld')"
if [[ ! -L "$CFG/vocab" || "$(rg -c 'HelloWorld' "$HOME/vocab.real")" != "1" ]] || ! rg -qxF "$rule_2028" "$HOME/vocab.real"; then
  echo "Expected migration to write through the vocab symlink and keep the rule whole" >&2
  exit 1
fi

# Invalid UTF-8 or a symlinked modes/ stops the migration before any change.
mkdir -p "$CFG/modes/code"
printf 'caf\xe9::Cafe\n' > "$CFG/modes/code/vocab"
vocab_before="$(cat "$CFG/vocab")"
archive_count="$(find "$CFG/modes-archive" -mindepth 1 -maxdepth 1 | wc -l)"
if migrate >/dev/null 2>&1; then
  echo "Expected migration to refuse a mode vocab that isn't UTF-8" >&2
  exit 1
fi
preserve_fixture "$CFG/modes"
mkdir -p "$HOME/profiles/code"
printf '%s\n' 'foo::Bar' > "$HOME/profiles/code/vocab"
ln -s "$HOME/profiles" "$CFG/modes"
if migrate >/dev/null 2>&1; then
  echo "Expected migration to refuse a symlinked modes/" >&2
  exit 1
fi
if [[ ! -L "$CFG/modes" || "$(cat "$CFG/vocab")" != "$vocab_before" || "$(find "$CFG/modes-archive" -mindepth 1 -maxdepth 1 | wc -l)" != "$archive_count" ]]; then
  echo "Expected a refused migration to change nothing" >&2
  exit 1
fi
preserve_fixture "$CFG/modes"
mkdir -p "$CFG/modes/base"
printf '%s\n' 'foo::Bar' > "$CFG/modes/base/vocab"
mv "$CFG/vocab" "$HOME/vocab.link-saved"
ln -s "$CFG/modes/base/vocab" "$CFG/vocab"
if migrate >/dev/null 2>&1 || [[ ! -d "$CFG/modes" ]]; then
  echo "Expected migration to refuse a vocab linked into modes/" >&2
  exit 1
fi
preserve_fixture "$CFG/vocab" "$CFG/modes"
mv "$HOME/vocab.link-saved" "$CFG/vocab"

# Force install should replace native sources cleanly so removed Swift files do not linger.
mkdir -p "$HOME/.local/share/khuluma/native/khulumad/Sources/khulumad"
printf '%s\n' 'stale native file' > "$HOME/.local/share/khuluma/native/khulumad/Sources/khulumad/main.swift"
"$ROOT/install.sh" --force --with-sounds
if [[ -e "$HOME/.local/share/khuluma/native/khulumad/Sources/khulumad/main.swift" ]]; then
  echo "Expected --force to remove stale native source files" >&2
  exit 1
fi

# Force install should not overwrite existing custom sounds unless explicitly requested.
printf '%s\n' 'custom-start-sound' > "$HOME/.local/share/sounds/khuluma/start.wav"
"$ROOT/install.sh" --force --with-sounds
if ! rg -q 'custom-start-sound' "$HOME/.local/share/sounds/khuluma/start.wav"; then
  echo "Expected existing sounds to be preserved without --replace-sounds" >&2
  exit 1
fi

"$ROOT/install.sh" --force --with-sounds --replace-sounds
if rg -q 'custom-start-sound' "$HOME/.local/share/sounds/khuluma/start.wav"; then
  echo "Expected --replace-sounds to refresh sound files" >&2
  exit 1
fi

echo "Install smoke tests passed."
