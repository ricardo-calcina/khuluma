#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Identity helpers are pure; validate inputs before any installation writes.
source "$REPO_ROOT/bin/khuluma-lib/identity.sh"
source "$REPO_ROOT/bin/khuluma-lib/migration.sh"

FORCE=0
INSTALL_SOUNDS="${KHULUMA_INSTALL_SAMPLE_SOUNDS:-1}"
REPLACE_SOUNDS="${KHULUMA_REPLACE_SOUNDS:-0}"
INSTALL_WARMUP="${KHULUMA_INSTALL_WARMUP:-1}"
usage() {
  cat <<'USAGE'
Usage: ./install.sh [--force] [--with-sounds|--no-sounds] [--replace-sounds]

Installs Khuluma's CLI into ~/.local/bin. New configuration uses ~/.config/khuluma;
models/native sources use ~/.local/share/khuluma and sounds use sounds/khuluma.
Existing configuration and vocabulary are preserved, including with --force.
Legacy installations require tools/migrate-khuluma-identity.sh before activation.

Options:
  --force           reinstall code (preserves config and vocab)
  --with-sounds     install missing bundled sample sounds
  --no-sounds       skip sample sound installation
  --replace-sounds  replace sample sounds with recoverable backups
  -h, --help        show this help
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --with-sounds) INSTALL_SOUNDS=1 ;;
    --no-sounds) INSTALL_SOUNDS=0 ;;
    --replace-sounds) REPLACE_SOUNDS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
khuluma_reject_obsolete_environment

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
absolute_path() { python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$1"; }
BIN_DIR="$(absolute_path "${KHULUMA_BIN_DIR:-$HOME/.local/bin}")"
# Only the exact released v0.10.0 forwarding shim may be retired automatically.
# Its tag peels to f8af27e95c6763b30b52da107da3120c4d96f190. Unknown commands
# belong to the user and must be inspected before this installer writes anything.
verified_legacy_shim_token() {
  python3 - "${1:-$BIN_DIR/tmux-whisper}" <<'PYSHIM'
import hashlib, os, stat, sys
path = sys.argv[1]
if not os.path.lexists(path):
    raise SystemExit(0)
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_size != 591:
    raise SystemExit(f"Refusing unknown, symlink or unowned old command before installation: {path}")
with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
    opened = os.fstat(source.fileno())
    digest = hashlib.sha256(source.read()).hexdigest()
    finished = os.fstat(source.fileno())
identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid)
if identity(info) != identity(opened) or identity(opened) != identity(finished) or finished.st_size != 591 or digest != "ab5f0067c075c177c2f56e99fe065a04662cde3636ca8f820957a9daf7e9fab6":
    raise SystemExit(f"Refusing unknown or changed old command before installation: {path}")
print(":".join(str(value) for value in identity(finished)))
PYSHIM
}
legacy_shim_token="$(verified_legacy_shim_token)"
# Pure preflight resolves explicit settings and matching receipts, and refuses
# to fork legacy data into empty canonical defaults. It creates nothing.
khuluma_identity_preflight "$BIN_DIR/khuluma"
CONFIG_DIR="$(absolute_path "$KHULUMA_CONFIG_DIR")"
CONFIG_FILE="$(absolute_path "$KHULUMA_CONFIG_FILE")"
NATIVE_PACKAGE_DIR="$(absolute_path "$KHULUMA_DAEMON_BUILD_ROOT")"
PARAKEET_MODELS_DIR="$(absolute_path "$KHULUMA_PARAKEET_MODELS_DIR")"
SOUND_DIR="$(absolute_path "$KHULUMA_SOUNDS_DIR")"
ADAPTER_SHARE_DIR="$(absolute_path "$(dirname "$BIN_DIR")/share/khuluma")"
# Refuse ambiguous/unowned existing installation roots before any writes.
python3 - "$BIN_DIR" "$CONFIG_DIR" "$(dirname "$CONFIG_FILE")" "$NATIVE_PACKAGE_DIR" "$PARAKEET_MODELS_DIR" "$SOUND_DIR" "$ADAPTER_SHARE_DIR" <<'PYGUARD'
import os, pathlib, stat, sys
for path in sys.argv[1:]:
    current = pathlib.Path("/")
    for component in pathlib.Path(path).parts[1:]:
        current = current / component
        if not os.path.lexists(current):
            break
        info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid()):
            raise SystemExit(f"Refusing symlink, non-directory or unowned install ancestor: {current}")
    if os.path.lexists(path) and os.lstat(path).st_uid != os.getuid():
        raise SystemExit(f"Refusing unowned installation root: {path}")
