#!/usr/bin/env bash

# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# tmux-whisper.adapter: swiftbar
# tmux-whisper.adapter-version: 2

STATE_FILE="${DICTATE_STATE_FILE:-/tmp/whisper-dictate.state}"
INLINE_STATE="${DICTATE_INLINE_STATE_FILE:-/tmp/whisper-dictate-inline.state}"
ERROR_FLAG="${DICTATE_ERROR_FLAG:-/tmp/dictate-error.flag}"
PROCESSING_DIR="${DICTATE_PROCESSING_DIR:-/tmp/dictate-processing}"
PROCESSED_FLAG="${DICTATE_PROCESSED_FLAG:-/tmp/dictate-just-processed}"
CANCEL_FLAG="${DICTATE_CANCEL_FLAG:-/tmp/dictate-cancelled.flag}"
PROCESSING_LONG_FLAG="${DICTATE_PROCESSING_LONG_FLAG:-/tmp/dictate-inline-processing-long.flag}"
TMUX_JOBS_DIR="${DICTATE_TMUX_JOBS_DIR:-/tmp/dictate-tmux-jobs}"

# Ensure $HOME is set (SwiftBar environment can be minimal).
if [[ -z "${HOME:-}" ]]; then
  HOME="$(eval echo "~$(id -un)")"
  export HOME
fi

# SwiftBar often runs with a minimal PATH; include user-local + common package paths.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$XDG_CONFIG_HOME/dictate"
CONFIG_TOML="$CONFIG_DIR/config.toml"
MODE_FILE="$CONFIG_DIR/current-mode"
DICTATE_BIN="${DICTATE_BIN:-$(command -v tmux-whisper 2>/dev/null || true)}"
DICTATE_BIN="${DICTATE_BIN:-$HOME/.local/bin/tmux-whisper}"
DICTATE_CONFIG_DIR="$CONFIG_DIR"
DICTATE_INTERNAL_LIB_DIR="${DICTATE_INTERNAL_LIB_DIR:-$HOME/.local/bin/tmux-whisper-lib}"
if [[ ! -d "$DICTATE_INTERNAL_LIB_DIR" && -n "$DICTATE_BIN" ]]; then
  DICTATE_BIN_DIR="$(cd "$(dirname "$DICTATE_BIN")" 2>/dev/null && pwd || true)"
  if [[ -n "${DICTATE_BIN_DIR:-}" && -d "$DICTATE_BIN_DIR/tmux-whisper-lib" ]]; then
    DICTATE_INTERNAL_LIB_DIR="$DICTATE_BIN_DIR/tmux-whisper-lib"
  fi
fi
[[ -r "$DICTATE_INTERNAL_LIB_DIR/mode.sh" ]] && source "$DICTATE_INTERNAL_LIB_DIR/mode.sh"

# SwiftBar may run without interactive shell env; load API key similarly to Raycast path.
if [[ -z "${CEREBRAS_API_KEY:-}" && -f "${ZDOTDIR:-$HOME}/.zshrc" ]]; then
  eval "$(grep '^export CEREBRAS_API_KEY=' "${ZDOTDIR:-$HOME}/.zshrc" 2>/dev/null || true)"
fi

# The plugin sources both cache files, so never use SwiftBar's shared /tmp
# fallback. Honour an explicitly supplied private cache directory for test
# isolation; otherwise use a private per-user config cache.
# GNU stat treats `-f` as a filesystem query, so pick the file-field form by
# platform instead of forking a failing `stat -c` on every macOS redraw.
# Usage: file_stat <gnu-format> <bsd-format> <file>
file_stat() {
  if [[ "${OSTYPE:-}" == darwin* ]]; then
    stat -f "$2" "$3"
  else
    stat -c "$1" "$3"
  fi
}

