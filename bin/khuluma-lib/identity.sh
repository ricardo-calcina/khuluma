#!/usr/bin/env bash
# Pure identity helpers. Sourcing this file never reads a profile or writes files.
KHULUMA_IDENTITY_API=1

khuluma_reject_obsolete_environment() {
  local variable
  for variable in "${!DICTATE_@}" LOWKEY_KEYCHAIN LOWKEY_SIGNING_IDENTITY; do
    if declare -p "$variable" >/dev/null 2>&1; then
      printf 'khuluma: obsolete environment input %s; remove it and use supported KHULUMA_* settings\n' "$variable" >&2
      return 2
    fi
  done
}

# Never evaluate a receipt as shell code. Only this fixed allowlist is read.
khuluma_receipt_value() {
  local key="${1:-}" receipt="${2:-}" binary="${3:-}"
  [[ -n "$key" && -f "$receipt" && ! -L "$receipt" ]] || return 0
  python3 - "$key" "$receipt" "$binary" <<'PY'
import ast, os, shlex, stat, sys
key, receipt, binary = sys.argv[1:]
allowed = {'installed_at', 'install_source', 'install_archive_url', 'repo_root',
           'repo_git_ref', 'repo_git_commit', 'bin_path', 'config_dir', 'config_file', 'native_dir',
           'models_dir', 'sounds_dir', 'sounds_installed'}
if key not in allowed:
    raise SystemExit(0)
try:
    info = os.lstat(receipt)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('untrusted receipt')
    parent = os.stat(os.path.dirname(os.path.abspath(receipt)))
    if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        raise ValueError('untrusted receipt directory')
    values = {}
    with open(receipt, encoding='utf-8') as stream:
        for line in stream:
            name, separator, raw = line.rstrip('\n').partition('=')
            if separator and name in allowed:
                if raw.startswith("$'") and raw.endswith("'"):
                    # Bash printf %q uses ANSI-C quoting for UTF-8 bytes in C
                    # locales. Literal parsing decodes escapes without a shell.
                    value = ast.literal_eval(raw[1:])
                    if not isinstance(value, str):
                        raise ValueError('invalid receipt scalar')
                    try:
                        value = value.encode('latin1').decode('utf-8')
                    except UnicodeEncodeError:
                        pass
                    words = [value]
                else:
                    words = shlex.split(raw, posix=True)
                if len(words) == 1 and not any(c in words[0] for c in '\r\n\0'):
                    values[name] = words[0]
    if binary and (not values.get('bin_path') or
                   os.path.realpath(values['bin_path']) != os.path.realpath(binary)):
        raise ValueError('receipt is for another binary')
    value = values.get(key, '')
    if (key.endswith('_dir') or key in {'config_file', 'bin_path'}) and value and not (key == 'sounds_dir' and value == 'skipped') and not os.path.isabs(value):
        raise ValueError('relative receipt path')
    print(value)
except (OSError, UnicodeError, ValueError, SyntaxError):
    pass
PY
}

