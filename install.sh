#!/usr/bin/env bash
set -euo pipefail

FORCE=0
INSTALL_SOUNDS="${DICTATE_INSTALL_SAMPLE_SOUNDS:-1}"
REPLACE_SOUNDS="${DICTATE_REPLACE_SOUNDS:-0}"
INSTALL_WARMUP="${DICTATE_INSTALL_WARMUP:-1}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--force] [--with-sounds|--no-sounds] [--replace-sounds]

Installs Tmux Whisper into ~/.local/bin while intentionally keeping config and sample-sound paths under ~/.config/dictate and ~/.local/share/sounds/dictate for now.

Options:
  --force        reinstall binaries/integrations (preserves existing config and vocab)
  --with-sounds  install bundled sample sounds into ~/.local/share/sounds/dictate
  --no-sounds    skip sample sound installation
  --replace-sounds  overwrite existing sound files with bundled samples
  -h, --help     show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      ;;
    --with-sounds)
      INSTALL_SOUNDS=1
      ;;
    --no-sounds)
      INSTALL_SOUNDS=0
      ;;
    --replace-sounds)
      REPLACE_SOUNDS=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${DICTATE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${DICTATE_CONFIG_DIR:-$HOME/.config/dictate}"
SOUND_DIR="${DICTATE_SOUNDS_DIR:-$HOME/.local/share/sounds/dictate}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
NATIVE_DIR="${DICTATE_NATIVE_DIR:-$XDG_DATA_HOME/tmux-whisper/native}"
PARAKEET_MODELS_DIR="${DICTATE_PARAKEET_MODELS_DIR:-$XDG_DATA_HOME/tmux-whisper/models}"

copy_if_missing() {
  local src="$1"
  local dst="$2"
  [[ -e "$dst" ]] || cp -R "$src" "$dst"
}

write_install_receipt() {
  local receipt="$CONFIG_DIR/install-receipt.env"
  local installed_at source archive_url git_ref git_commit
  installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  source="${DICTATE_INSTALL_SOURCE:-local}"
  archive_url="${DICTATE_INSTALL_ARCHIVE_URL:-}"
  git_ref=""
  git_commit=""
  if command -v git >/dev/null 2>&1 && [[ -d "$REPO_ROOT/.git" ]]; then
    git_ref="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  fi

  {
    printf 'installed_at=%q\n' "$installed_at"
    printf 'install_source=%q\n' "$source"
    printf 'install_archive_url=%q\n' "$archive_url"
    printf 'repo_root=%q\n' "$REPO_ROOT"
    printf 'repo_git_ref=%q\n' "$git_ref"
    printf 'repo_git_commit=%q\n' "$git_commit"
    printf 'bin_path=%q\n' "$BIN_DIR/tmux-whisper"
    printf 'config_dir=%q\n' "$CONFIG_DIR"
    printf 'native_dir=%q\n' "$NATIVE_DIR/tmux-whisperd"
    if [[ "$INSTALL_SOUNDS" == "1" ]]; then
      printf 'sounds_dir=%q\n' "$SOUND_DIR"
    else
      printf 'sounds_dir=%q\n' "skipped"
    fi
  } > "$receipt"
}

run_install_warmup() {
  if [[ "$INSTALL_WARMUP" != "1" ]]; then
    echo "Warmup: skipped (DICTATE_INSTALL_WARMUP=0)"
    return 0
  fi

  env \
    -u DICTATE_SWIFT_PARAKEET_MODEL_PATH \
    -u DICTATE_SWIFT_PARAKEET_MODEL_VERSION \
    -u DICTATE_SWIFT_PARAKEET_SOCKET_PATH \
    -u DICTATE_TMUX_WHISPERD_BIN \
    -u DICTATE_TMUX_WHISPERD_ROOT \
    DICTATE_CONFIG_DIR="$CONFIG_DIR" \
    DICTATE_CONFIG_FILE="$CONFIG_DIR/config.toml" \
    XDG_DATA_HOME="$XDG_DATA_HOME" \
    "$BIN_DIR/tmux-whisper" warmup --best-effort --refresh-in-background || true
}

install_default_config_files() {
  if [[ ! -e "$CONFIG_DIR/config.toml" ]]; then
    mkdir -p "$CONFIG_DIR"
    "$BIN_DIR/tmux-whisper" config defaults > "$CONFIG_DIR/config.toml"
  fi
  copy_if_missing "$REPO_ROOT/config/vocab" "$CONFIG_DIR/vocab"
}

# Modes were removed in v0.11: fold an older install's modes/*/vocab into
# vocab and archive modes/ and current-mode (never deleted). A no-op once done.
migrate_legacy_modes() {
  [[ -d "$CONFIG_DIR/modes" || -f "$CONFIG_DIR/current-mode" ]] || return 0
  echo "Modes were removed: folding their vocab into $CONFIG_DIR/vocab"
  DICTATE_CONFIG_DIR="$CONFIG_DIR" DICTATE_CONFIG_FILE="$CONFIG_DIR/config.toml" \
    "$BIN_DIR/tmux-whisper" migrate-modes || echo "warning: mode migration failed; run: tmux-whisper migrate-modes" >&2
}

mkdir -p "$BIN_DIR" "$CONFIG_DIR"
mkdir -p "$NATIVE_DIR/tmux-whisperd"
mkdir -p "$PARAKEET_MODELS_DIR"

install -m 0755 "$REPO_ROOT/bin/tmux-whisper" "$BIN_DIR/tmux-whisper"
install -m 0755 "$REPO_ROOT/bin/dictate-lib.sh" "$BIN_DIR/dictate-lib.sh"
rm -rf "$BIN_DIR/tmux-whisper-lib"
mkdir -p "$BIN_DIR/tmux-whisper-lib"
cp -R "$REPO_ROOT/bin/tmux-whisper-lib/." "$BIN_DIR/tmux-whisper-lib/"
install -m 0644 "$REPO_ROOT/tmux-whisperd/Package.swift" "$NATIVE_DIR/tmux-whisperd/Package.swift"
# The pinned dependency graph keeps installed builds identical to CI's.
install -m 0644 "$REPO_ROOT/tmux-whisperd/Package.resolved" "$NATIVE_DIR/tmux-whisperd/Package.resolved"
rm -rf "$NATIVE_DIR/tmux-whisperd/Sources" "$NATIVE_DIR/tmux-whisperd/Tests"
mkdir -p "$NATIVE_DIR/tmux-whisperd/Sources"
cp -R "$REPO_ROOT/tmux-whisperd/Sources/." "$NATIVE_DIR/tmux-whisperd/Sources/"
# Package.swift declares the test target, so its directory must exist to build.
cp -R "$REPO_ROOT/tmux-whisperd/Tests" "$NATIVE_DIR/tmux-whisperd/Tests"

# Preserve user config and vocab edits on every install, including --force.
# `--force` remains a convenience for reinstalling binaries/integrations.
install_default_config_files
migrate_legacy_modes

# The Finder Quick Action handler lives beside the binary (mirrors Homebrew's
# pkgshare), so it keeps working after bootstrap deletes its extracted tree.
ADAPTER_SHARE_DIR="$(dirname "$BIN_DIR")/share/tmux-whisper"
rm -rf "$ADAPTER_SHARE_DIR/integrations"
mkdir -p "$ADAPTER_SHARE_DIR/integrations/finder"
install -m 0755 "$REPO_ROOT/integrations/finder/tmux-whisper-transcribe.sh" "$ADAPTER_SHARE_DIR/integrations/finder/tmux-whisper-transcribe.sh"

if [[ "$INSTALL_SOUNDS" == "1" && -d "$REPO_ROOT/assets/sounds/dictate" ]]; then
  mkdir -p "$SOUND_DIR"
  for wav in "$REPO_ROOT"/assets/sounds/dictate/*.wav; do
    [[ -f "$wav" ]] || continue
    target="$SOUND_DIR/$(basename "$wav")"
    if [[ "$REPLACE_SOUNDS" -eq 1 || ! -f "$target" ]]; then
      install -m 0644 "$wav" "$target"
    fi
  done
fi

write_install_receipt

echo "Installed tmux-whisper to: $BIN_DIR/tmux-whisper"
echo "Config path: $CONFIG_DIR"
echo "Native backend source: $NATIVE_DIR/tmux-whisperd"
echo "Parakeet models dir: $PARAKEET_MODELS_DIR"
if [[ "$INSTALL_SOUNDS" == "1" ]]; then
  echo "Sample sounds: $SOUND_DIR"
else
  echo "Sample sounds: skipped"
fi
echo "Paths kept for now: config=$CONFIG_DIR sounds=$SOUND_DIR"
echo "Install receipt: $CONFIG_DIR/install-receipt.env"
run_install_warmup
echo "Run: tmux-whisper doctor"