ensure_private_cache_dir() {
  local dir="${1:-}" mode
  [[ -n "$dir" && ! -L "$dir" ]] || return 1
  if [[ ! -d "$dir" ]]; then
    mkdir -p -m 700 "$dir" 2>/dev/null || return 1
  fi
  [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
  mode="$(file_stat '%a' '%Lp' "$dir" 2>/dev/null || true)"
  if [[ "$mode" != "700" && "$mode" != "0700" ]]; then
    chmod 700 "$dir" 2>/dev/null || return 1
    mode="$(file_stat '%a' '%Lp' "$dir" 2>/dev/null || true)"
  fi
  [[ "$mode" == "700" || "$mode" == "0700" ]]
}

DEFAULT_CACHE_DIR="$CONFIG_DIR/.cache/swiftbar"
CACHE_DIR="${SWIFTBAR_PLUGIN_CACHE_PATH:-$DEFAULT_CACHE_DIR}"
CACHE_DIR_READY="0"
if ensure_private_cache_dir "$CACHE_DIR"; then
  CACHE_DIR_READY="1"
elif [[ "$CACHE_DIR" != "$DEFAULT_CACHE_DIR" ]] && ensure_private_cache_dir "$DEFAULT_CACHE_DIR"; then
  CACHE_DIR="$DEFAULT_CACHE_DIR"
  CACHE_DIR_READY="1"
fi
CONFIG_CACHE="$CACHE_DIR/dictate-config.cache"
USAGE_CACHE="$CACHE_DIR/tmux-whisper-usage.cache"
# The plugin is polled every 0.2 seconds. Keep the durable CLI read off that
# hot path, but always invalidate immediately when its atomic ledger changes.
USAGE_CACHE_TTL_SECONDS="${DICTATE_SWIFTBAR_USAGE_CACHE_TTL_SECONDS:-30}"
[[ "$USAGE_CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]] || USAGE_CACHE_TTL_SECONDS=30
# A failed read (e.g. a corrupt ledger) is retried slowly; the signature check
# still picks up a repaired file on the next redraw.
USAGE_FAILURE_CACHE_TTL_SECONDS="${DICTATE_SWIFTBAR_USAGE_FAILURE_CACHE_TTL_SECONDS:-60}"
[[ "$USAGE_FAILURE_CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]] || USAGE_FAILURE_CACHE_TTL_SECONDS=60

shopt -s nullglob

safe_key() {
  printf "%s" "${1:-}" | sed -E 's/[^A-Za-z0-9_]/_/g'
}

safe_cache_file() {
  local file="${1:-}"
  [[ -f "$file" && ! -L "$file" && -O "$file" ]]
}

write_usage_cache() {
  local tmp
  tmp="$(mktemp "$CACHE_DIR/.tmux-whisper-usage.cache.XXXXXX" 2>/dev/null)" || return 1
  chmod 600 "$tmp" 2>/dev/null || return 1
  cat >"$tmp" && mv -f "$tmp" "$USAGE_CACHE"
}

write_config_cache() {
  local tmp
  tmp="$(mktemp "$CACHE_DIR/.dictate-config.cache.XXXXXX" 2>/dev/null)" || return 1
  chmod 600 "$tmp" 2>/dev/null || return 1
  cat >"$tmp" && mv -f "$tmp" "$CONFIG_CACHE"
}

short_path_tail() {
  local p="${1:-}"
  [[ -n "$p" ]] || return 0
  p="${p%/}"
  [[ -z "$p" ]] && { echo "/"; return 0; }
  local base parent
  base="$(basename "$p")"
  parent="$(basename "$(dirname "$p")")"
  if [[ "$parent" == "/" || "$parent" == "." || "$parent" == "$base" ]]; then
    echo "$base"
  else
    echo "$parent/$base"
  fi
}

# NOTE: SwiftBar runs this script frequently; flags are meant to be short-lived.
is_recent_file() {
  local f="${1:-}"
  local max_age_s="${2:-}"
  [[ -n "$f" && -n "$max_age_s" && -f "$f" ]] || return 1
  local now mtime age
  now="$(date +%s)"
  mtime="$(file_stat %Y %m "$f" 2>/dev/null || true)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  age=$((now - mtime))
  [[ "$age" -le "$max_age_s" ]]
}

usage_summary_file() {
  printf '%s\n' "${DICTATE_USAGE_SUMMARY_FILE:-$DICTATE_CONFIG_DIR/usage.json}"
}

usage_file_signature() {
  local file="${1:-}"
  [[ -f "$file" ]] || { printf '%s\n' "missing"; return 0; }

  # inode, mtime, and size are cheap to read at every redraw. The CLI publishes
  # usage.json with an atomic replacement, so inode catches back-to-back
  # deliveries that happen in one timestamp tick with the same byte length.
  file_stat '%i:%Y:%s' '%i:%m:%z' "$file" 2>/dev/null || printf '%s\n' "unreadable"
}

format_usage_duration() {
  local value="${1:-0}"
  [[ "$value" =~ ^-?[0-9]+$ ]] || { printf '%s\n' "?"; return 0; }
  local sign=""
  if [[ "$value" == -* ]]; then
    sign="-"
    value="${value#-}"
  elif [[ "$value" -gt 0 ]]; then
    sign="+"
  fi
  local seconds=$((value / 1000)) hours minutes
  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  seconds=$((seconds % 60))
  if [[ "$hours" -gt 0 ]]; then
    printf '%s%dh %02dm\n' "$sign" "$hours" "$minutes"
  elif [[ "$minutes" -gt 0 ]]; then
    printf '%s%dm %02ds\n' "$sign" "$minutes" "$seconds"
  else
    printf '%s%ds\n' "$sign" "$seconds"
  fi
}

# Load the stable `tmux-whisper usage --json` contract into a small, safe
# cache. The first argument is a completed-delivery marker signature: it causes
# one fresh CLI read, then remains cached for that same marker.
# Usage failures are deliberately non-fatal: recording/processing controls
# must never depend on an operator summary being available.
load_usage_summary() {
  local completion_signature="${1:-}" usage_file signature now cache_fresh="0"
  usage_file="$(usage_summary_file)"
  signature="$(usage_file_signature "$usage_file")"
  now="$(date +%s)"
  USAGE_MENU_STATE="unavailable"
  unset USAGE_TRACKING_STARTED_AT USAGE_DELIVERIES USAGE_WORDS USAGE_TIME_DIFFERENCE_MS
  [[ "$CACHE_DIR_READY" == "1" ]] || return 0

  if safe_cache_file "$USAGE_CACHE"; then
    # shellcheck disable=SC1090
    source "$USAGE_CACHE" 2>/dev/null || true
    if [[ "${USAGE_CACHE_SIGNATURE:-}" == "$signature" && "${USAGE_CACHE_EXPIRES_AT:-0}" =~ ^[0-9]+$ && "${USAGE_CACHE_EXPIRES_AT:-0}" -ge "$now" && ( -z "$completion_signature" || "${USAGE_CACHE_COMPLETION_SIGNATURE:-}" == "$completion_signature" ) ]]; then
      cache_fresh="1"
    fi
  fi
  [[ "$cache_fresh" == "1" ]] && return 0

  # A stale cache must not survive an unavailable or malformed fresh read.
  USAGE_MENU_STATE="unavailable"
  unset USAGE_TRACKING_STARTED_AT USAGE_DELIVERIES USAGE_WORDS USAGE_TIME_DIFFERENCE_MS

  local usage_json parsed expires
  usage_json="$("$DICTATE_BIN" usage --json 2>/dev/null)" || usage_json=""
  parsed="$(python3 - "$usage_json" <<'PYEOF' 2>/dev/null || true
import json, shlex, sys

try:
    payload = json.loads(sys.argv[1])
    coverage = payload["coverage"]
    deliveries = payload["delivered_dictations"]
    if payload.get("command") != "usage" or payload.get("schema_version") != 1:
        raise ValueError("unexpected usage contract")
    if not isinstance(coverage, dict) or not isinstance(deliveries, dict):
        raise ValueError("invalid usage sections")
    state = coverage.get("status")
    if state not in {"active", "not_started"}:
        raise ValueError("invalid usage status")
    started = coverage.get("tracking_started_at") if state == "active" else ""
    if state == "active" and (not isinstance(started, str) or not started):
        raise ValueError("invalid tracking timestamp")
    def integer(value, name, *, nonnegative=False):
        if isinstance(value, bool) or not isinstance(value, int) or (nonnegative and value < 0):
            raise ValueError(f"invalid {name}")
        return value
    values = {
        "USAGE_MENU_STATE": state,
        "USAGE_TRACKING_STARTED_AT": started,
        "USAGE_DELIVERIES": integer(deliveries.get("count", 0), "delivery count", nonnegative=True),
        "USAGE_WORDS": integer(payload.get("processed_words", 0), "word count", nonnegative=True),
        "USAGE_TIME_DIFFERENCE_MS": integer(payload.get("estimated_time_difference_ms", 0), "time difference"),
    }
    for key, value in values.items():
        print(f"{key}={shlex.quote(str(value))}")
except Exception:
    pass
PYEOF
  )"
  if [[ -z "$parsed" ]]; then
    expires=$((now + USAGE_FAILURE_CACHE_TTL_SECONDS))
    {
      echo "# Autogenerated SwiftBar usage cache"
      printf 'USAGE_CACHE_SIGNATURE=%q\n' "$signature"
      printf 'USAGE_CACHE_COMPLETION_SIGNATURE=%q\n' "$completion_signature"
      printf 'USAGE_CACHE_EXPIRES_AT=%q\n' "$expires"
      echo "USAGE_MENU_STATE=unavailable"
    } | write_usage_cache >/dev/null 2>&1 || true
    return 0
  fi

  expires=$((now + USAGE_CACHE_TTL_SECONDS))
  {
    echo "# Autogenerated SwiftBar usage cache"
    printf 'USAGE_CACHE_SIGNATURE=%q\n' "$signature"
    printf 'USAGE_CACHE_COMPLETION_SIGNATURE=%q\n' "$completion_signature"
    printf 'USAGE_CACHE_EXPIRES_AT=%q\n' "$expires"
    printf '%s\n' "$parsed"
  } | write_usage_cache >/dev/null 2>&1 || true
  eval "$parsed"
}

emit_usage_summary_menu() {
  case "${USAGE_MENU_STATE:-unavailable}" in
    active)
      echo "Usage (tracked): ${USAGE_WORDS:-0} words · ${USAGE_DELIVERIES:-0} deliveries | size=11 color=gray"
      echo "Tracking since: ${USAGE_TRACKING_STARTED_AT:-unknown} | size=11 color=gray"
      echo "Estimated typing-time difference: $(format_usage_duration "${USAGE_TIME_DIFFERENCE_MS:-0}") (typing - dictation) | size=11 color=gray"
      ;;
    not_started)
      echo "Usage tracking starts with the next delivered dictation | size=11 color=gray"
      ;;
    *)
      echo "Usage summary unavailable (will retry) | size=11 color=gray"
      ;;
  esac
}

load_config() {
  command -v python3 >/dev/null 2>&1 || return 0
  [[ "$CACHE_DIR_READY" == "1" ]] || return 0

  local cache_sig="missing"
  if [[ -f "$CONFIG_TOML" ]]; then
    cache_sig="$(cksum <"$CONFIG_TOML" 2>/dev/null | awk '{print $1 ":" $2}' || true)"
    [[ -n "$cache_sig" ]] || cache_sig="missing"
  fi
  if safe_cache_file "$CONFIG_CACHE"; then
    # shellcheck disable=SC1090
    source "$CONFIG_CACHE" 2>/dev/null || true
    if [[ "${CFG_CACHE_SIG:-}" == "$cache_sig" && -n "${CFG_AUDIO_SILENCE_TRIM:-}" && -n "${CFG_CLEAN_REPEATS_LEVEL:-}" && -n "${CFG_INLINE_PROCESS_SOUND:-}" && -n "${CFG_TMUX_PROCESS_SOUND:-}" && -n "${CFG_SWIFTBAR_ENABLED:-}" ]]; then
      return 0
    fi
  fi

  local out
  out="$(
    python3 - "$CONFIG_TOML" <<'PYEOF' 2>/dev/null || true
import os, shlex, sys, tomllib

path = os.path.expanduser(sys.argv[1])
cfg = {}
if os.path.exists(path):
  with open(path, "rb") as f:
    cfg = tomllib.load(f) or {}

def get(path, default=None):
  cur = cfg
  for part in path.split("."):
    if not isinstance(cur, dict) or part not in cur:
      return default
    cur = cur[part]
  return cur

def safe_key(k: str) -> str:
  out = []
  for ch in k:
    out.append(ch if (ch.isalnum() or ch == "_") else "_")
  return "".join(out)

def b(v, default=False):
  if v is None:
    return default
  return bool(v)

post_enabled = "1" if b(get("postprocess.enabled", False), False) else "0"
autosend = "1" if b(get("inline.autosend", True), True) else "0"
parakeet_model_path = str(get("swift_parakeet.model_path", ""))

print(f"CFG_CACHE_MTIME={shlex.quote(str(int(os.path.getmtime(path)) if os.path.exists(path) else 0))}")
print(f"CFG_POSTPROCESS_ENABLED={shlex.quote(post_enabled)}")
print(f"CFG_INLINE_AUTOSEND={shlex.quote(autosend)}")
print(f"CFG_INLINE_PROCESS_SOUND={shlex.quote('1' if b(get('inline.process_sound', True), True) else '0')}")
print(f"CFG_INLINE_PASTE_TARGET={shlex.quote(str(get('inline.paste_target', 'restore')))}")
print(f"CFG_SWIFT_PARAKEET_MODEL_PATH={shlex.quote(parakeet_model_path)}")
print(f"CFG_AUDIO_SOURCE={shlex.quote(str(get('audio.source', 'auto')))}")
print(f"CFG_AUDIO_DEVICE_NAME={shlex.quote(str(get('audio.device_name', '')))}")
print(f"CFG_AUDIO_MAC_NAME={shlex.quote(str(get('audio.mac_name', 'MacBook Air Microphone')))}")
print(f"CFG_AUDIO_IPHONE_NAME={shlex.quote(str(get('audio.iphone_name', '')))}")
print(f"CFG_AUDIO_SILENCE_TRIM={shlex.quote('1' if b(get('audio.silence_trim', False), False) else '0')}")
print(f"CFG_CLEAN_REPEATS_LEVEL={shlex.quote(str(get('clean.repeats_level', '1')))}")
print(f"CFG_TMUX_AUTOSEND={shlex.quote('1' if b(get('tmux.autosend', True), True) else '0')}")
print(f"CFG_TMUX_PASTE_TARGET={shlex.quote(str(get('tmux.paste_target', 'origin')))}")
print(f"CFG_TMUX_POSTPROCESS={shlex.quote('1' if b(get('tmux.postprocess', False), False) else '0')}")
print(f"CFG_TMUX_PROCESS_SOUND={shlex.quote('1' if b(get('tmux.process_sound', False), False) else '0')}")
print(f"CFG_TMUX_MODE={shlex.quote(str(get('tmux.mode', 'code')))}")
print(f"CFG_TMUX_SEND_MODE={shlex.quote(str(get('tmux.send_mode', 'auto')))}")
print(f"CFG_DEBUG_KEEP_LOGS={shlex.quote('1' if b(get('debug.keep_logs', False), False) else '0')}")
print(f"CFG_SWIFTBAR_ENABLED={shlex.quote('1' if b(get('integrations.swiftbar.enabled', True), True) else '0')}")

icons = get("ui.icons", {}) or {}
if isinstance(icons, dict):
  for k, v in icons.items():
    print(f"CFG_ICON_{safe_key(str(k))}={shlex.quote(str(v))}")

keybinds = get("ui.keybinds", {}) or {}
if isinstance(keybinds, dict):
  for k, v in keybinds.items():
    print(f"CFG_KEYBIND_{safe_key(str(k))}={shlex.quote(str(v))}")
PYEOF
  )"

  if [[ -n "$out" ]]; then
    eval "$out"
    {
      echo "# Autogenerated cache for SwiftBar"
      printf "CFG_CACHE_SIG=%q\n" "$cache_sig"
      echo "$out"
    } | write_config_cache >/dev/null 2>&1 || true
  fi
}