khuluma_absolute_path() {
  python3 - "${1:-}" <<'PY'
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

khuluma_resolve_identity_paths() {
  local binary="${1:-${KHULUMA_RUNNING_BINARY:-}}" receipt candidate value default_config
  default_config="${XDG_CONFIG_HOME:-$HOME/.config}/khuluma"
  KHULUMA_EFFECTIVE_RECEIPT=""
  if [[ -n "$binary" ]]; then
    binary="$(khuluma_absolute_path "$binary")"
    for candidate in "$(dirname "$(dirname "$binary")")/share/khuluma/install-receipt.env" \
      "${KHULUMA_CONFIG_DIR:-$default_config}/install-receipt.env" "$default_config/install-receipt.env"; do
      value="$(khuluma_receipt_value bin_path "$candidate" "$binary")"
      if [[ -n "$value" ]]; then KHULUMA_EFFECTIVE_RECEIPT="$candidate"; break; fi
    done
  fi
  receipt="$KHULUMA_EFFECTIVE_RECEIPT"
  value="$(khuluma_receipt_value config_dir "$receipt" "$binary")"
  KHULUMA_CONFIG_DIR="$(khuluma_absolute_path "${KHULUMA_CONFIG_DIR:-${value:-$default_config}}")"
  value="$(khuluma_receipt_value config_file "$receipt" "$binary")"
  KHULUMA_CONFIG_FILE="$(khuluma_absolute_path "${KHULUMA_CONFIG_FILE:-${value:-$KHULUMA_CONFIG_DIR/config.toml}}")"
  XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  value="$(khuluma_receipt_value native_dir "$receipt" "$binary")"
  if [[ -n "${KHULUMA_DAEMON_BUILD_ROOT:-}" ]]; then :
  elif [[ -n "${KHULUMA_NATIVE_DIR:-}" ]]; then KHULUMA_DAEMON_BUILD_ROOT="$KHULUMA_NATIVE_DIR/khulumad"
  else KHULUMA_DAEMON_BUILD_ROOT="${value:-$XDG_DATA_HOME/khuluma/native/khulumad}"; fi
  KHULUMA_DAEMON_BUILD_ROOT="$(khuluma_absolute_path "$KHULUMA_DAEMON_BUILD_ROOT")"
  KHULUMA_NATIVE_DIR="$(dirname "$KHULUMA_DAEMON_BUILD_ROOT")"
  value="$(khuluma_receipt_value models_dir "$receipt" "$binary")"
  KHULUMA_PARAKEET_MODELS_DIR="$(khuluma_absolute_path "${KHULUMA_PARAKEET_MODELS_DIR:-${value:-$XDG_DATA_HOME/khuluma/models}}")"
  value="$(khuluma_receipt_value sounds_dir "$receipt" "$binary")"
  [[ "$value" != "skipped" ]] || value=""
  KHULUMA_SOUNDS_DIR="$(khuluma_absolute_path "${KHULUMA_SOUNDS_DIR:-${value:-${SOUNDS_DIR:-$XDG_DATA_HOME/sounds}/khuluma}}")"
}

# Read-only: detect an old default profile before any canonical writes.
khuluma_identity_migration_required() {
  local canonical="${KHULUMA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/khuluma}"
  local legacy="${XDG_CONFIG_HOME:-$HOME/.config}/dictate" default_config="${XDG_CONFIG_HOME:-$HOME/.config}/khuluma"
  canonical="$(khuluma_absolute_path "$canonical")"
  legacy="$(khuluma_absolute_path "$legacy")"
  default_config="$(khuluma_absolute_path "$default_config")"
  # Explicit unrelated profiles are isolated; an explicitly pinned old default
  # must still not split writes after the new default has been committed.
  if [[ "$canonical" == "$legacy" ]]; then
    [[ ! -f "$default_config/.khuluma-identity.json" ]] || return 0
    return 1
  fi
  [[ "$canonical" == "$default_config" ]] || return 1
  local data="${XDG_DATA_HOME:-$HOME/.local/share}"
  if [[ ! -e "$legacy" && ! -e "$data/tmux-whisper/native" && ! -e "$data/tmux-whisper/models" && ! -e "${SOUNDS_DIR:-$data/sounds}/dictate" ]]; then return 1; fi
  if ! declare -F khuluma_identity_migration_committed >/dev/null 2>&1; then
    local migration_module="$(dirname "${BASH_SOURCE[0]}")/migration.sh"
    [[ ! -r "$migration_module" ]] || source "$migration_module"
  fi
  if declare -F khuluma_identity_migration_committed >/dev/null 2>&1; then
    khuluma_identity_migration_committed "$canonical" && return 1
  fi
  if [[ -n "${KHULUMA_MIGRATION_ADMISSION_RECEIPT:-}" ]] && declare -F khuluma_identity_migration_staged >/dev/null 2>&1; then
    khuluma_identity_migration_staged "$canonical" "$KHULUMA_MIGRATION_ADMISSION_RECEIPT" && return 1
  fi
  return 0
}

khuluma_identity_preflight() {
  khuluma_reject_obsolete_environment || return
  khuluma_resolve_identity_paths "${1:-${KHULUMA_RUNNING_BINARY:-}}" || return
  if khuluma_identity_migration_required; then
    printf '%s\n' 'khuluma: legacy profile requires the explicit identity migration; run tools/migrate-khuluma-identity.sh --dry-run before installing or writing.' >&2
    return 2
  fi
}

# Cleanup is recoverable. Validate the exact owned target; never delete through
# a symlink or substitute a permanent-removal fallback when Trash is unavailable.
khuluma_trash_owned() {
  local target
  for target in "$@"; do
    [[ -n "$target" ]] || continue
    [[ -e "$target" || -L "$target" ]] || continue
    python3 "${KHULUMA_RECOVERY_HELPER:?missing recovery helper}" "$target" || return
  done
}

# mkdir locks used by bench are empty; retain rmdir's nonempty refusal.
khuluma_trash_empty_directory() {
  [[ -d "$1" && ! -L "$1" ]] || return 0
  python3 "${KHULUMA_RECOVERY_HELPER:?missing recovery helper}" --empty-directory "$1"
}
