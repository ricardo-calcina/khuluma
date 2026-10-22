#!/usr/bin/env bash
# Pure identity helpers. Sourcing this file never reads a profile or writes files.
KHULUMA_IDENTITY_API=1

khuluma_normalize_environment() {
  local legacy canonical
  while read -r legacy canonical; do
    [[ -n "$legacy" ]] || continue
    if [[ -n "${!canonical-}" ]]; then
      export "$canonical=${!canonical}"
    elif [[ -n "${!legacy-}" ]]; then
      export "$canonical=${!legacy}"
    fi
  done <<'ALIASES'
DICTATE_APP_HOTKEY KHULUMA_APP_HOTKEY
DICTATE_APP_SUPERVISE_DAEMON KHULUMA_APP_SUPERVISE_DAEMON
DICTATE_AUTOSEND KHULUMA_AUTOSEND
DICTATE_BENCH_MAX_ROWS KHULUMA_BENCH_MAX_ROWS
DICTATE_BIN KHULUMA_BIN
DICTATE_BIN_DIR KHULUMA_BIN_DIR
DICTATE_BOOTSTRAP_ARCHIVE_URL KHULUMA_BOOTSTRAP_ARCHIVE_URL
DICTATE_BOOTSTRAP_REF KHULUMA_BOOTSTRAP_REF
DICTATE_BOOTSTRAP_REPO KHULUMA_BOOTSTRAP_REPO
DICTATE_BRITISH_SPELLING KHULUMA_BRITISH_SPELLING
DICTATE_CLEAN KHULUMA_CLEAN
DICTATE_CONFIG_DIR KHULUMA_CONFIG_DIR
DICTATE_CONFIG_FILE KHULUMA_CONFIG_FILE
DICTATE_DAEMON_BACKGROUND_REFRESH KHULUMA_DAEMON_BACKGROUND_REFRESH
DICTATE_DAEMON_LIFECYCLE_WAIT_SECONDS KHULUMA_DAEMON_LIFECYCLE_WAIT_SECONDS
DICTATE_DAEMON_RESTART_WAIT_SECONDS KHULUMA_DAEMON_RESTART_WAIT_SECONDS
DICTATE_DAEMON_START_WAIT_SECONDS KHULUMA_DAEMON_START_WAIT_SECONDS
DICTATE_FINDER_NOTIFY_LOG KHULUMA_FINDER_NOTIFY_LOG
DICTATE_FINDER_TRANSCRIBE_LOG KHULUMA_FINDER_TRANSCRIBE_LOG
DICTATE_HISTORY_AUDIO_RETENTION_DAYS KHULUMA_HISTORY_AUDIO_RETENTION_DAYS
DICTATE_HISTORY_RETENTION_DAYS KHULUMA_HISTORY_RETENTION_DAYS
DICTATE_HISTORY_STATS_NOW KHULUMA_HISTORY_STATS_NOW
DICTATE_HISTORY_TYPING_WPM KHULUMA_HISTORY_TYPING_WPM
DICTATE_INLINE_ACTIVATE_DELAY_MS KHULUMA_INLINE_ACTIVATE_DELAY_MS
DICTATE_INLINE_PASTE_TARGET KHULUMA_INLINE_PASTE_TARGET
DICTATE_INLINE_PROCESS_SOUND KHULUMA_INLINE_PROCESS_SOUND
DICTATE_INLINE_SEND_DELAY_MS KHULUMA_INLINE_SEND_DELAY_MS
DICTATE_INLINE_SEND_MODE KHULUMA_INLINE_SEND_MODE
DICTATE_INSTALL_ARCHIVE_URL KHULUMA_INSTALL_ARCHIVE_URL
DICTATE_INSTALL_SAMPLE_SOUNDS KHULUMA_INSTALL_SAMPLE_SOUNDS
DICTATE_INSTALL_SOURCE KHULUMA_INSTALL_SOURCE
DICTATE_INSTALL_WARMUP KHULUMA_INSTALL_WARMUP
DICTATE_INTERNAL_LIB_DIR KHULUMA_INTERNAL_LIB_DIR
DICTATE_KEEP_LOGS KHULUMA_KEEP_LOGS
DICTATE_LANGUAGE KHULUMA_LANGUAGE
DICTATE_LIB_PATH KHULUMA_LIB_PATH
DICTATE_NATIVE_DIR KHULUMA_NATIVE_DIR
DICTATE_PARAKEET_MODELS_DIR KHULUMA_PARAKEET_MODELS_DIR
DICTATE_PROCESSING_DIR KHULUMA_PROCESSING_DIR
DICTATE_REPEATS_LEVEL KHULUMA_REPEATS_LEVEL
DICTATE_REPLACE_SOUNDS KHULUMA_REPLACE_SOUNDS
DICTATE_SERVICES_DIR KHULUMA_SERVICES_DIR
DICTATE_SOUNDS_DIR KHULUMA_SOUNDS_DIR
DICTATE_SWIFT_PARAKEET_MODEL_PATH KHULUMA_SWIFT_PARAKEET_MODEL_PATH
DICTATE_SWIFT_PARAKEET_MODEL_VERSION KHULUMA_SWIFT_PARAKEET_MODEL_VERSION
DICTATE_SWIFT_PARAKEET_PING_TIMEOUT_SECONDS KHULUMA_SWIFT_PARAKEET_PING_TIMEOUT_SECONDS
DICTATE_SWIFT_PARAKEET_SOCKET_PATH KHULUMA_SWIFT_PARAKEET_SOCKET_PATH
DICTATE_SWIFT_PARAKEET_TAIL_RESCUE KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE
DICTATE_SWIFT_PARAKEET_TAIL_RESCUE_MIN_MS KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE_MIN_MS
DICTATE_SWIFT_PARAKEET_TAIL_RESCUE_MS KHULUMA_SWIFT_PARAKEET_TAIL_RESCUE_MS
DICTATE_SWIFT_PARAKEET_TIMEOUT_SECONDS KHULUMA_SWIFT_PARAKEET_TIMEOUT_SECONDS
DICTATE_TMPDIR KHULUMA_TMPDIR
DICTATE_TMUX_WHISPERD_BIN KHULUMA_DAEMON_BIN
DICTATE_TMUX_WHISPERD_BUILD_ROOT KHULUMA_DAEMON_BUILD_ROOT
DICTATE_TMUX_WHISPERD_ROOT KHULUMA_DAEMON_SOURCE_ROOT
DICTATE_TRANSCRIBE_FILE_LOG KHULUMA_TRANSCRIBE_FILE_LOG
DICTATE_TRANSCRIBE_LOG KHULUMA_TRANSCRIBE_LOG
DICTATE_TRANSCRIBE_TAIL_PAD_MS KHULUMA_TRANSCRIBE_TAIL_PAD_MS
DICTATE_USAGE_NOW KHULUMA_USAGE_NOW
DICTATE_USAGE_SUMMARY_FILE KHULUMA_USAGE_SUMMARY_FILE
DICTATE_VOCAB_CLEAN KHULUMA_VOCAB_CLEAN
DICTATE_WARMUP_PRIME_MS KHULUMA_WARMUP_PRIME_MS
DICTATE_WARMUP_PRIME_TRANSCRIBE KHULUMA_WARMUP_PRIME_TRANSCRIBE
LOWKEY_KEYCHAIN KHULUMA_KEYCHAIN
LOWKEY_SIGNING_IDENTITY KHULUMA_SIGNING_IDENTITY
ALIASES
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
  khuluma_normalize_environment
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