load_config

get_icon() {
  local key="$1"
  local fallback="$2"
  local safe var value
  safe="$(safe_key "$key")"
  var="CFG_ICON_${safe}"
  value="${!var:-}"
  [[ -n "$value" ]] && echo "$value" || echo "$fallback"
}

get_icon_allow_empty() {
  local key="$1"
  local fallback="$2"
  local safe var
  safe="$(safe_key "$key")"
  var="CFG_ICON_${safe}"
  if [[ -n "${!var+x}" ]]; then
    printf '%s\n' "${!var}"
  else
    printf '%s\n' "$fallback"
  fi
}

get_keybind() {
  local key="$1"
  local fallback="$2"
  local safe var value
  safe="$(safe_key "$key")"
  var="CFG_KEYBIND_${safe}"
  value="${!var:-}"
  [[ -n "$value" ]] && echo "$value" || echo "$fallback"
}

normalize_audio_source() {
  local src="${1:-auto}"
  src="$(printf "%s" "$src" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$src" in
    auto|external|mac|iphone|name) echo "$src" ;;
    *) echo "auto" ;;
  esac
}

audio_source_label() {
  local src
  src="$(normalize_audio_source "${1:-auto}")"
  case "$src" in
    auto) echo "auto (external -> mac -> iphone)" ;;
    external) echo "external mic" ;;
    mac) echo "mac built-in mic" ;;
    iphone) echo "iphone mic" ;;
    name) echo "named device" ;;
    *) echo "auto (external -> mac -> iphone)" ;;
  esac
}