PYGUARD

# Directory-aware shell mv can treat a raced destination as a container. Use
# the platform's exclusive rename syscall, and validate the owned source inode.
path_token() {
  python3 - "$1" <<'PYTOKEN'
import os, sys
try:
    info = os.lstat(sys.argv[1])
    print(f"{info.st_dev}:{info.st_ino}")
except OSError:
    raise SystemExit(1)
PYTOKEN
}
exclusive_rename() {
  python3 - "$1" "$2" "${3:-}" <<'PYRENAME'
import ctypes, os, sys
source, destination, expected = sys.argv[1:]
info = os.lstat(source)
if info.st_uid != os.getuid() or (expected and expected != f"{info.st_dev}:{info.st_ino}"):
    raise SystemExit(f"Refusing changed or unowned rename source: {source}")
libc = ctypes.CDLL(None, use_errno=True)
if sys.platform == "darwin":
    operation = libc.renamex_np
    operation.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    result = operation(os.fsencode(source), os.fsencode(destination), 0x00000004) # RENAME_EXCL
elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
    operation = libc.renameat2
    operation.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    result = operation(-100, os.fsencode(source), -100, os.fsencode(destination), 1) # RENAME_NOREPLACE
else:
    raise SystemExit("Platform lacks an atomic exclusive rename; destination left unchanged")
if result != 0:
    error = ctypes.get_errno()
    raise SystemExit(f"Refusing rename {source} -> {destination}: {os.strerror(error)}")
PYRENAME
}