load_audio_resolution_cache() {
  AUDIO_CACHE_NAME=""
  AUDIO_CACHE_MATCH=""
  AUDIO_CACHE_INDEX=""
  local cache_file="$CONFIG_DIR/.cache/audio-index.sh"
  [[ -f "$cache_file" ]] || return 1
  # shellcheck disable=SC1090
  source "$cache_file" 2>/dev/null || return 1
  AUDIO_CACHE_NAME="${CACHED_AUDIO_NAME:-}"
  AUDIO_CACHE_MATCH="${CACHED_AUDIO_MATCH:-}"
  AUDIO_CACHE_INDEX="${CACHED_AUDIO_INDEX:-}"
  [[ -n "$AUDIO_CACHE_INDEX" ]] || return 1
  return 0
}

list_modes_for_flow() {
  list_modes "${1:-}"
}

read_saved_mode_raw() {
  if [[ -f "$MODE_FILE" ]]; then
    printf '%s' "$(cat "$MODE_FILE" 2>/dev/null || true)" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
  else
    echo "auto"
  fi
}

mode_hidden_in_inline_menu() {
  local mode_name
  mode_name="$(normalize_mode_name "${1:-}")"
  case "$mode_name" in
    email|chat|linkedin|twitter|long) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_inline_mode() {
  local saved_mode_raw="${1:-}"
  if [[ -z "$saved_mode_raw" || "$saved_mode_raw" == "auto" ]]; then
    detect_mode
    return 0
  fi
  if mode_exists "$saved_mode_raw" && mode_allows_flow "$saved_mode_raw" "inline"; then
    normalize_mode_name "$saved_mode_raw"
  else
    default_inline_mode
  fi
}

emit_inline_modes_menu() {
  local saved_mode_raw="${1:-auto}"
  local selected_mode="$saved_mode_raw"
  if [[ -z "$selected_mode" || "$selected_mode" == "auto" ]]; then
    selected_mode="${2:-$(default_inline_mode)}"
  fi
  local mode_name
  while IFS= read -r mode_name; do
    [[ -n "$mode_name" ]] || continue
    if mode_hidden_in_inline_menu "$mode_name"; then
      continue
    fi
    local mode_label
    mode_label="$(mode_display_name "$mode_name")"
    if [[ "$mode_name" == "$selected_mode" ]]; then
      echo "-- ✓ $mode_label | bash=$DICTATE_BIN param1=mode param2=$mode_name terminal=false refresh=true"
    else
      echo "-- $mode_label | bash=$DICTATE_BIN param1=mode param2=$mode_name terminal=false refresh=true"
    fi
  done < <(list_modes_for_flow "inline")
}

emit_tmux_modes_menu() {
  local current_mode
  current_mode="$(normalize_mode_name "${1:-code}")"
  local current_mode_display
  current_mode_display="$(mode_display_name "$current_mode")"
  local mode_name
  while IFS= read -r mode_name; do
    [[ -n "$mode_name" ]] || continue
    mode_name="$(mode_display_name "$mode_name")"
    if [[ "$mode_name" == "$current_mode_display" ]]; then
      echo "-- ✓ $mode_name | bash=$DICTATE_BIN param1=tmux param2=mode param3=$mode_name terminal=false refresh=true"
    else
      echo "-- $mode_name | bash=$DICTATE_BIN param1=tmux param2=mode param3=$mode_name terminal=false refresh=true"
    fi
  done < <(list_modes_for_flow "tmux")
}