# Stage every payload before any existing code is moved. Transaction roots are
# kept on each destination volume so switching an entry is a rename. Successful
# backups remain available; a failed transaction restores entries in reverse.
transaction_roots=()
transaction_targets=()
transaction_tokens=()
rollback() {
  local status="$1" i transaction target current_token
  trap - ERR INT TERM
  for (( i=${#transaction_roots[@]}-1; i>=0; i-- )); do
    transaction="${transaction_roots[$i]}"
    target="${transaction_targets[$i]}"
    current_token="$(path_token "$target" 2>/dev/null || true)"
    if [[ -n "${transaction_tokens[$i]}" && ! -e "$transaction/replacement" && "$current_token" == "${transaction_tokens[$i]}" ]]; then
      exclusive_rename "$target" "$transaction/failed" "$current_token" || { echo "Restore requires attention: $transaction -> $target" >&2; continue; }
    fi
    if [[ -e "$transaction/previous" ]]; then
      exclusive_rename "$transaction/previous" "$target" || echo "Restore requires attention; destination preserved: $transaction/previous -> $target" >&2
    fi
  done
  echo "Installation failed; staging retained: ${stage:-not created}" >&2
  for transaction in "${transaction_roots[@]}"; do echo "Recovery workspace: $transaction" >&2; done
  exit "$status"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

replace_item() {
  local source="$1" target="$2" parent transaction previous_token="" replacement_token
  [[ ! -L "$target" ]] || { echo "Refusing symlink destination: $target" >&2; return 2; }
  parent="$(dirname "$target")"
  mkdir -p "$parent"
  transaction="$(mktemp -d "$parent/.khuluma-install.XXXXXX")"
  chmod 700 "$transaction"
  cp -R "$source" "$transaction/replacement"
  if [[ -e "$target" ]]; then previous_token="$(path_token "$target")"; fi
  replacement_token="$(path_token "$transaction/replacement")"
  transaction_roots+=("$transaction")
  transaction_targets+=("$target")
  transaction_tokens+=("$replacement_token")
  if [[ -n "$previous_token" ]]; then exclusive_rename "$target" "$transaction/previous" "$previous_token"; fi
  exclusive_rename "$transaction/replacement" "$target" "$replacement_token"
}

retire_legacy_shim() {
  local target="$BIN_DIR/tmux-whisper" current_token inode_token retired_token transaction
  current_token="$(verified_legacy_shim_token)" || return
  [[ "$current_token" == "$legacy_shim_token" ]] || { echo "Old command changed during installation: $target" >&2; return 2; }
  [[ -n "$current_token" ]] || return 0
  transaction="$(mktemp -d "$BIN_DIR/.khuluma-install.XXXXXX")"
  chmod 700 "$transaction"
  transaction_roots+=("$transaction")
  transaction_targets+=("$target")
  transaction_tokens+=("")
  inode_token="${current_token%:*}"
  inode_token="${inode_token%:*}"
  exclusive_rename "$target" "$transaction/previous" "$inode_token"
  # A writer may change this inode without replacing the directory entry.
  # Recheck the retained object; failure restores those changed bytes/mode via
  # the same exclusive rollback instead of silently retiring an unknown file.
  retired_token="$(verified_legacy_shim_token "$transaction/previous")" || return
  [[ "$retired_token" == "$current_token" ]] || { echo "Old command changed during retirement: $target" >&2; return 2; }
}

stage="$(mktemp -d "${KHULUMA_TMPDIR:-${TMPDIR:-/tmp}}/khuluma-install.XXXXXX")"
chmod 700 "$stage"
mkdir -p "$stage/bin" "$stage/native" "$stage/integrations/finder" "$stage/tools"
for entry in khuluma khuluma-lib.sh; do
  install -m 0755 "$REPO_ROOT/bin/$entry" "$stage/bin/$entry"
done
cp -R "$REPO_ROOT/bin/khuluma-lib" "$stage/bin/khuluma-lib"
for entry in Package.swift Package.resolved; do
  install -m 0644 "$REPO_ROOT/native/$entry" "$stage/native/$entry"
done
cp -R "$REPO_ROOT/native/Sources" "$REPO_ROOT/native/Tests" "$stage/native/"
for entry in migrate-khuluma-identity.sh khuluma_identity_migration.py; do
  install -m 0755 "$REPO_ROOT/tools/$entry" "$stage/tools/$entry"
done
install -m 0755 "$REPO_ROOT/integrations/finder/khuluma-transcribe.sh" "$stage/integrations/finder/khuluma-transcribe.sh"
# config defaults is a nonmutating probe; do not launch a daemon in staging.
if [[ ! -e "$CONFIG_FILE" ]]; then
  "$stage/bin/khuluma" config defaults > "$stage/config.toml"
fi
retire_legacy_shim
for entry in khuluma khuluma-lib.sh khuluma-lib; do
  replace_item "$stage/bin/$entry" "$BIN_DIR/$entry"
done
for entry in Package.swift Package.resolved Sources Tests; do
  replace_item "$stage/native/$entry" "$NATIVE_PACKAGE_DIR/$entry"
done
replace_item "$stage/integrations" "$ADAPTER_SHARE_DIR/integrations"
replace_item "$stage/tools" "$ADAPTER_SHARE_DIR/tools"
mkdir -p "$CONFIG_DIR" "$PARAKEET_MODELS_DIR"
if [[ ! -e "$CONFIG_FILE" ]]; then replace_item "$stage/config.toml" "$CONFIG_FILE"; fi
# This is the pre-existing modes-to-global migration within the explicitly
# selected profile, not an old-to-new identity/data cutover. Preserve mode rules
# before seeding factory vocabulary; its own archives retain original files.
if [[ -d "$CONFIG_DIR/modes" || -f "$CONFIG_DIR/current-mode" ]]; then
  KHULUMA_CONFIG_DIR="$CONFIG_DIR" KHULUMA_CONFIG_FILE="$CONFIG_FILE" \
    "$BIN_DIR/khuluma" migrate-modes
fi
if [[ ! -e "$CONFIG_DIR/vocab" ]]; then replace_item "$REPO_ROOT/config/vocab" "$CONFIG_DIR/vocab"; fi

if [[ "$INSTALL_SOUNDS" == 1 && -d "$REPO_ROOT/assets/sounds/khuluma" ]]; then
  mkdir -p "$SOUND_DIR"
  for wav in "$REPO_ROOT"/assets/sounds/khuluma/*.wav; do
    [[ -f "$wav" ]] || continue
    target="$SOUND_DIR/$(basename "$wav")"
    if [[ "$REPLACE_SOUNDS" == 1 || ! -e "$target" ]]; then replace_item "$wav" "$target"; fi
  done
fi

installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
git_ref="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
# shlex-compatible quoted data, never evaluated or sourced by readers.
python3 - "$stage/install-receipt.env" "$installed_at" "${KHULUMA_INSTALL_SOURCE:-local}" \
  "${KHULUMA_INSTALL_ARCHIVE_URL:-}" "$REPO_ROOT" "$git_ref" "$git_commit" \
  "$BIN_DIR/khuluma" "$CONFIG_DIR" "$CONFIG_FILE" "$NATIVE_PACKAGE_DIR" "$PARAKEET_MODELS_DIR" \
  "$SOUND_DIR" "$INSTALL_SOUNDS" <<'PY'
import os, shlex, sys
path, *values = sys.argv[1:]
keys = ("installed_at", "install_source", "install_archive_url", "repo_root", "repo_git_ref", "repo_git_commit", "bin_path", "config_dir", "config_file", "native_dir", "models_dir", "sounds_dir", "sounds_installed")
# Actual placement persists even when this run skips copying optional sounds.
# sounds_installed records that choice; never erase custom routing.
with open(path, "x", encoding="utf-8") as handle:
    for key, value in zip(keys, values):
        if any(c in value for c in "\r\n\x00"):
            raise SystemExit("unsupported control character in install receipt")
        handle.write(f"{key}={shlex.quote(value)}\n")
os.chmod(path, 0o600)
PY
replace_item "$stage/install-receipt.env" "$CONFIG_DIR/install-receipt.env"
# This routing copy lets a later GUI/CLI find custom config roots after the
# one-shot installer environment is gone. Readers require matching bin_path.
replace_item "$stage/install-receipt.env" "$ADAPTER_SHARE_DIR/install-receipt.env"
trap - ERR INT TERM

echo "Installed khuluma to: $BIN_DIR/khuluma"
echo "Config path: $CONFIG_DIR"
echo "Native backend source: $NATIVE_PACKAGE_DIR"
echo "Parakeet models dir: $PARAKEET_MODELS_DIR"
if [[ "$INSTALL_SOUNDS" == 1 ]]; then echo "Sample sounds: $SOUND_DIR"; else echo "Sample sounds: skipped"; fi
echo "Install receipt: $CONFIG_DIR/install-receipt.env"
echo "Installation staging retained: $stage"
for transaction in "${transaction_roots[@]}"; do
  [[ ! -e "$transaction/previous" ]] || echo "Recoverable previous entry: $transaction/previous"
done
# Explicit model/daemon/sound settings survive child launch.
if [[ "$INSTALL_WARMUP" == 1 ]]; then
  KHULUMA_CONFIG_DIR="$CONFIG_DIR" KHULUMA_CONFIG_FILE="$CONFIG_FILE" \
    "$BIN_DIR/khuluma" warmup --best-effort --refresh-in-background || true
else
  echo "Warmup: skipped (KHULUMA_INSTALL_WARMUP=0)"
fi
echo "Run: khuluma doctor"