# Count active processing jobs
count_processing() {
  if [[ -d "$PROCESSING_DIR" ]]; then
    local now count
    now="$(date +%s)"
    count=0
    local f line pid kind phase
    for f in "$PROCESSING_DIR"/*; do
      [[ -f "$f" ]] || continue

      pid=""
      kind=""
      line="$(head -n 1 "$f" 2>/dev/null || true)"
      if [[ "$line" =~ ^pid=([0-9]+)$ ]]; then
        pid="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[0-9]+$ ]]; then
        pid="$line"
      fi
      kind="$(sed -n 's/^kind=//p' "$f" 2>/dev/null | head -n 1 || true)"
      # Lowkey markers cover the whole take: count only the processing part
      # (a take handed to the CLI has the CLI's own marker).
      phase="$(sed -n 's/^phase=//p' "$f" 2>/dev/null | head -n 1 || true)"

      # Only show processing for inline flows (Raycast inline or `tmux-whisper inline`).
      # Still clean up stale markers for other kinds.
      local is_inline="0"
      if [[ "$kind" == "raycast-inline" || "$kind" == "inline" ]]; then
        is_inline="1"
      elif [[ "$(basename "$f")" == inline-* ]]; then
        is_inline="1"
      fi

      [[ -z "$phase" || "$phase" == "queued" || "$phase" == "processing" ]] || is_inline="0"

      if [[ -n "$pid" ]]; then
        if kill -0 "$pid" 2>/dev/null; then
          [[ "$is_inline" == "1" ]] && count=$((count + 1))
          continue
        fi
        rm -f "$f" 2>/dev/null || true
        continue
      fi

      # If there's no pid, treat it as stale.
      rm -f "$f" 2>/dev/null || true
    done
    echo "$count"
  else
    echo "0"
  fi
}

# Count tmux jobs (recording/processing)
count_tmux_jobs() {
  local rec=0 proc=0
  [[ -d "$TMUX_JOBS_DIR" ]] || { echo "0 0"; return 0; }
  local now mtime age status marker_pid f
  now="$(date +%s)"
  for f in "$TMUX_JOBS_DIR"/*; do
    [[ -f "$f" ]] || continue
    mtime="$(stat -f %m "$f" 2>/dev/null || echo 0)"
    age=$((now - mtime))
    if [[ "$age" -gt 1800 ]]; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    status="$(sed -n 's/^status=//p' "$f" 2>/dev/null | head -n 1 || true)"
    marker_pid="$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -n 1 || true)"
    case "$status" in
      recording|processing)
        if [[ -z "$marker_pid" || ! "$marker_pid" =~ ^[0-9]+$ ]]; then
          rm -f "$f" 2>/dev/null || true
          continue
        fi
        if ! kill -0 "$marker_pid" 2>/dev/null; then
          rm -f "$f" 2>/dev/null || true
          continue
        fi
        ;;
    esac
    case "$status" in
      recording) rec=$((rec + 1)) ;;
      processing) proc=$((proc + 1)) ;;
      *) ;;
    esac
  done
  echo "$rec $proc"
}

# Check if just processed (within the brief handoff window)
just_processed() {
  if [[ -f "$PROCESSED_FLAG" ]]; then
    if is_recent_file "$PROCESSED_FLAG" 2; then
      return 0
    fi
    rm -f "$PROCESSED_FLAG" 2>/dev/null || true
  fi
  return 1
}

# Check if just cancelled (within the brief handoff window)
just_cancelled() {
  if [[ -f "$CANCEL_FLAG" ]]; then
    if is_recent_file "$CANCEL_FLAG" 2; then
      return 0
    fi
    rm -f "$CANCEL_FLAG" 2>/dev/null || true
  fi
  return 1
}

# Mode icon from config
mode_icon() {
  local mode="$1"
  case "$mode" in
    base|code|email|chat|long|linkedin|twitter) get_icon_allow_empty "$mode" "" ;;
    *) get_icon_allow_empty "$mode" "" ;;
  esac
}

compose_status_icon() {
  local primary="${1:-}"
  local secondary="${2:-}"
  if [[ -n "$secondary" ]]; then
    printf '%s %s\n' "$primary" "$secondary"
  else
    printf '%s\n' "$primary"
  fi
}

# State icons from config
ICON_RECORDING="$(get_icon "recording" "🔴")"
ICON_PROCESSING="$(get_icon "processing" "⏳")"
ICON_READY="$(get_icon "ready" "🎙️")"
ICON_ERROR="$(get_icon "error" "⚠️")"
ICON_CANCEL="$(get_icon "cancel" "🚫")"
ICON_PAUSED="$(get_icon "paused" "⏸")"

if [[ ! -x "$DICTATE_BIN" ]]; then
  echo "$ICON_ERROR"
  echo "---"
  echo "Tmux Whisper binary not found | color=red"
  echo "Checked: ${DICTATE_BIN:-<none>} | size=11 color=gray"
  echo "Install (stable): brew install ricardo-nth/tap/tmux-whisper | size=11"
  echo "Install (dev): ./install.sh --force | size=11"
  exit 0
fi

swiftbar_enabled="${CFG_SWIFTBAR_ENABLED:-1}"
if [[ "$swiftbar_enabled" != "1" ]]; then
  echo "$ICON_PAUSED"
  echo "---"
  echo "SwiftBar integration: OFF | color=gray"
  echo "Enable SwiftBar integration | bash=$DICTATE_BIN param1=swiftbar param2=on terminal=false refresh=true"
  echo "CLI and Raycast dictation remain active | size=11 color=gray"
  exit 0
fi

# Check for recent cancel (show briefly)
if just_cancelled; then
  echo "$ICON_CANCEL"
  echo "---"
  echo "Cancelled | color=orange"
  exit 0
fi

saved_mode_raw="$(read_saved_mode_raw)"
saved_mode="$(resolve_inline_mode "$saved_mode_raw")"

# Determine mode icon display
current_mode_icon="$(mode_icon "$saved_mode")"
mode_display="$(mode_display_name "$saved_mode")"

# Check if recording (either tmux or inline mode)
recording_state_file=""
for candidate_state in "$INLINE_STATE" "$STATE_FILE"; do
  [[ -f "$candidate_state" ]] || continue
  unset pid wav target_pane target_app model_id language
  # shellcheck disable=SC1090
  source "$candidate_state" 2>/dev/null || true
  if kill -0 "${pid:-0}" 2>/dev/null || is_recent_file "$candidate_state" 2; then
    recording_state_file="$candidate_state"
    break
  fi
  # The marker is stale, but its WAV may still be useful for manual recovery.
  rm -f "$candidate_state" 2>/dev/null || true
done

if [[ -n "$recording_state_file" ]]; then
    # Recording state
    compose_status_icon "$ICON_RECORDING" "$current_mode_icon"
    echo "---"
    echo "Recording... | color=red"
    echo "Mode: $mode_display | size=11"
    if [[ -n "$target_pane" ]]; then
      target_label="$target_pane"
      if command -v tmux >/dev/null 2>&1; then
        pane_title="$(tmux display-message -p -t "$target_pane" '#{pane_title}' 2>/dev/null || true)"
        pane_path="$(tmux display-message -p -t "$target_pane" '#{pane_current_path}' 2>/dev/null || true)"
        pane_path="$(short_path_tail "$pane_path")"
        [[ -n "$pane_title" ]] && target_label="$target_label · $pane_title"
        [[ -n "$pane_path" ]] && target_label="$target_label · $pane_path"
      fi
      echo "Target: tmux $target_label | size=11"
    else
      echo "Target: inline | size=11"
    fi
    echo "---"
    echo "Stop Recording | bash=$DICTATE_BIN param1=stop terminal=false refresh=true"
    echo "Cancel Recording | bash=$DICTATE_BIN param1=cancel terminal=false refresh=true"
    exit 0
fi

# A live recording always takes precedence over a prior processing failure.
if [[ -f "$ERROR_FLAG" ]]; then
  if is_recent_file "$ERROR_FLAG" 10; then
    echo "$ICON_ERROR"
    echo "---"
    echo "Error occurred | color=red"
    echo "Check: /tmp/dictate-raycast-inline.log | size=11"
    echo "---"
    echo "Clear Error | bash=/bin/rm param1=-f param2=$ERROR_FLAG terminal=false refresh=true"
    exit 0
  else
    rm -f "$ERROR_FLAG"
  fi
fi

# Processing count can be mildly expensive; avoid unless needed.
processing_count="$(count_processing)"

# Check if processing (inline-only). Inline owns the frontmost window until
# transcription, paste, and optional send have completed.
processing_long="0"
if [[ "$processing_count" -gt 0 ]]; then
  processing_long="1"
elif [[ -f "$PROCESSING_LONG_FLAG" ]]; then
  rm -f "$PROCESSING_LONG_FLAG" 2>/dev/null || true
fi

if [[ "$processing_long" == "1" ]]; then
  current_mode="$saved_mode"
  compose_status_icon "$ICON_PROCESSING" "$current_mode_icon"
  echo "---"
  echo "Processing ($processing_count) | color=orange"
  echo "Mode: $mode_display | size=11"
  echo "---"
  echo "Inline"
  echo "-- Modes"
  emit_inline_modes_menu "$saved_mode_raw" "$current_mode"
  exit 0
fi

# “Just processed” should not hold the ⏳ icon; show Ready icon with a brief status.
recently_processed="0"
if just_processed; then
  recently_processed="1"
fi

# Ready state
current_mode="$saved_mode"

# Ready state
compose_status_icon "$ICON_READY" "$current_mode_icon"
echo "---"
if [[ "$recently_processed" == "1" ]]; then
  echo "Just processed | color=orange"
else
  echo "Ready | color=gray"
fi
audio_source_val="$(normalize_audio_source "${DICTATE_AUDIO_SOURCE:-${CFG_AUDIO_SOURCE:-auto}}")"
audio_source_display="$(audio_source_label "$audio_source_val")"
audio_active_label="unresolved"
if [[ -n "${DICTATE_AUDIO_INDEX:-}" ]]; then
  audio_active_label="env index ${DICTATE_AUDIO_INDEX}"
elif load_audio_resolution_cache; then
  audio_active_label="${AUDIO_CACHE_NAME:-index ${AUDIO_CACHE_INDEX}}"
  [[ -n "${AUDIO_CACHE_MATCH:-}" ]] && audio_active_label="$audio_active_label (${AUDIO_CACHE_MATCH})"
fi
echo "Mode: $mode_display"
echo "Mic source: $audio_source_display | size=11"
echo "Mic active: $audio_active_label | size=11 color=gray"
completion_marker_signature=""
if [[ "$recently_processed" == "1" ]]; then
  completion_marker_signature="$(usage_file_signature "$PROCESSED_FLAG")"
fi
load_usage_summary "$completion_marker_signature"
emit_usage_summary_menu
read -r tmux_rec tmux_proc < <(count_tmux_jobs)
if [[ "${tmux_rec:-0}" -gt 0 || "${tmux_proc:-0}" -gt 0 ]]; then
  echo "TMUX queue: 🔴 ${tmux_rec:-0} · ⏳ ${tmux_proc:-0} | size=11"
fi
echo "---"
echo "Inline"
echo "-- Modes"
emit_inline_modes_menu "$saved_mode_raw" "$current_mode"
echo "-- Settings"
postprocess_val="${CFG_POSTPROCESS_ENABLED:-0}"
key_set="0"
[[ -n "${CEREBRAS_API_KEY:-}" ]] && key_set="1"
if [[ "$postprocess_val" == "1" && "$key_set" == "1" ]]; then
  postprocess_label="ON"
elif [[ "$postprocess_val" == "1" ]]; then
  postprocess_label="OFF (no key)"
else
  postprocess_label="OFF"
fi
autosend_val="${CFG_INLINE_AUTOSEND:-1}"
[[ -z "$autosend_val" ]] && autosend_val="1"
[[ "$autosend_val" == "1" ]] && autosend_label="ON" || autosend_label="OFF"
inline_process_sound_val="${CFG_INLINE_PROCESS_SOUND:-1}"
[[ "$inline_process_sound_val" == "1" ]] && inline_process_sound_label="ON" || inline_process_sound_label="OFF"
tmux_postprocess_val="${CFG_TMUX_POSTPROCESS:-0}"
if [[ "$tmux_postprocess_val" == "1" && "$key_set" == "1" ]]; then
  tmux_postprocess_label="ON"
elif [[ "$tmux_postprocess_val" == "1" ]]; then
  tmux_postprocess_label="OFF (no key)"
else
  tmux_postprocess_label="OFF"
fi
tmux_process_sound_val="${CFG_TMUX_PROCESS_SOUND:-0}"
[[ "$tmux_process_sound_val" == "1" ]] && tmux_process_sound_label="ON" || tmux_process_sound_label="OFF"
tmux_autosend_val="${CFG_TMUX_AUTOSEND:-1}"
[[ -z "$tmux_autosend_val" ]] && tmux_autosend_val="1"
[[ "$tmux_autosend_val" == "1" ]] && tmux_autosend_label="ON" || tmux_autosend_label="OFF"
inline_target_val="${CFG_INLINE_PASTE_TARGET:-restore}"
if [[ "$inline_target_val" == "current" ]]; then
  inline_target_val="current"
else
  inline_target_val="origin"
fi
tmux_target_val="${CFG_TMUX_PASTE_TARGET:-origin}"
tmux_send_mode_val="${DICTATE_TMUX_SEND_MODE:-${CFG_TMUX_SEND_MODE:-auto}}"
case "$tmux_send_mode_val" in
  auto|enter|codex) ;;
  *) tmux_send_mode_val="auto" ;;
esac
keep_logs_val="${DICTATE_KEEP_LOGS:-${CFG_DEBUG_KEEP_LOGS:-0}}"
swiftbar_toggle_val="off"
swiftbar_label="ON"
if [[ "${CFG_SWIFTBAR_ENABLED:-1}" == "1" ]]; then
  swiftbar_toggle_val="off"
  swiftbar_label="ON"
else
  swiftbar_toggle_val="on"
  swiftbar_label="OFF"
fi
[[ "$keep_logs_val" == "1" ]] && keep_logs_label="ON" || keep_logs_label="OFF"
repeats_level_val="${CFG_CLEAN_REPEATS_LEVEL:-1}"
# Toggle commands (tmux-whisper uses on/off)
autosend_toggle_val=$([[ "$autosend_val" == "1" ]] && echo "off" || echo "on")
inline_process_sound_toggle_val=$([[ "$inline_process_sound_val" == "1" ]] && echo "off" || echo "on")
postprocess_toggle_val=$([[ "$postprocess_val" == "1" ]] && echo "off" || echo "on")
tmux_autosend_toggle_val=$([[ "$tmux_autosend_val" == "1" ]] && echo "off" || echo "on")
tmux_postprocess_toggle_val=$([[ "$tmux_postprocess_val" == "1" ]] && echo "off" || echo "on")
tmux_process_sound_toggle_val=$([[ "$tmux_process_sound_val" == "1" ]] && echo "off" || echo "on")
tmux_target_toggle_val=$([[ "$tmux_target_val" == "origin" ]] && echo "current" || echo "origin")
inline_target_toggle_val=$([[ "$inline_target_val" == "origin" ]] && echo "current" || echo "origin")
keep_logs_toggle_val=$([[ "$keep_logs_val" == "1" ]] && echo "off" || echo "on")

echo "-- Postprocess: $postprocess_label | bash=$DICTATE_BIN param1=postprocess param2=$postprocess_toggle_val terminal=false refresh=true"
echo "-- Process sound: $inline_process_sound_label | bash=$DICTATE_BIN param1=inline param2=process-sound param3=$inline_process_sound_toggle_val terminal=false refresh=true"
echo "-- Autosend: $autosend_label | bash=$DICTATE_BIN param1=autosend param2=$autosend_toggle_val terminal=false refresh=true"
echo "Tmux"
echo "-- Modes"
emit_tmux_modes_menu "$(normalize_mode_name "${CFG_TMUX_MODE:-code}")"
echo "-- Settings"
echo "-- Postprocess: $tmux_postprocess_label | bash=$DICTATE_BIN param1=tmux param2=postprocess param3=$tmux_postprocess_toggle_val terminal=false refresh=true"
echo "-- Process sound: $tmux_process_sound_label | bash=$DICTATE_BIN param1=tmux param2=process-sound param3=$tmux_process_sound_toggle_val terminal=false refresh=true"
echo "-- Autosend: $tmux_autosend_label | bash=$DICTATE_BIN param1=tmux param2=autosend param3=$tmux_autosend_toggle_val terminal=false refresh=true"
echo "Advanced"
echo "-- Global | color=gray"
echo "-- SwiftBar integration: $swiftbar_label | bash=$DICTATE_BIN param1=swiftbar param2=$swiftbar_toggle_val terminal=false refresh=true"
echo "-- Keep logs: $keep_logs_label | bash=$DICTATE_BIN param1=keep-logs param2=$keep_logs_toggle_val terminal=false refresh=true"
echo "-- Inline | color=gray"
echo "-- Paste target: $inline_target_val | bash=$DICTATE_BIN param1=target param2=$inline_target_toggle_val terminal=false refresh=true"
echo "-- Repeats level"
for lvl in 0 1 2; do
  if [[ "$lvl" == "$repeats_level_val" ]]; then
    echo "---- ✓ $lvl | bash=$DICTATE_BIN param1=repeats param2=$lvl terminal=false refresh=true"
  else
    echo "---- $lvl | bash=$DICTATE_BIN param1=repeats param2=$lvl terminal=false refresh=true"
  fi
done
echo "-- Tmux | color=gray"
echo "-- Paste target: $tmux_target_val | bash=$DICTATE_BIN param1=tmux param2=target param3=$tmux_target_toggle_val terminal=false refresh=true"
echo "-- Send mode"
if [[ "auto" == "$tmux_send_mode_val" ]]; then
  echo "---- ✓ auto (detect Codex) | bash=$DICTATE_BIN param1=tmux param2=send-mode param3=auto terminal=false refresh=true"
else
  echo "---- auto (detect Codex) | bash=$DICTATE_BIN param1=tmux param2=send-mode param3=auto terminal=false refresh=true"
fi
if [[ "enter" == "$tmux_send_mode_val" ]]; then
  echo "---- ✓ enter (always Enter) | bash=$DICTATE_BIN param1=tmux param2=send-mode param3=enter terminal=false refresh=true"
else
  echo "---- enter (always Enter) | bash=$DICTATE_BIN param1=tmux param2=send-mode param3=enter terminal=false refresh=true"
fi
if [[ "codex" == "$tmux_send_mode_val" ]]; then
  echo "---- ✓ codex (Tab+Enter) | bash=$DICTATE_BIN param1=tmux param2=send-mode param3=codex terminal=false refresh=true"
else
  echo "---- codex (Tab+Enter) | bash=$DICTATE_BIN param1=tmux param2=send-mode param3=codex terminal=false refresh=true"
fi
echo "Mic src"
if [[ "$audio_source_val" == "auto" ]]; then
  echo "-- ✓ auto | bash=$DICTATE_BIN param1=device param2=source param3=auto terminal=false refresh=true"
else
  echo "-- auto | bash=$DICTATE_BIN param1=device param2=source param3=auto terminal=false refresh=true"
fi
if [[ "$audio_source_val" == "mac" ]]; then
  echo "-- ✓ mac | bash=$DICTATE_BIN param1=device param2=source param3=mac terminal=false refresh=true"
else
  echo "-- mac | bash=$DICTATE_BIN param1=device param2=source param3=mac terminal=false refresh=true"
fi
if [[ "$audio_source_val" == "external" ]]; then
  echo "-- ✓ external | bash=$DICTATE_BIN param1=device param2=source param3=external terminal=false refresh=true"
else
  echo "-- external | bash=$DICTATE_BIN param1=device param2=source param3=external terminal=false refresh=true"
fi
if [[ "$audio_source_val" == "iphone" ]]; then
  echo "-- ✓ iphone | bash=$DICTATE_BIN param1=device param2=source param3=iphone terminal=false refresh=true"
else
  echo "-- iphone | bash=$DICTATE_BIN param1=device param2=source param3=iphone terminal=false refresh=true"
fi
echo "---"
TMUX_KEY="$(get_keybind "tmux" "F12")"
INLINE_KEY="$(get_keybind "inline" "F17")"
echo "$TMUX_KEY tmux · $INLINE_KEY inline | size=11 color=gray"
