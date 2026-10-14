#!/usr/bin/env bash

detect_install_channel() {
  local bin_path="${1:-}"
  case "$bin_path" in
    /opt/homebrew/*|/usr/local/Homebrew/*|/usr/local/opt/*|/usr/local/bin/*)
      echo "homebrew"
      ;;
    "$HOME/.local/bin/"*)
      echo "local-user"
      ;;
    *)
      echo "custom"
      ;;
  esac
}

resolve_running_tmux_whisper_bin() {
  local candidate="${DICTATE_BIN:-$0}"
  if [[ -n "$candidate" && "$candidate" == */* ]]; then
    local dir base
    dir="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd)"
    base="$(basename "$candidate")"
    if [[ -n "$dir" && -e "$dir/$base" ]]; then
      printf '%s/%s\n' "$dir" "$base"
      return 0
    fi
  fi
  command -v tmux-whisper 2>/dev/null || true
}

file_age_seconds() {
  local f="${1:-}"
  [[ -f "$f" ]] || { echo "-"; return 0; }
  local now mtime
  now="$(date +%s)"
  mtime="$(stat -f %m "$f" 2>/dev/null || true)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(stat -c %Y "$f" 2>/dev/null || true)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  if [[ "$mtime" -le 0 ]]; then
    echo "?"
    return 0
  fi
  echo $((now - mtime))
}

collect_set_env_overrides() {
  local var val
  for var in "$@"; do
    val="${!var-}"
    [[ -n "$val" ]] || continue
    if [[ "$var" == "CEREBRAS_API_KEY" ]]; then
      printf '%s\t%s\n' "$var" "<set>"
    else
      printf '%s\t%s\n' "$var" "$val"
    fi
  done
}

state_file_summary_tsv() {
  local label="${1:-}"
  local file="${2:-}"
  [[ -n "$label" && -n "$file" ]] || return 1

  if [[ ! -f "$file" ]]; then
    printf 'idle\t\t\t\t\t\t\n'
    return 0
  fi

  local st_pid st_target st_app st_model st_lang st_age st_display st_state
  st_pid="$( ( source "$file" 2>/dev/null || true; printf "%s" "${pid:-}" ) 2>/dev/null || true)"
  st_target="$( ( source "$file" 2>/dev/null || true; printf "%s" "${target_pane:-}" ) 2>/dev/null || true)"
  st_app="$( ( source "$file" 2>/dev/null || true; printf "%s" "${target_app:-}" ) 2>/dev/null || true)"
  st_model="$( ( source "$file" 2>/dev/null || true; printf "%s" "${model_id:-}" ) 2>/dev/null || true)"
  st_lang="$( ( source "$file" 2>/dev/null || true; printf "%s" "${language:-}" ) 2>/dev/null || true)"
  st_age="$(file_age_seconds "$file")"

  if [[ "$label" == "tmux" ]]; then
    st_display="$st_target"
    [[ -n "$st_target" ]] && st_display="$(tmux_describe_pane "$st_target")"
  else
    st_display="${st_app:-n/a}"
  fi

  if [[ -n "$st_pid" ]] && kill -0 "$st_pid" 2>/dev/null; then
    st_state="active"
  elif [[ -z "$st_pid" && "$st_age" =~ ^[0-9]+$ && "$st_age" -le 2 ]]; then
    # A reader can encounter an in-progress legacy writer. Leave a newly
    # touched, incomplete marker alone rather than removing recording control.
    st_state="pending"
  else
    st_state="stale"
    rm -f "$file" 2>/dev/null || true
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$st_state" "$st_pid" "$st_age" "$st_display" "$st_model" "$st_lang" "${st_target:-$st_app}"
}

debug() {
  local output_format="text"
  if [[ "${1:-}" == "--json" ]]; then
    output_format="json"
  fi

  load_backend_runtime_cache >/dev/null 2>&1 || true

  local dictate_bin ffmpeg_bin python_bin swift_bin install_channel
  dictate_bin="$(resolve_running_tmux_whisper_bin)"
  ffmpeg_bin="$(command -v ffmpeg 2>/dev/null || true)"
  python_bin="$(command -v python3 2>/dev/null || true)"
  swift_bin="$(command -v swift 2>/dev/null || true)"
  install_channel="$(detect_install_channel "$dictate_bin")"

  local backend_requested swift_model_path swift_model_version swift_socket_path swift_root swift_binary swift_models_dir
  swift_models_dir="$(expand_path "$DEFAULT_SWIFT_PARAKEET_MODELS_DIR")"
  backend_requested="$(resolve_transcribe_backend)"
  swift_model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  swift_model_version="$(resolve_swift_parakeet_model_version "${swift_model_path:-}")"
  swift_socket_path="$(resolve_swift_parakeet_socket_path)"
  swift_root="$(resolve_tmux_whisperd_root 2>/dev/null || true)"
  swift_binary="${DICTATE_TMUX_WHISPERD_BIN:-${swift_root:+$(tmux_whisperd_build_root)/.build/release/tmux-whisperd}}"
  local cfg_schema_status cfg_schema_version cfg_parse_error
  cfg_schema_status="$(config_schema_status)"
  cfg_schema_version="$(config_schema_version_label)"
  cfg_parse_error="${CFG_CONFIG_PARSE_ERROR:-}"

  local src="(none)"
  local audio_cache_note=""
  local idx="${DICTATE_AUDIO_INDEX:-}"
  if [[ -n "$idx" ]]; then
    src="env:DICTATE_AUDIO_INDEX"
  elif [[ -n "${CFG_AUDIO_DEVICE_INDEX:-}" ]]; then
    idx="$CFG_AUDIO_DEVICE_INDEX"
    src="config:audio.device_index"
  else
    if [[ -n "$ffmpeg_bin" && -n "$python_bin" ]]; then
      local detect_meta detect_src detect_ms detect_note
      detect_meta="$(detect_audio_index 2>/dev/null || true)"
      IFS=$'\t' read -r idx detect_src detect_ms detect_note <<<"$detect_meta"
      if [[ -n "$idx" ]]; then
        src="${detect_src:-detect:source(${CFG_AUDIO_SOURCE:-auto})}"
      fi
      audio_cache_note="${detect_note:-}"
    else
      src="detect skipped (missing ffmpeg/python3)"
    fi
  fi

  local env_override_lines ffmpeg_devices_output
  env_override_lines="$(collect_set_env_overrides \
    DICTATE_AUDIO_SOURCE DICTATE_AUDIO_INDEX DICTATE_AUDIO_NAME \
    DICTATE_SILENCE_TRIM DICTATE_TRIM_WITH_POSTPROCESS \
    DICTATE_REPEATS_LEVEL DICTATE_REPEATS_WITH_POSTPROCESS \
    DICTATE_POSTPROCESS DICTATE_VOCAB_CLEAN DICTATE_TMUX_POSTPROCESS \
    DICTATE_TMUX_AUTOSEND DICTATE_TMUX_PASTE_TARGET DICTATE_TMUX_SEND_MODE \
    DICTATE_TMUX_SEND_DELAY_MS DICTATE_TMUX_CODEX_TAB_DELAY_MS \
    DICTATE_INLINE_PROCESS_SOUND DICTATE_INLINE_PASTE_TARGET \
    DICTATE_INLINE_ACTIVATE_DELAY_MS DICTATE_INLINE_SEND_DELAY_MS \
    DICTATE_INLINE_SEND_MODE DICTATE_TMUX_PROCESS_SOUND DICTATE_TMUX_MODE \
    DICTATE_SWIFT_PARAKEET_MODEL_PATH DICTATE_SWIFT_PARAKEET_MODEL_VERSION \
    DICTATE_SWIFT_PARAKEET_SOCKET_PATH DICTATE_LLM_MAX_TOKENS \
    DICTATE_LLM_CHUNK_WORDS DICTATE_BRITISH_SPELLING DICTATE_KEEP_LOGS \
    DICTATE_TARGET_APP DICTATE_TARGET_PANE
  )"
  if [[ -n "$ffmpeg_bin" ]]; then
    ffmpeg_devices_output="$(devices 2>/dev/null || true)"
  else
    ffmpeg_devices_output=""
  fi

  if [[ "$output_format" == "json" ]]; then
    env \
      JSON_DICTATE_BIN="$dictate_bin" \
      JSON_FFMPEG_BIN="$ffmpeg_bin" \
      JSON_PYTHON_BIN="$python_bin" \
      JSON_SWIFT_BIN="$swift_bin" \
      JSON_INSTALL_CHANNEL="$install_channel" \
      JSON_LIB_PATH="$DICTATE_LIB_PATH" \
      JSON_INTERNAL_LIB_DIR="$DICTATE_INTERNAL_LIB_DIR" \
      JSON_CONFIG_DIR="$DICTATE_CONFIG_DIR" \
      JSON_CONFIG_FILE="$DICTATE_CONFIG_FILE" \
      JSON_MODES_DIR="$DICTATE_CONFIG_DIR/modes" \
      JSON_VOCAB_FILE="$DICTATE_CONFIG_DIR/vocab" \
      JSON_PARAKEET_DIR="$swift_models_dir" \
      JSON_BACKEND="$backend_requested" \
      JSON_WHISPERD_SRC="$swift_root" \
      JSON_WHISPERD_BIN="$swift_binary" \
      JSON_WHISPERD_SOCKET="$swift_socket_path" \
      JSON_PARAKEET_MODEL="$swift_model_path" \
      JSON_PARAKEET_MODEL_VERSION="$swift_model_version" \
      JSON_RAYCAST_DIR="$DICTATE_CONFIG_DIR/integrations/raycast" \
      JSON_BACKEND_MODEL="${DICTATE_LAST_BACKEND_MODEL:-$(current_transcribe_model_label)}" \
      JSON_ENV_OVERRIDES="$env_override_lines" \
      JSON_CFG_AUDIO_SOURCE="${CFG_AUDIO_SOURCE:-auto}" \
      JSON_CFG_AUDIO_DEVICE_NAME="${CFG_AUDIO_DEVICE_NAME:-}" \
      JSON_CFG_AUDIO_MAC_NAME="${CFG_AUDIO_MAC_NAME:-}" \
      JSON_CFG_AUDIO_IPHONE_NAME="${CFG_AUDIO_IPHONE_NAME:-}" \
      JSON_CFG_AUDIO_DEVICE_INDEX="${CFG_AUDIO_DEVICE_INDEX:-}" \
      JSON_CFG_AUDIO_SILENCE_TRIM="${CFG_AUDIO_SILENCE_TRIM:-0}" \
      JSON_CFG_AUDIO_SILENCE_TRIM_MODE="${CFG_AUDIO_SILENCE_TRIM_MODE:-edges}" \
      JSON_CFG_AUDIO_SILENCE_THRESHOLD_DB="${CFG_AUDIO_SILENCE_THRESHOLD_DB:--60}" \
      JSON_CFG_AUDIO_SILENCE_MIN_MS="${CFG_AUDIO_SILENCE_MIN_MS:-250}" \
      JSON_CFG_AUDIO_SILENCE_KEEP_MS="${CFG_AUDIO_SILENCE_KEEP_MS:-50}" \
      JSON_CFG_CLEAN_REPEATS_LEVEL="${CFG_CLEAN_REPEATS_LEVEL:-1}" \
      JSON_CFG_SCHEMA_VERSION="$cfg_schema_version" \
      JSON_CFG_SCHEMA_STATUS="$cfg_schema_status" \
      JSON_CFG_SCHEMA_EXPECTED="$DICTATE_CONFIG_SCHEMA_VERSION" \
      JSON_CFG_PARSE_ERROR="$cfg_parse_error" \
      JSON_CFG_SWIFT_MODEL_PATH="${CFG_SWIFT_PARAKEET_MODEL_PATH:-}" \
      JSON_CFG_SWIFT_MODEL_VERSION="${CFG_SWIFT_PARAKEET_MODEL_VERSION:-}" \
      JSON_CFG_SWIFT_SOCKET_PATH="${CFG_SWIFT_PARAKEET_SOCKET_PATH:-$DICTATE_CONFIG_DIR/.cache/tmux-whisperd.sock}" \
      JSON_CFG_POSTPROCESS_ENABLED="${CFG_POSTPROCESS_ENABLED:-0}" \
      JSON_CFG_POSTPROCESS_LLM="${CFG_POSTPROCESS_LLM:-}" \
      JSON_CFG_POSTPROCESS_MAX_TOKENS="${CFG_POSTPROCESS_MAX_TOKENS:-}" \
      JSON_CFG_POSTPROCESS_CHUNK_WORDS="${CFG_POSTPROCESS_CHUNK_WORDS:-}" \
      JSON_CFG_POSTPROCESS_BUDGET_THRESHOLD="${CFG_POSTPROCESS_BUDGET_LONG_WORDS_THRESHOLD:-120}" \
      JSON_CFG_INLINE_AUTOSEND="${CFG_INLINE_AUTOSEND:-1}" \
      JSON_CFG_INLINE_PROCESS_SOUND="${CFG_INLINE_PROCESS_SOUND:-1}" \
      JSON_CFG_INLINE_PASTE_TARGET="$(inline_paste_target_label "${CFG_INLINE_PASTE_TARGET:-restore}")" \
      JSON_CFG_INLINE_SEND_MODE="$(inline_send_mode_label "${CFG_INLINE_SEND_MODE:-enter}")" \
      JSON_CFG_TMUX_AUTOSEND="${CFG_TMUX_AUTOSEND:-1}" \
      JSON_CFG_TMUX_PASTE_TARGET="${CFG_TMUX_PASTE_TARGET:-origin}" \
      JSON_CFG_TMUX_POSTPROCESS="${CFG_TMUX_POSTPROCESS:-0}" \
      JSON_CFG_TMUX_PROCESS_SOUND="${CFG_TMUX_PROCESS_SOUND:-0}" \
      JSON_CFG_TMUX_MODE="${CFG_TMUX_MODE:-code}" \
      JSON_CFG_TMUX_SEND_MODE="${CFG_TMUX_SEND_MODE:-auto}" \
      JSON_CFG_DEBUG_KEEP_LOGS="${CFG_DEBUG_KEEP_LOGS:-0}" \
      JSON_AUDIO_INDEX="$idx" \
      JSON_AUDIO_SOURCE_RESOLVED="$src" \
      JSON_AUDIO_CACHE_NOTE="$audio_cache_note" \
      JSON_FFMPEG_DEVICES="$ffmpeg_devices_output" \
      python3 - <<'PYEOF'
import json
import os

def s(name: str) -> str:
    return os.environ.get(name, "")

def maybe(name: str):
    value = s(name)
    return value if value else None

def to_int(name: str):
    value = s(name)
    try:
        return int(value)
    except Exception:
        return None

def to_bool_flag(name: str) -> bool:
    return s(name) == "1"

overrides = {}
for line in s("JSON_ENV_OVERRIDES").splitlines():
    if not line:
        continue
    key, value = line.split("\t", 1)
    overrides[key] = value

data = {
    "command": "debug",
    "binaries": {
        "tmux_whisper": {"path": maybe("JSON_DICTATE_BIN"), "found": maybe("JSON_DICTATE_BIN") is not None},
        "ffmpeg": {"path": maybe("JSON_FFMPEG_BIN"), "found": maybe("JSON_FFMPEG_BIN") is not None},
        "python3": {"path": maybe("JSON_PYTHON_BIN"), "found": maybe("JSON_PYTHON_BIN") is not None},
        "swift": {"path": maybe("JSON_SWIFT_BIN"), "found": maybe("JSON_SWIFT_BIN") is not None},
        "channel": s("JSON_INSTALL_CHANNEL"),
        "shared_lib": {"path": s("JSON_LIB_PATH"), "ok": os.path.isfile(s("JSON_LIB_PATH"))},
        "internal_lib": {"path": s("JSON_INTERNAL_LIB_DIR"), "ok": os.path.isdir(s("JSON_INTERNAL_LIB_DIR"))},
    },
    "paths": {
        "config_dir": {"path": s("JSON_CONFIG_DIR"), "ok": os.path.isdir(s("JSON_CONFIG_DIR"))},
        "config_file": {"path": s("JSON_CONFIG_FILE"), "ok": os.path.isfile(s("JSON_CONFIG_FILE"))},
        "modes_dir": {"path": s("JSON_MODES_DIR"), "ok": os.path.isdir(s("JSON_MODES_DIR"))},
        "vocab_file": {"path": s("JSON_VOCAB_FILE"), "ok": os.path.isfile(s("JSON_VOCAB_FILE"))},
        "parakeet_dir": {"path": s("JSON_PARAKEET_DIR"), "ok": os.path.isdir(s("JSON_PARAKEET_DIR"))},
        "backend": s("JSON_BACKEND"),
        "whisperd_src": {"path": maybe("JSON_WHISPERD_SRC"), "ok": bool(s("JSON_WHISPERD_SRC")) and os.path.isfile(os.path.join(s("JSON_WHISPERD_SRC"), "Package.swift"))},
        "whisperd_bin": {"path": maybe("JSON_WHISPERD_BIN"), "ok": bool(s("JSON_WHISPERD_BIN")) and os.path.isfile(s("JSON_WHISPERD_BIN")) and os.access(s("JSON_WHISPERD_BIN"), os.X_OK)},
        "whisperd_socket": {"path": maybe("JSON_WHISPERD_SOCKET"), "live": bool(s("JSON_WHISPERD_SOCKET")) and os.path.exists(s("JSON_WHISPERD_SOCKET"))},
        "parakeet_model": {"path": maybe("JSON_PARAKEET_MODEL"), "ok": bool(s("JSON_PARAKEET_MODEL")) and os.path.isdir(s("JSON_PARAKEET_MODEL")), "version": maybe("JSON_PARAKEET_MODEL_VERSION")},
        "raycast_dir": {"path": s("JSON_RAYCAST_DIR"), "ok": os.path.isdir(s("JSON_RAYCAST_DIR"))},
        "backend_model": maybe("JSON_BACKEND_MODEL"),
    },
    "env_overrides": overrides,
    "config": {
        "audio": {
            "source": s("JSON_CFG_AUDIO_SOURCE"),
            "device_name": maybe("JSON_CFG_AUDIO_DEVICE_NAME"),
            "mac_name": maybe("JSON_CFG_AUDIO_MAC_NAME"),
            "iphone_name": maybe("JSON_CFG_AUDIO_IPHONE_NAME"),
            "device_index": to_int("JSON_CFG_AUDIO_DEVICE_INDEX"),
            "silence_trim": to_bool_flag("JSON_CFG_AUDIO_SILENCE_TRIM"),
            "silence_trim_mode": s("JSON_CFG_AUDIO_SILENCE_TRIM_MODE"),
            "silence_threshold_db": to_int("JSON_CFG_AUDIO_SILENCE_THRESHOLD_DB"),
            "silence_min_ms": to_int("JSON_CFG_AUDIO_SILENCE_MIN_MS"),
            "silence_keep_ms": to_int("JSON_CFG_AUDIO_SILENCE_KEEP_MS"),
        },
        "clean": {"repeats_level": to_int("JSON_CFG_CLEAN_REPEATS_LEVEL")},
        "meta": {
            "config_version": s("JSON_CFG_SCHEMA_VERSION"),
            "expected_version": f"v{s('JSON_CFG_SCHEMA_EXPECTED')}",
            "schema_status": s("JSON_CFG_SCHEMA_STATUS"),
            "parse_error": maybe("JSON_CFG_PARSE_ERROR"),
        },
        "backend": "swift_parakeet",
        "swift_parakeet": {
            "model_path": maybe("JSON_CFG_SWIFT_MODEL_PATH"),
            "model_version": maybe("JSON_CFG_SWIFT_MODEL_VERSION"),
            "socket_path": maybe("JSON_CFG_SWIFT_SOCKET_PATH"),
        },
        "postprocess": {
            "enabled": to_bool_flag("JSON_CFG_POSTPROCESS_ENABLED"),
            "llm": maybe("JSON_CFG_POSTPROCESS_LLM"),
            "max_tokens": to_int("JSON_CFG_POSTPROCESS_MAX_TOKENS"),
            "chunk_words": to_int("JSON_CFG_POSTPROCESS_CHUNK_WORDS"),
            "budget_long_words_threshold": to_int("JSON_CFG_POSTPROCESS_BUDGET_THRESHOLD"),
        },
        "inline": {
            "autosend": to_bool_flag("JSON_CFG_INLINE_AUTOSEND"),
            "process_sound": to_bool_flag("JSON_CFG_INLINE_PROCESS_SOUND"),
            "paste_target": maybe("JSON_CFG_INLINE_PASTE_TARGET"),
            "send_mode": maybe("JSON_CFG_INLINE_SEND_MODE"),
        },
        "tmux": {
            "autosend": to_bool_flag("JSON_CFG_TMUX_AUTOSEND"),
            "paste_target": maybe("JSON_CFG_TMUX_PASTE_TARGET"),
            "postprocess": to_bool_flag("JSON_CFG_TMUX_POSTPROCESS"),
            "process_sound": to_bool_flag("JSON_CFG_TMUX_PROCESS_SOUND"),
            "mode": maybe("JSON_CFG_TMUX_MODE"),
            "send_mode": maybe("JSON_CFG_TMUX_SEND_MODE"),
        },
        "debug": {"keep_logs": to_bool_flag("JSON_CFG_DEBUG_KEEP_LOGS")},
    },
    "audio_resolution": {
        "index": to_int("JSON_AUDIO_INDEX"),
        "source": maybe("JSON_AUDIO_SOURCE_RESOLVED"),
        "cache_note": maybe("JSON_AUDIO_CACHE_NOTE"),
    },
    "ffmpeg_devices": maybe("JSON_FFMPEG_DEVICES"),
    "tips": ([] if maybe("JSON_AUDIO_INDEX") is not None else [
        "If microphone device enumeration fails, grant Microphone permission to the launching app in System Settings -> Privacy & Security -> Microphone."
    ]),
}

print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
    return
  fi

  echo "Tmux Whisper debug"
  echo ""

  echo "Binaries:"
  echo "  tmux-whisper: ${dictate_bin:-'(not found)'}"
  echo "  ffmpeg:  ${ffmpeg_bin:-'(not found)'}"
  echo "  python3: ${python_bin:-'(not found)'}"
  echo "  swift:   ${swift_bin:-'(not found)'}"
  echo "  channel: $install_channel"
  echo "  lib:     $DICTATE_LIB_PATH $([[ -r "$DICTATE_LIB_PATH" ]] && echo '(ok)' || echo '(missing)')"
  echo "  internal_lib: $DICTATE_INTERNAL_LIB_DIR $([[ -d "$DICTATE_INTERNAL_LIB_DIR" ]] && echo '(ok)' || echo '(missing)')"
  echo ""

  echo "Paths:"
  echo "  config_dir:   $DICTATE_CONFIG_DIR $([[ -d "$DICTATE_CONFIG_DIR" ]] && echo '(ok)' || echo '(missing)')"
  echo "  config_file:  $DICTATE_CONFIG_FILE $([[ -f "$DICTATE_CONFIG_FILE" ]] && echo '(ok)' || echo '(missing)')"
  echo "  modes_dir:    $DICTATE_CONFIG_DIR/modes $([[ -d "$DICTATE_CONFIG_DIR/modes" ]] && echo '(ok)' || echo '(missing)')"
  echo "  vocab_file:   $DICTATE_CONFIG_DIR/vocab $([[ -f "$DICTATE_CONFIG_DIR/vocab" ]] && echo '(ok)' || echo '(missing)')"
  echo "  parakeet_dir: $swift_models_dir"
  echo "  backend:      $backend_requested"
  echo "  whisperd_src: ${swift_root:-<none>} $([[ -n "$swift_root" && -f "$swift_root/Package.swift" ]] && echo '(ok)' || echo '(missing)')"
  echo "  whisperd_bin: ${swift_binary:-<none>} $([[ -n "$swift_binary" && -x "$swift_binary" ]] && echo "($(tmux_whisperd_binary_state))" || echo '(not built)')"
  echo "  whisperd_sock:${swift_socket_path:-<none>} $([[ -S "$swift_socket_path" ]] && echo '(live)' || echo '(offline)')"
  echo "  parakeet_mod: ${swift_model_path:-<none>} $([[ -n "$swift_model_path" && -d "$swift_model_path" ]] && echo "(ok, ${swift_model_version})" || echo '(missing)')"
  echo "  raycast_dir:  $DICTATE_CONFIG_DIR/integrations/raycast $([[ -d "$DICTATE_CONFIG_DIR/integrations/raycast" ]] && echo '(ok)' || echo '(missing)')"
  echo "  backend_model:${DICTATE_LAST_BACKEND_MODEL:-$(current_transcribe_model_label)}"
  echo ""

  echo "Env overrides:"
  echo "  DICTATE_AUDIO_SOURCE=${DICTATE_AUDIO_SOURCE:-}"
  echo "  DICTATE_AUDIO_INDEX=${DICTATE_AUDIO_INDEX:-}"
  echo "  DICTATE_AUDIO_NAME=${DICTATE_AUDIO_NAME:-}"
  echo "  DICTATE_SILENCE_TRIM=${DICTATE_SILENCE_TRIM:-}"
  echo "  DICTATE_TRIM_WITH_POSTPROCESS=${DICTATE_TRIM_WITH_POSTPROCESS:-}"
  echo "  DICTATE_REPEATS_LEVEL=${DICTATE_REPEATS_LEVEL:-}"
  echo "  DICTATE_REPEATS_WITH_POSTPROCESS=${DICTATE_REPEATS_WITH_POSTPROCESS:-}"
  echo "  DICTATE_POSTPROCESS=${DICTATE_POSTPROCESS:-}"
  echo "  DICTATE_VOCAB_CLEAN=${DICTATE_VOCAB_CLEAN:-}"
  echo "  DICTATE_TMUX_POSTPROCESS=${DICTATE_TMUX_POSTPROCESS:-}"
  echo "  DICTATE_TMUX_AUTOSEND=${DICTATE_TMUX_AUTOSEND:-}"
  echo "  DICTATE_TMUX_PASTE_TARGET=${DICTATE_TMUX_PASTE_TARGET:-}"
  echo "  DICTATE_TMUX_SEND_MODE=${DICTATE_TMUX_SEND_MODE:-}"
  echo "  DICTATE_TMUX_SEND_DELAY_MS=${DICTATE_TMUX_SEND_DELAY_MS:-}"
  echo "  DICTATE_TMUX_CODEX_TAB_DELAY_MS=${DICTATE_TMUX_CODEX_TAB_DELAY_MS:-}"
  echo "  DICTATE_INLINE_PROCESS_SOUND=${DICTATE_INLINE_PROCESS_SOUND:-}"
  echo "  DICTATE_INLINE_PASTE_TARGET=${DICTATE_INLINE_PASTE_TARGET:-}"
  echo "  DICTATE_INLINE_ACTIVATE_DELAY_MS=${DICTATE_INLINE_ACTIVATE_DELAY_MS:-}"
  echo "  DICTATE_INLINE_SEND_DELAY_MS=${DICTATE_INLINE_SEND_DELAY_MS:-}"
  echo "  DICTATE_INLINE_SEND_MODE=${DICTATE_INLINE_SEND_MODE:-}"
  echo "  DICTATE_TMUX_PROCESS_SOUND=${DICTATE_TMUX_PROCESS_SOUND:-}"
  echo "  DICTATE_TMUX_MODE=${DICTATE_TMUX_MODE:-}"
  echo "  DICTATE_SWIFT_PARAKEET_MODEL_PATH=${DICTATE_SWIFT_PARAKEET_MODEL_PATH:-}"
  echo "  DICTATE_SWIFT_PARAKEET_MODEL_VERSION=${DICTATE_SWIFT_PARAKEET_MODEL_VERSION:-}"
  echo "  DICTATE_SWIFT_PARAKEET_SOCKET_PATH=${DICTATE_SWIFT_PARAKEET_SOCKET_PATH:-}"
  echo "  DICTATE_LLM_MAX_TOKENS=${DICTATE_LLM_MAX_TOKENS:-}"
  echo "  DICTATE_LLM_CHUNK_WORDS=${DICTATE_LLM_CHUNK_WORDS:-}"
  echo "  DICTATE_BRITISH_SPELLING=${DICTATE_BRITISH_SPELLING:-}"
  echo "  DICTATE_KEEP_LOGS=${DICTATE_KEEP_LOGS:-}"
  echo "  DICTATE_TARGET_APP=${DICTATE_TARGET_APP:-}"
  echo "  DICTATE_TARGET_PANE=${DICTATE_TARGET_PANE:-}"
  echo ""

  echo "Config:"
  echo "  audio.source=${CFG_AUDIO_SOURCE:-auto}"
  echo "  audio.device_name=${CFG_AUDIO_DEVICE_NAME:-}"
  echo "  audio.mac_name=${CFG_AUDIO_MAC_NAME:-}"
  echo "  audio.iphone_name=${CFG_AUDIO_IPHONE_NAME:-}"
  echo "  audio.device_index=${CFG_AUDIO_DEVICE_INDEX:-}"
  echo "  audio.silence_trim=${CFG_AUDIO_SILENCE_TRIM:-0}"
  echo "  audio.silence_trim_mode=${CFG_AUDIO_SILENCE_TRIM_MODE:-edges}"
  echo "  audio.silence_threshold_db=${CFG_AUDIO_SILENCE_THRESHOLD_DB:--60}"
  echo "  audio.silence_min_ms=${CFG_AUDIO_SILENCE_MIN_MS:-250}"
  echo "  audio.silence_keep_ms=${CFG_AUDIO_SILENCE_KEEP_MS:-50}"
  echo "  clean.repeats_level=${CFG_CLEAN_REPEATS_LEVEL:-1}"
  echo "  meta.config_version=${cfg_schema_version} (expected v${DICTATE_CONFIG_SCHEMA_VERSION}, status=${cfg_schema_status})"
  [[ -n "$cfg_parse_error" ]] && echo "  meta.config_parse_error=${cfg_parse_error}"
  [[ -n "$cfg_parse_error" ]] && echo "  meta.config_source=${CFG_CONFIG_SOURCE:-defaults} (settings in use)"
  echo "  backend=swift_parakeet"
  echo "  swift_parakeet.model_path=${CFG_SWIFT_PARAKEET_MODEL_PATH:-}"
  echo "  swift_parakeet.model_version=${CFG_SWIFT_PARAKEET_MODEL_VERSION:-}"
  echo "  swift_parakeet.socket_path=${CFG_SWIFT_PARAKEET_SOCKET_PATH:-$DICTATE_CONFIG_DIR/.cache/tmux-whisperd.sock}"
  echo "  postprocess.enabled=${CFG_POSTPROCESS_ENABLED:-0}"
  echo "  postprocess.llm=${CFG_POSTPROCESS_LLM:-}"
  echo "  postprocess.max_tokens=${CFG_POSTPROCESS_MAX_TOKENS:-}"
  echo "  postprocess.chunk_words=${CFG_POSTPROCESS_CHUNK_WORDS:-}"
  echo "  postprocess.budget_long_words_threshold=${CFG_POSTPROCESS_BUDGET_LONG_WORDS_THRESHOLD:-120}"
  echo "  inline.autosend=${CFG_INLINE_AUTOSEND:-1}"
  echo "  inline.process_sound=${CFG_INLINE_PROCESS_SOUND:-1}"
  echo "  inline.paste_target=$(inline_paste_target_label "${CFG_INLINE_PASTE_TARGET:-restore}")"
  echo "  inline.send_mode=$(inline_send_mode_label "${CFG_INLINE_SEND_MODE:-enter}")"
  echo "  tmux.autosend=${CFG_TMUX_AUTOSEND:-1}"
  echo "  tmux.paste_target=${CFG_TMUX_PASTE_TARGET:-origin}"
  echo "  tmux.postprocess=${CFG_TMUX_POSTPROCESS:-0}"
  echo "  tmux.process_sound=${CFG_TMUX_PROCESS_SOUND:-0}"
  echo "  tmux.mode=${CFG_TMUX_MODE:-code}"
  echo "  tmux.send_mode=${CFG_TMUX_SEND_MODE:-auto}"
  echo "  debug.keep_logs=${CFG_DEBUG_KEEP_LOGS:-0}"
  echo ""

  echo "ffmpeg devices (trimmed):"
  if [[ -n "$ffmpeg_bin" ]]; then
    printf '%s\n' "$ffmpeg_devices_output"
  else
    echo "  ffmpeg not found; skipping device enumeration."
  fi
  echo ""

  echo "Resolved audio index: ${idx:-<none>} (source: $src)"
  [[ -n "$audio_cache_note" ]] && echo "Audio cache note: $audio_cache_note"
  if [[ -z "$idx" ]]; then
    echo ""
    echo "Tip: If you see 'Input/output error' above, macOS is blocking device access for the app launching ffmpeg."
    echo "Grant Microphone permission to that app (System Settings → Privacy & Security → Microphone)."
  fi
}

doctor_mode_count_for_flow() {
  local flow="${1:-}"
  local count="0"
  while IFS= read -r _mode_name; do
    [[ -n "$_mode_name" ]] || continue
    count=$((count + 1))
  done < <(list_modes "$flow")
  printf '%s\n' "$count"
}

doctor_mode_seed_for_flow() {
  local flow="${1:-}"
  case "$flow" in
    inline)
      if mode_exists "base"; then
        echo "base"
        return 0
      fi
      if mode_exists "code"; then
        echo "code"
        return 0
      fi
      ;;
    tmux)
      if mode_exists "code"; then
        echo "code"
        return 0
      fi
      if mode_exists "base"; then
        echo "base"
        return 0
      fi
      ;;
  esac

  local first_mode=""
  first_mode="$(list_modes "" | head -n 1)"
  [[ -n "$first_mode" ]] && printf '%s\n' "$first_mode"
}

doctor_mode_flow_fix_suggestion() {
  local mode required_flow flow_spec
  mode="$(canonical_mode_name "${1:-}")"
  required_flow="${2:-}"
  [[ -n "$mode" && -n "$required_flow" ]] || return 1
  flow_spec="$(mode_recommended_flow_spec "$mode" "$required_flow")"
  printf "Enable %s flow for '%s': tmux-whisper mode flows %s %s\n" "$required_flow" "$mode" "$mode" "$flow_spec"
}

doctor_mode_inventory_tsv() {
  local mode_name mode_label mode_dir prompt_path prompt_status
  local flows_file flows_summary flows_explicit invalid_entries
  local inline_enabled tmux_enabled apps_file apps_count apps_ignored
  local sep=$'\x1f'

  while IFS= read -r mode_name; do
    [[ -n "$mode_name" ]] || continue
    mode_label="$(mode_display_name "$mode_name")"
    mode_dir="$(mode_dir_path "$mode_name")"
    prompt_path="$mode_dir/prompt"
    if [[ -s "$prompt_path" ]]; then
      prompt_status="ok"
    elif [[ -f "$prompt_path" ]]; then
      prompt_status="empty"
    else
      prompt_status="missing"
    fi

    flows_file="$(mode_flows_file_path "$mode_name")"
    flows_summary="$(mode_flow_summary "$mode_name")"
    flows_explicit="0"
    [[ -f "$flows_file" ]] && flows_explicit="1"
    invalid_entries="$(mode_invalid_flow_entries "$mode_name" | paste -sd ',' - 2>/dev/null || true)"

    inline_enabled="0"
    tmux_enabled="0"
    mode_allows_flow "$mode_name" "inline" && inline_enabled="1"
    mode_allows_flow "$mode_name" "tmux" && tmux_enabled="1"

    apps_file="$(mode_apps_file_path "$mode_name")"
    apps_count="$(mode_app_entry_count "$mode_name")"
    apps_ignored="0"
    if [[ "$apps_count" =~ ^[0-9]+$ ]] && (( apps_count > 0 )) && [[ "$inline_enabled" != "1" ]]; then
      apps_ignored="1"
    fi

    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
      "$mode_name" "$sep" "$mode_label" "$sep" "$prompt_status" "$sep" "$prompt_path" "$sep" \
      "$flows_summary" "$sep" "$inline_enabled" "$sep" "$tmux_enabled" "$sep" "$flows_file" "$sep" "$flows_explicit" "$sep" \
      "${invalid_entries:-}" "$sep" "$apps_file" "$sep" "$apps_count" "$sep" "$apps_ignored"
  done < <(list_modes "")
}

doctor_json() {
  load_backend_runtime_cache >/dev/null 2>&1 || true

  local issues=0
  local warnings=0
  local suggestions=()

  doctor_json_add_suggestion() {
    local suggestion="${1:-}"
    [[ -n "$suggestion" ]] || return 0
    local existing
    for existing in "${suggestions[@]-}"; do
      [[ "$existing" == "$suggestion" ]] && return 0
    done
    suggestions+=("$suggestion")
  }

  local dependency_lines=""
  local dep_path=""
  dep_path="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$dep_path" ]]; then
    dependency_lines="${dependency_lines}python3	required	ok	${dep_path}"$'\n'
  else
    dependency_lines="${dependency_lines}python3	required	missing	"$'\n'
    issues=$((issues + 1))
    doctor_json_add_suggestion "Install python3: brew install python"
  fi
  dep_path="$(command -v ffmpeg 2>/dev/null || true)"
  if [[ -n "$dep_path" ]]; then
    dependency_lines="${dependency_lines}ffmpeg	required	ok	${dep_path}"$'\n'
  else
    dependency_lines="${dependency_lines}ffmpeg	required	missing	"$'\n'
    issues=$((issues + 1))
    doctor_json_add_suggestion "Install ffmpeg: brew install ffmpeg"
  fi
  dep_path="$(command -v tmux 2>/dev/null || true)"
  if [[ -n "$dep_path" ]]; then
    dependency_lines="${dependency_lines}tmux	optional	ok	${dep_path}"$'\n'
  else
    dependency_lines="${dependency_lines}tmux	optional	missing	"$'\n'
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Install tmux (optional, recommended): brew install tmux"
  fi
  dep_path="$(command -v swift 2>/dev/null || true)"
  if [[ -n "$dep_path" ]]; then
    dependency_lines="${dependency_lines}swift	optional	ok	${dep_path}"$'\n'
  else
    dependency_lines="${dependency_lines}swift	optional	missing	"$'\n'
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Install Swift/Xcode so tmux-whisperd can be built"
  fi

  local dictate_bin install_channel
  dictate_bin="$(resolve_running_tmux_whisper_bin)"
  install_channel="$(detect_install_channel "$dictate_bin")"
  [[ -n "$dictate_bin" ]] || {
    issues=$((issues + 1))
    doctor_json_add_suggestion "Install Tmux Whisper from this repo: ./install.sh --force"
  }

  local shared_lib_ok="0" internal_lib_ok="0" config_file_ok="0" raycast_inline_ok="0"
  [[ -r "$DICTATE_LIB_PATH" ]] && shared_lib_ok="1"
  if [[ "$shared_lib_ok" != "1" ]]; then
    issues=$((issues + 1))
    doctor_json_add_suggestion "Repair Tmux Whisper install: ./install.sh --force"
  fi
  if [[ -r "$DICTATE_INTERNAL_LIB_DIR/history.sh" && -r "$DICTATE_INTERNAL_LIB_DIR/diagnostics.sh" ]]; then
    internal_lib_ok="1"
  else
    issues=$((issues + 1))
    doctor_json_add_suggestion "Repair internal runtime modules: ./install.sh --force"
  fi
  if [[ -f "$DICTATE_CONFIG_FILE" ]]; then
    config_file_ok="1"
  else
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Create default config: tmux-whisper config repair"
  fi
  local cfg_schema_status cfg_schema_version cfg_parse_error
  cfg_schema_status="$(config_schema_status)"
  cfg_schema_version="$(config_schema_version_label)"
  cfg_parse_error="${CFG_CONFIG_PARSE_ERROR:-}"
  case "$cfg_schema_status" in
    mismatch|invalid)
      issues=$((issues + 1))
      doctor_json_add_suggestion "Preview config repair: tmux-whisper config repair --dry-run"
      doctor_json_add_suggestion "Repair config in place: tmux-whisper config repair"
      ;;
  esac
  local raycast_inline_path
  raycast_inline_path="$DICTATE_CONFIG_DIR/integrations/raycast/tmux-whisper-inline.sh"
  [[ -f "$raycast_inline_path" ]] && raycast_inline_ok="1"

  local swift_root swift_binary swift_socket_path swift_model_path swift_model_version swift_models_dir
  swift_root="$(resolve_tmux_whisperd_root 2>/dev/null || true)"
  swift_binary="${DICTATE_TMUX_WHISPERD_BIN:-${swift_root:+$(tmux_whisperd_build_root)/.build/release/tmux-whisperd}}"
  swift_socket_path="$(resolve_swift_parakeet_socket_path)"
  swift_model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  swift_model_version="$(resolve_swift_parakeet_model_version "${swift_model_path:-}")"
  swift_models_dir="$(expand_path "$DEFAULT_SWIFT_PARAKEET_MODELS_DIR")"
  local swift_root_ok="0" swift_binary_ok="0" swift_socket_live="0" swift_model_ok="0"
  [[ -n "$swift_root" ]] && swift_root_ok="1"
  if [[ "$swift_root_ok" != "1" ]]; then
    issues=$((issues + 1))
    doctor_json_add_suggestion "Reinstall native backend sources: ./install.sh --force"
  fi
  [[ -n "$swift_binary" && -x "$swift_binary" ]] && swift_binary_ok="1"
  if [[ -z "$(command -v swift 2>/dev/null || true)" && "$swift_binary_ok" != "1" ]]; then
    issues=$((issues + 1))
    doctor_json_add_suggestion "Install Swift/Xcode so tmux-whisperd can be built"
  fi
  [[ -S "$swift_socket_path" ]] && swift_socket_live="1"
  [[ -n "$swift_model_path" && -d "$swift_model_path" ]] && swift_model_ok="1"
  if [[ "$swift_model_ok" != "1" ]]; then
    issues=$((issues + 1))
    doctor_json_add_suggestion "Set swift_parakeet.model_path in ~/.config/dictate/config.toml to your local CoreML Parakeet model directory"
  elif [[ "$swift_model_path" == "$HOME/Library/Application Support/FluidAudio/Models/"* ]]; then
    doctor_json_add_suggestion "Move or copy the Parakeet model into $swift_models_dir so tmux-whisper does not depend on Spokenly/FluidAudio being installed"
  fi

  local mode_inventory_lines=""
  local mode_total_count inline_mode_count tmux_mode_count any_modes_present
  local mode_line
  mode_inventory_lines="$(doctor_mode_inventory_tsv)"
  mode_total_count="$(doctor_mode_count_for_flow "")"
  inline_mode_count="$(doctor_mode_count_for_flow "inline")"
  tmux_mode_count="$(doctor_mode_count_for_flow "tmux")"
  any_modes_present="0"
  [[ -n "${mode_inventory_lines//[[:space:]]/}" ]] && any_modes_present="1"

  while IFS= read -r mode_line; do
    [[ -n "$mode_line" ]] || continue
    local inv_mode inv_label inv_prompt_status inv_prompt_path inv_flows_summary
    local inv_inline_enabled inv_tmux_enabled inv_flows_path inv_flows_explicit inv_invalid_entries
    local inv_apps_path inv_apps_count inv_apps_ignored
    IFS=$'\x1f' read -r inv_mode inv_label inv_prompt_status inv_prompt_path inv_flows_summary \
      inv_inline_enabled inv_tmux_enabled inv_flows_path inv_flows_explicit inv_invalid_entries \
      inv_apps_path inv_apps_count inv_apps_ignored <<<"$mode_line"

    case "$inv_prompt_status" in
      empty|missing)
        warnings=$((warnings + 1))
        doctor_json_add_suggestion "Populate $inv_label prompt: tmux-whisper mode edit $inv_label"
        ;;
    esac

    if [[ -n "$inv_invalid_entries" ]]; then
      warnings=$((warnings + 1))
      doctor_json_add_suggestion "Review flow filter for '$inv_mode': tmux-whisper mode flows $inv_mode"
      if [[ "$inv_inline_enabled" != "1" && "$inv_apps_count" =~ ^[0-9]+$ && "$inv_apps_count" -gt 0 ]]; then
        doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$inv_mode" "inline")"
      elif [[ "$inv_tmux_enabled" != "1" && "${CFG_TMUX_MODE:-code}" == "$inv_mode" ]]; then
        doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$inv_mode" "tmux")"
      fi
    fi

    if [[ "$inv_apps_ignored" == "1" ]]; then
      warnings=$((warnings + 1))
      doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$inv_mode" "inline")"
    fi
  done <<<"$mode_inventory_lines"

  if [[ "$any_modes_present" != "1" ]]; then
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Repair mode defaults: ./install.sh --force"
  elif [[ "$inline_mode_count" -eq 0 ]]; then
    warnings=$((warnings + 1))
    local inline_seed_mode=""
    inline_seed_mode="$(doctor_mode_seed_for_flow "inline")"
    if [[ -n "$inline_seed_mode" ]]; then
      doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$inline_seed_mode" "inline")"
    else
      doctor_json_add_suggestion "Repair mode defaults: ./install.sh --force"
    fi
  fi
  if [[ "$any_modes_present" == "1" && "$tmux_mode_count" -eq 0 ]]; then
    warnings=$((warnings + 1))
    local tmux_seed_mode=""
    tmux_seed_mode="$(doctor_mode_seed_for_flow "tmux")"
    if [[ -n "$tmux_seed_mode" ]]; then
      doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$tmux_seed_mode" "tmux")"
    else
      doctor_json_add_suggestion "Repair mode defaults: ./install.sh --force"
    fi
  fi

  local inline_mode_requested inline_mode_effective inline_mode_source inline_mode_status
  local inline_mode_requested_exists="0" inline_mode_flow_allowed="0"
  if [[ -f "$MODE_FILE" ]]; then
    inline_mode_requested="$(head -n 1 "$MODE_FILE" 2>/dev/null | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  else
    inline_mode_requested="auto"
  fi
  if [[ -z "$inline_mode_requested" ]]; then
    inline_mode_effective="$(default_inline_mode)"
    inline_mode_source="fixed"
    inline_mode_status="invalid_empty"
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Set inline mode policy: tmux-whisper mode auto"
  elif [[ "$inline_mode_requested" == "auto" ]]; then
    inline_mode_effective="$(get_current_mode 2>/dev/null || true)"
    [[ -n "$inline_mode_effective" ]] || inline_mode_effective="$(default_inline_mode)"
    inline_mode_source="auto"
    if [[ "$inline_mode_count" -gt 0 ]]; then
      inline_mode_status="ok"
    else
      inline_mode_status="no_inline_modes"
    fi
  elif mode_exists "$inline_mode_requested"; then
    inline_mode_effective="$(canonical_mode_name "$inline_mode_requested")"
    inline_mode_source="fixed"
    inline_mode_requested_exists="1"
    if mode_allows_flow "$inline_mode_effective" "inline"; then
      inline_mode_status="ok"
      inline_mode_flow_allowed="1"
    else
      inline_mode_effective="$(default_inline_mode)"
      inline_mode_status="flow_disabled"
      warnings=$((warnings + 1))
      doctor_json_add_suggestion "Set inline mode policy: tmux-whisper mode auto"
      doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$inline_mode_requested" "inline")"
    fi
  else
    inline_mode_effective="$(default_inline_mode)"
    inline_mode_source="fixed"
    inline_mode_status="invalid"
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Set inline mode policy: tmux-whisper mode auto"
    doctor_json_add_suggestion "Or create the missing mode: tmux-whisper mode create \"$inline_mode_requested\""
  fi

  local tmux_mode_requested tmux_mode_effective tmux_mode_status
  local tmux_mode_requested_exists="0" tmux_mode_flow_allowed="0"
  tmux_mode_requested="${DICTATE_TMUX_MODE:-${CFG_TMUX_MODE:-code}}"
  tmux_mode_effective="$(canonical_mode_name "$tmux_mode_requested")"
  if mode_exists "$tmux_mode_effective"; then
    tmux_mode_requested_exists="1"
    if mode_allows_flow "$tmux_mode_effective" "tmux"; then
      tmux_mode_status="ok"
      tmux_mode_flow_allowed="1"
    else
      tmux_mode_status="flow_disabled"
      warnings=$((warnings + 1))
      doctor_json_add_suggestion "Set tmux mode to a valid mode: tmux-whisper tmux mode code"
      doctor_json_add_suggestion "$(doctor_mode_flow_fix_suggestion "$tmux_mode_effective" "tmux")"
    fi
  else
    tmux_mode_status="invalid"
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Set tmux mode to a valid mode: tmux-whisper tmux mode code"
  fi

  local state_tmux_summary state_inline_summary stale_state_paths=""
  state_tmux_summary="$(state_file_summary_tsv tmux "$STATE_FILE")"
  state_inline_summary="$(state_file_summary_tsv inline "$INLINE_STATE_FILE")"
  local state_status
  IFS=$'\t' read -r state_status _ <<<"$state_tmux_summary"
  if [[ "$state_status" == "stale" ]]; then
    warnings=$((warnings + 1))
    stale_state_paths="${stale_state_paths}${STATE_FILE}"$'\n'
  fi
  IFS=$'\t' read -r state_status _ <<<"$state_inline_summary"
  if [[ "$state_status" == "stale" ]]; then
    warnings=$((warnings + 1))
    stale_state_paths="${stale_state_paths}${INLINE_STATE_FILE}"$'\n'
  fi
  if [[ -n "$stale_state_paths" ]]; then
    doctor_json_add_suggestion "Clean stale state files: rm -f ${stale_state_paths//$'\n'/ }"
  fi

  local proc_dir="${DICTATE_PROCESSING_DIR:-/tmp/dictate-processing}"
  local proc_total=0
  local proc_live=0
  local proc_stale=0
  if [[ -d "$proc_dir" ]]; then
    local pf marker_pid line
    for pf in "$proc_dir"/*; do
      [[ -f "$pf" ]] || continue
      proc_total=$((proc_total + 1))
      marker_pid=""
      line="$(head -n 1 "$pf" 2>/dev/null || true)"
      if [[ "$line" =~ ^pid=([0-9]+)$ ]]; then
        marker_pid="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[0-9]+$ ]]; then
        marker_pid="$line"
      fi
      if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null; then
        proc_live=$((proc_live + 1))
      else
        proc_stale=$((proc_stale + 1))
      fi
    done
  fi
  if [[ "$proc_stale" -gt 0 ]]; then
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Clean stale processing markers: rm -rf $proc_dir"
  fi

  local tmux_total=0
  local tmux_rec=0
  local tmux_proc=0
  local tmux_stale=0
  local jf st marker_pid now mtime age
  now="$(date +%s)"
  if [[ -d "$TMUX_JOBS_DIR" ]]; then
    for jf in "$TMUX_JOBS_DIR"/*; do
      [[ -f "$jf" ]] || continue
      st="$(sed -n 's/^status=//p' "$jf" 2>/dev/null | head -n 1 || true)"
      marker_pid="$(sed -n 's/^pid=//p' "$jf" 2>/dev/null | head -n 1 || true)"
      mtime="$(stat -f %m "$jf" 2>/dev/null || true)"
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(stat -c %Y "$jf" 2>/dev/null || true)"
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
      age=$((now - mtime))
      case "$st" in
        recording|processing)
          if [[ -z "$marker_pid" || ! "$marker_pid" =~ ^[0-9]+$ ]]; then
            warnings=$((warnings + 1))
            tmux_stale=$((tmux_stale + 1))
            doctor_json_add_suggestion "Clean stale tmux job markers: rm -rf $TMUX_JOBS_DIR"
            continue
          fi
          if ! kill -0 "$marker_pid" 2>/dev/null; then
            warnings=$((warnings + 1))
            tmux_stale=$((tmux_stale + 1))
            doctor_json_add_suggestion "Clean stale tmux job markers: rm -rf $TMUX_JOBS_DIR"
            continue
          fi
          ;;
      esac
      tmux_total=$((tmux_total + 1))
      case "$st" in
        recording) tmux_rec=$((tmux_rec + 1)) ;;
        processing) tmux_proc=$((tmux_proc + 1)) ;;
      esac
    done
  fi

  local summary_status
  if [[ "$issues" -eq 0 && "$warnings" -eq 0 ]]; then
    summary_status="healthy"
  elif [[ "$issues" -eq 0 ]]; then
    summary_status="ok with warnings"
  else
    summary_status="needs attention"
  fi

  local suggestions_blob=""
  if [[ "${#suggestions[@]}" -gt 0 ]]; then
    suggestions_blob="$(printf '%s\n' "${suggestions[@]}")"
  fi

  env \
    JSON_STATE_FILE_PATH="$STATE_FILE" \
    JSON_INLINE_STATE_FILE_PATH="$INLINE_STATE_FILE" \
    JSON_DEPENDENCIES="$dependency_lines" \
    JSON_INSTALL_TMUX_WHISPER="$dictate_bin" \
    JSON_INSTALL_CHANNEL="$install_channel" \
    JSON_SHARED_LIB_PATH="$DICTATE_LIB_PATH" \
    JSON_SHARED_LIB_OK="$shared_lib_ok" \
    JSON_INTERNAL_LIB_DIR="$DICTATE_INTERNAL_LIB_DIR" \
    JSON_INTERNAL_LIB_OK="$internal_lib_ok" \
    JSON_CONFIG_FILE="$DICTATE_CONFIG_FILE" \
    JSON_CONFIG_FILE_OK="$config_file_ok" \
    JSON_CONFIG_SCHEMA_VERSION="$cfg_schema_version" \
    JSON_CONFIG_SCHEMA_EXPECTED="v$DICTATE_CONFIG_SCHEMA_VERSION" \
    JSON_CONFIG_SCHEMA_STATUS="$cfg_schema_status" \
    JSON_CONFIG_SCHEMA_PARSE_ERROR="$cfg_parse_error" \
    JSON_RAYCAST_INLINE_PATH="$raycast_inline_path" \
    JSON_RAYCAST_INLINE_OK="$raycast_inline_ok" \
    JSON_BACKEND="swift_parakeet" \
    JSON_TMUX_WHISPERD_SOURCE="$swift_root" \
    JSON_TMUX_WHISPERD_SOURCE_OK="$swift_root_ok" \
    JSON_TMUX_WHISPERD_BIN="$swift_binary" \
    JSON_TMUX_WHISPERD_BIN_OK="$swift_binary_ok" \
    JSON_TMUX_WHISPERD_SOCKET="$swift_socket_path" \
    JSON_TMUX_WHISPERD_SOCKET_LIVE="$swift_socket_live" \
    JSON_PARAKEET_DIR="$swift_models_dir" \
    JSON_PARAKEET_MODEL="$swift_model_path" \
    JSON_PARAKEET_MODEL_OK="$swift_model_ok" \
    JSON_PARAKEET_MODEL_VERSION="$swift_model_version" \
    JSON_MODE_INLINE_REQUESTED="$inline_mode_requested" \
    JSON_MODE_INLINE_EFFECTIVE="$inline_mode_effective" \
    JSON_MODE_INLINE_DISPLAY="$(mode_display_name "$inline_mode_effective")" \
    JSON_MODE_INLINE_SOURCE="$inline_mode_source" \
    JSON_MODE_INLINE_STATUS="$inline_mode_status" \
    JSON_MODE_INLINE_REQUESTED_EXISTS="$inline_mode_requested_exists" \
    JSON_MODE_INLINE_FLOW_ALLOWED="$inline_mode_flow_allowed" \
    JSON_MODE_TMUX_REQUESTED="$tmux_mode_requested" \
    JSON_MODE_TMUX_EFFECTIVE="$tmux_mode_effective" \
    JSON_MODE_TMUX_DISPLAY="$(mode_display_name "$tmux_mode_effective")" \
    JSON_MODE_TMUX_STATUS="$tmux_mode_status" \
    JSON_MODE_TMUX_REQUESTED_EXISTS="$tmux_mode_requested_exists" \
    JSON_MODE_TMUX_FLOW_ALLOWED="$tmux_mode_flow_allowed" \
    JSON_MODE_INVENTORY="$mode_inventory_lines" \
    JSON_MODE_TOTAL_COUNT="$mode_total_count" \
    JSON_MODE_INLINE_COUNT="$inline_mode_count" \
    JSON_MODE_TMUX_COUNT="$tmux_mode_count" \
    JSON_ANY_MODES_PRESENT="$any_modes_present" \
    JSON_STATE_TMUX="$state_tmux_summary" \
    JSON_STATE_INLINE="$state_inline_summary" \
    JSON_STALE_STATE_FILES="$stale_state_paths" \
    JSON_PROC_DIR="$proc_dir" \
    JSON_PROC_TOTAL="$proc_total" \
    JSON_PROC_LIVE="$proc_live" \
    JSON_PROC_STALE="$proc_stale" \
    JSON_TMUX_JOBS_DIR="$TMUX_JOBS_DIR" \
    JSON_TMUX_TOTAL="$tmux_total" \
    JSON_TMUX_RECORDING="$tmux_rec" \
    JSON_TMUX_PROCESSING="$tmux_proc" \
    JSON_TMUX_STALE="$tmux_stale" \
    JSON_ISSUES="$issues" \
    JSON_WARNINGS="$warnings" \
    JSON_SUMMARY_STATUS="$summary_status" \
    JSON_SUGGESTIONS="$suggestions_blob" \
    python3 - <<'PYEOF'
import json
import os

def s(name: str) -> str:
    return os.environ.get(name, "")

def maybe(name: str):
    value = s(name)
    return value if value else None

def to_int(name: str):
    value = s(name)
    try:
        return int(value)
    except Exception:
        return None

def to_bool_flag(name: str) -> bool:
    return s(name) == "1"

def parse_state(line: str, path_name: str):
    cols = line.split("\t") if line else []
    cols += [""] * (7 - len(cols))
    state, pid, age, display, model, language, raw_target = cols[:7]
    parsed_age = None
    try:
        parsed_age = int(age)
    except Exception:
        parsed_age = None
    return {
        "path": path_name,
        "state": state or "idle",
        "pid": int(pid) if pid.isdigit() else None,
        "age_seconds": parsed_age,
        "display_target": display or None,
        "model": model or None,
        "language": language or None,
        "raw_target": raw_target or None,
        "active": (state == "active"),
        "stale": (state == "stale"),
    }

dependencies = {}
for line in s("JSON_DEPENDENCIES").splitlines():
    if not line:
        continue
    name, kind, status, path = (line.split("\t") + ["", "", "", ""])[:4]
    dependencies[name] = {
        "required": kind == "required",
        "status": status,
        "found": status == "ok",
        "path": path or None,
    }

mode_inventory = []
for line in s("JSON_MODE_INVENTORY").splitlines():
    if not line:
        continue
    cols = line.split("\x1f")
    cols += [""] * (13 - len(cols))
    (
        mode,
        label,
        prompt_status,
        prompt_path,
        flows_summary,
        inline_enabled,
        tmux_enabled,
        flows_path,
        flows_explicit,
        invalid_entries,
        apps_path,
        apps_count,
        apps_ignored,
    ) = cols[:13]
    try:
        parsed_apps_count = int(apps_count)
    except Exception:
        parsed_apps_count = 0
    invalid_entry_list = [entry for entry in invalid_entries.split(",") if entry]
    mode_inventory.append(
        {
            "mode": mode,
            "label": label,
            "prompt": {
                "status": prompt_status,
                "path": prompt_path or None,
            },
            "flows": {
                "summary": flows_summary,
                "path": flows_path or None,
                "explicit": flows_explicit == "1",
                "inline_enabled": inline_enabled == "1",
                "tmux_enabled": tmux_enabled == "1",
                "invalid_entries": invalid_entry_list,
            },
            "apps": {
                "path": apps_path or None,
                "count": parsed_apps_count,
                "ignored": apps_ignored == "1",
            },
        }
    )

data = {
    "command": "doctor",
    "dependencies": dependencies,
    "install_sanity": {
        "tmux_whisper_binary": maybe("JSON_INSTALL_TMUX_WHISPER"),
        "install_channel": s("JSON_INSTALL_CHANNEL"),
        "shared_library": {"path": s("JSON_SHARED_LIB_PATH"), "ok": to_bool_flag("JSON_SHARED_LIB_OK")},
        "internal_library_dir": {"path": s("JSON_INTERNAL_LIB_DIR"), "ok": to_bool_flag("JSON_INTERNAL_LIB_OK")},
        "config_file": {"path": s("JSON_CONFIG_FILE"), "ok": to_bool_flag("JSON_CONFIG_FILE_OK")},
        "config_schema": {
            "version": s("JSON_CONFIG_SCHEMA_VERSION"),
            "expected": s("JSON_CONFIG_SCHEMA_EXPECTED"),
            "status": s("JSON_CONFIG_SCHEMA_STATUS"),
            "parse_error": maybe("JSON_CONFIG_SCHEMA_PARSE_ERROR"),
        },
        "raycast_inline": {"path": s("JSON_RAYCAST_INLINE_PATH"), "ok": to_bool_flag("JSON_RAYCAST_INLINE_OK")},
        "backend": s("JSON_BACKEND"),
        "tmux_whisperd_source": {"path": maybe("JSON_TMUX_WHISPERD_SOURCE"), "ok": to_bool_flag("JSON_TMUX_WHISPERD_SOURCE_OK")},
        "tmux_whisperd_binary": {"path": maybe("JSON_TMUX_WHISPERD_BIN"), "ok": to_bool_flag("JSON_TMUX_WHISPERD_BIN_OK")},
        "tmux_whisperd_socket": {"path": maybe("JSON_TMUX_WHISPERD_SOCKET"), "live": to_bool_flag("JSON_TMUX_WHISPERD_SOCKET_LIVE")},
        "preferred_parakeet_dir": s("JSON_PARAKEET_DIR"),
        "parakeet_model": {
            "path": maybe("JSON_PARAKEET_MODEL"),
            "ok": to_bool_flag("JSON_PARAKEET_MODEL_OK"),
            "version": maybe("JSON_PARAKEET_MODEL_VERSION"),
        },
    },
    "mode_config": {
        "available": {
            "total": to_int("JSON_MODE_TOTAL_COUNT") or 0,
            "inline_count": to_int("JSON_MODE_INLINE_COUNT") or 0,
            "tmux_count": to_int("JSON_MODE_TMUX_COUNT") or 0,
        },
        "inline": {
            "requested": maybe("JSON_MODE_INLINE_REQUESTED"),
            "effective": maybe("JSON_MODE_INLINE_EFFECTIVE"),
            "effective_display": maybe("JSON_MODE_INLINE_DISPLAY"),
            "source": s("JSON_MODE_INLINE_SOURCE"),
            "status": s("JSON_MODE_INLINE_STATUS"),
            "requested_exists": to_bool_flag("JSON_MODE_INLINE_REQUESTED_EXISTS"),
            "flow_allowed": to_bool_flag("JSON_MODE_INLINE_FLOW_ALLOWED"),
        },
        "tmux": {
            "requested": maybe("JSON_MODE_TMUX_REQUESTED"),
            "effective": maybe("JSON_MODE_TMUX_EFFECTIVE"),
            "effective_display": maybe("JSON_MODE_TMUX_DISPLAY"),
            "status": s("JSON_MODE_TMUX_STATUS"),
            "requested_exists": to_bool_flag("JSON_MODE_TMUX_REQUESTED_EXISTS"),
            "flow_allowed": to_bool_flag("JSON_MODE_TMUX_FLOW_ALLOWED"),
        },
        "modes_present": s("JSON_ANY_MODES_PRESENT") == "1",
        "modes": mode_inventory,
    },
    "state_files": {
        "tmux": parse_state(s("JSON_STATE_TMUX"), s("JSON_STATE_FILE_PATH")),
        "inline": parse_state(s("JSON_STATE_INLINE"), s("JSON_INLINE_STATE_FILE_PATH")),
        "stale_paths": [line for line in s("JSON_STALE_STATE_FILES").splitlines() if line],
    },
    "processing_markers": {
        "path": s("JSON_PROC_DIR"),
        "total": to_int("JSON_PROC_TOTAL") or 0,
        "live": to_int("JSON_PROC_LIVE") or 0,
        "stale": to_int("JSON_PROC_STALE") or 0,
    },
    "tmux_queue": {
        "path": s("JSON_TMUX_JOBS_DIR"),
        "total": to_int("JSON_TMUX_TOTAL") or 0,
        "recording": to_int("JSON_TMUX_RECORDING") or 0,
        "processing": to_int("JSON_TMUX_PROCESSING") or 0,
        "stale": to_int("JSON_TMUX_STALE") or 0,
    },
    "summary": {
        "issues": to_int("JSON_ISSUES") or 0,
        "warnings": to_int("JSON_WARNINGS") or 0,
        "status": s("JSON_SUMMARY_STATUS"),
    },
    "suggestions": [line for line in s("JSON_SUGGESTIONS").splitlines() if line],
}

print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
}

doctor() {
  if [[ "${1:-}" == "--json" ]]; then
    doctor_json
    return 0
  fi

  echo "Tmux Whisper doctor"
  echo ""

  load_backend_runtime_cache >/dev/null 2>&1 || true

  local issues=0
  local warnings=0
  local suggestions=()

  local add_suggestion
  add_suggestion() {
    local suggestion="${1:-}"
    [[ -n "$suggestion" ]] || return 0
    local existing
    for existing in "${suggestions[@]-}"; do
      [[ "$existing" == "$suggestion" ]] && return 0
    done
    suggestions+=("$suggestion")
  }

  local check_required_dep
  check_required_dep() {
    local dep="$1"
    if command -v "$dep" >/dev/null 2>&1; then
      echo "  - $dep: ok"
    else
      echo "  - $dep: missing"
      issues=$((issues + 1))
      case "$dep" in
        python3) add_suggestion "Install python3: brew install python" ;;
        ffmpeg) add_suggestion "Install ffmpeg: brew install ffmpeg" ;;
      esac
    fi
  }

  local check_optional_dep
  check_optional_dep() {
    local dep="$1"
    if command -v "$dep" >/dev/null 2>&1; then
      echo "  - $dep: ok"
    else
      echo "  - $dep: missing (optional)"
      warnings=$((warnings + 1))
      case "$dep" in
        tmux) add_suggestion "Install tmux (optional, recommended): brew install tmux" ;;
        swift) add_suggestion "Install Swift/Xcode so tmux-whisperd can be built" ;;
      esac
    fi
  }

  echo "Dependencies:"
  check_required_dep python3
  check_required_dep ffmpeg
  check_optional_dep tmux
  check_optional_dep swift
  echo ""

  echo "Install sanity:"
  local dictate_bin install_channel
  dictate_bin="$(resolve_running_tmux_whisper_bin)"
  install_channel="$(detect_install_channel "$dictate_bin")"
  echo "  - tmux-whisper binary: ${dictate_bin:-missing}"
  if [[ -z "$dictate_bin" ]]; then
    issues=$((issues + 1))
    add_suggestion "Install Tmux Whisper from this repo: ./install.sh --force"
  fi
  echo "  - install channel: $install_channel"
  echo "  - shared library: $DICTATE_LIB_PATH $([[ -r "$DICTATE_LIB_PATH" ]] && echo '(ok)' || echo '(missing)')"
  if [[ ! -r "$DICTATE_LIB_PATH" ]]; then
    issues=$((issues + 1))
    add_suggestion "Repair Tmux Whisper install: ./install.sh --force"
  fi
  echo "  - internal library dir: $DICTATE_INTERNAL_LIB_DIR $([[ -d "$DICTATE_INTERNAL_LIB_DIR" ]] && echo '(ok)' || echo '(missing)')"
  if [[ ! -r "$DICTATE_INTERNAL_LIB_DIR/history.sh" || ! -r "$DICTATE_INTERNAL_LIB_DIR/diagnostics.sh" ]]; then
    issues=$((issues + 1))
    add_suggestion "Repair internal runtime modules: ./install.sh --force"
  fi
  echo "  - config file: $DICTATE_CONFIG_FILE $([[ -f "$DICTATE_CONFIG_FILE" ]] && echo '(ok)' || echo '(missing)')"
  if [[ ! -f "$DICTATE_CONFIG_FILE" ]]; then
    warnings=$((warnings + 1))
    add_suggestion "Create default config: tmux-whisper config repair"
  fi
  local cfg_schema_status cfg_schema_version cfg_parse_error
  cfg_schema_status="$(config_schema_status)"
  cfg_schema_version="$(config_schema_version_label)"
  cfg_parse_error="${CFG_CONFIG_PARSE_ERROR:-}"
  echo "  - config schema: ${cfg_schema_version} (expected v${DICTATE_CONFIG_SCHEMA_VERSION}, status=${cfg_schema_status})"
  case "$cfg_schema_status" in
    mismatch)
      issues=$((issues + 1))
      echo "  - hint: this build requires config schema v${DICTATE_CONFIG_SCHEMA_VERSION}. Preview repair with tmux-whisper config repair --dry-run, then apply with tmux-whisper config repair."
      add_suggestion "Preview config repair: tmux-whisper config repair --dry-run"
      add_suggestion "Repair config in place: tmux-whisper config repair"
      ;;
    invalid)
      issues=$((issues + 1))
      echo "  - hint: config TOML is invalid. Preview repair with tmux-whisper config repair --dry-run, then apply with tmux-whisper config repair."
      [[ -n "$cfg_parse_error" ]] && echo "  - parse error: $cfg_parse_error"
      [[ -n "$cfg_parse_error" ]] && echo "  - using: $( [[ "${CFG_CONFIG_SOURCE:-}" == "last_good" ]] && echo "the last valid copy of config.toml" || echo "built-in defaults" )"
      add_suggestion "Preview config repair: tmux-whisper config repair --dry-run"
      add_suggestion "Repair config in place: tmux-whisper config repair"
      ;;
  esac
  echo "  - raycast inline: $DICTATE_CONFIG_DIR/integrations/raycast/tmux-whisper-inline.sh $([[ -f "$DICTATE_CONFIG_DIR/integrations/raycast/tmux-whisper-inline.sh" ]] && echo '(ok)' || echo '(missing)')"
  local swift_root swift_binary swift_socket_path swift_model_path swift_model_version swift_models_dir
  swift_root="$(resolve_tmux_whisperd_root 2>/dev/null || true)"
  swift_binary="${DICTATE_TMUX_WHISPERD_BIN:-${swift_root:+$(tmux_whisperd_build_root)/.build/release/tmux-whisperd}}"
  swift_socket_path="$(resolve_swift_parakeet_socket_path)"
  swift_model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  swift_model_version="$(resolve_swift_parakeet_model_version "${swift_model_path:-}")"
  swift_models_dir="$(expand_path "$DEFAULT_SWIFT_PARAKEET_MODELS_DIR")"
  echo "  - backend: swift_parakeet"
  echo "  - tmux-whisperd source: ${swift_root:-missing}"
  if [[ -z "$swift_root" ]]; then
    issues=$((issues + 1))
    add_suggestion "Reinstall native backend sources: ./install.sh --force"
  fi
  echo "  - tmux-whisperd binary: ${swift_binary:-missing} $([[ -n "$swift_binary" && -x "$swift_binary" ]] && echo '(ok)' || echo '(build needed)')"
  if [[ -z "$(command -v swift 2>/dev/null || true)" && ( -z "$swift_binary" || ! -x "$swift_binary" ) ]]; then
    issues=$((issues + 1))
    add_suggestion "Install Swift/Xcode so tmux-whisperd can be built"
  fi
  echo "  - tmux-whisperd socket: $swift_socket_path $([[ -S "$swift_socket_path" ]] && echo '(live)' || echo '(offline)')"
  echo "  - preferred parakeet dir: $swift_models_dir"
  echo "  - parakeet model: ${swift_model_path:-missing}"
  if [[ -z "$swift_model_path" || ! -d "$swift_model_path" ]]; then
    issues=$((issues + 1))
    add_suggestion "Set swift_parakeet.model_path in ~/.config/dictate/config.toml to your local CoreML Parakeet model directory"
  else
    echo "  - parakeet model version: $swift_model_version"
    if [[ "$swift_model_path" == "$HOME/Library/Application Support/FluidAudio/Models/"* ]]; then
      add_suggestion "Move or copy the Parakeet model into $swift_models_dir so tmux-whisper does not depend on Spokenly/FluidAudio being installed"
    fi
  fi
  echo ""

  echo "Mode/config:"
  local mode_inventory_lines="" mode_line=""
  local mode_total_count inline_mode_count tmux_mode_count any_modes_present
  mode_inventory_lines="$(doctor_mode_inventory_tsv)"
  mode_total_count="$(doctor_mode_count_for_flow "")"
  inline_mode_count="$(doctor_mode_count_for_flow "inline")"
  tmux_mode_count="$(doctor_mode_count_for_flow "tmux")"
  any_modes_present="0"
  [[ -n "${mode_inventory_lines//[[:space:]]/}" ]] && any_modes_present="1"

  local inline_mode_requested inline_mode_effective inline_mode_source inline_mode_status
  local inline_mode_requested_exists="0" inline_mode_flow_allowed="0"
  if [[ -f "$MODE_FILE" ]]; then
    inline_mode_requested="$(head -n 1 "$MODE_FILE" 2>/dev/null | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  else
    inline_mode_requested="auto"
  fi
  if [[ -z "$inline_mode_requested" ]]; then
    inline_mode_effective="$(default_inline_mode)"
    inline_mode_source="fixed"
    inline_mode_status="invalid_empty"
    warnings=$((warnings + 1))
    echo "  - mode.current: <empty> (invalid, fallback=auto)"
    add_suggestion "Set inline mode policy: tmux-whisper mode auto"
  elif [[ "$inline_mode_requested" == "auto" ]]; then
    inline_mode_effective="$(get_current_mode 2>/dev/null || true)"
    [[ -n "$inline_mode_effective" ]] || inline_mode_effective="$(default_inline_mode)"
    inline_mode_source="auto"
    if [[ "$inline_mode_count" -gt 0 ]]; then
      inline_mode_status="ok"
      echo "  - mode.current: auto (app-detect, current=$(mode_display_name "$inline_mode_effective"))"
    else
      inline_mode_status="no_inline_modes"
      echo "  - mode.current: auto (no inline-capable modes, fallback=$(mode_display_name "$inline_mode_effective"))"
    fi
  elif mode_exists "$inline_mode_requested"; then
    inline_mode_requested_exists="1"
    inline_mode_effective="$(canonical_mode_name "$inline_mode_requested")"
    inline_mode_source="fixed"
    if mode_allows_flow "$inline_mode_effective" "inline"; then
      inline_mode_status="ok"
      inline_mode_flow_allowed="1"
      echo "  - mode.current: $(mode_display_name "$inline_mode_effective") (fixed)"
    else
      inline_mode_effective="$(default_inline_mode)"
      inline_mode_status="flow_disabled"
      warnings=$((warnings + 1))
      echo "  - mode.current: $(mode_display_name "$inline_mode_requested") (fixed, inline disabled, fallback=$(mode_display_name "$inline_mode_effective"))"
      add_suggestion "Set inline mode policy: tmux-whisper mode auto"
      add_suggestion "$(doctor_mode_flow_fix_suggestion "$inline_mode_requested" "inline")"
    fi
  else
    inline_mode_effective="$(default_inline_mode)"
    inline_mode_source="fixed"
    inline_mode_status="invalid"
    warnings=$((warnings + 1))
    echo "  - mode.current: $inline_mode_requested (invalid, fallback=auto)"
    add_suggestion "Set inline mode policy: tmux-whisper mode auto"
    add_suggestion "Or create the missing mode: tmux-whisper mode create \"$inline_mode_requested\""
  fi

  local tmux_mode_requested tmux_mode_effective tmux_mode_status tmux_mode_fallback
  local tmux_mode_requested_exists="0" tmux_mode_flow_allowed="0"
  tmux_mode_requested="${DICTATE_TMUX_MODE:-${CFG_TMUX_MODE:-code}}"
  tmux_mode_effective="$(canonical_mode_name "$tmux_mode_requested")"
  tmux_mode_fallback="$(first_mode_for_flow "tmux")"
  if mode_exists "$tmux_mode_effective"; then
    tmux_mode_requested_exists="1"
    if mode_allows_flow "$tmux_mode_effective" "tmux"; then
      tmux_mode_status="ok"
      tmux_mode_flow_allowed="1"
      echo "  - tmux.mode: $(mode_display_name "$tmux_mode_effective") (ok)"
    else
      tmux_mode_status="flow_disabled"
      warnings=$((warnings + 1))
      echo "  - tmux.mode: $(mode_display_name "$tmux_mode_effective") (tmux disabled, fallback=$(mode_display_name "$tmux_mode_fallback"))"
      add_suggestion "Set tmux mode to a valid mode: tmux-whisper tmux mode code"
      add_suggestion "$(doctor_mode_flow_fix_suggestion "$tmux_mode_effective" "tmux")"
    fi
  else
    tmux_mode_status="invalid"
    warnings=$((warnings + 1))
    echo "  - tmux.mode: $tmux_mode_requested (invalid, fallback=code)"
    add_suggestion "Set tmux mode to a valid mode: tmux-whisper tmux mode code"
  fi

  if [[ "$any_modes_present" != "1" ]]; then
    warnings=$((warnings + 1))
    echo "  - modes: none found in $DICTATE_CONFIG_DIR/modes"
    add_suggestion "Repair mode defaults: ./install.sh --force"
  else
    echo "  - modes.total: $mode_total_count"
    echo "  - modes.inline-capable: $inline_mode_count"
    echo "  - modes.tmux-capable: $tmux_mode_count"
    if [[ "$inline_mode_count" -eq 0 ]]; then
      warnings=$((warnings + 1))
      local inline_seed_mode=""
      inline_seed_mode="$(doctor_mode_seed_for_flow "inline")"
      if [[ -n "$inline_seed_mode" ]]; then
        add_suggestion "$(doctor_mode_flow_fix_suggestion "$inline_seed_mode" "inline")"
      else
        add_suggestion "Repair mode defaults: ./install.sh --force"
      fi
    fi
    if [[ "$tmux_mode_count" -eq 0 ]]; then
      warnings=$((warnings + 1))
      local tmux_seed_mode=""
      tmux_seed_mode="$(doctor_mode_seed_for_flow "tmux")"
      if [[ -n "$tmux_seed_mode" ]]; then
        add_suggestion "$(doctor_mode_flow_fix_suggestion "$tmux_seed_mode" "tmux")"
      else
        add_suggestion "Repair mode defaults: ./install.sh --force"
      fi
    fi
  fi

  while IFS= read -r mode_line; do
    [[ -n "$mode_line" ]] || continue
    local inv_mode inv_label inv_prompt_status inv_prompt_path inv_flows_summary
    local inv_inline_enabled inv_tmux_enabled inv_flows_path inv_flows_explicit inv_invalid_entries
    local inv_apps_path inv_apps_count inv_apps_ignored inv_flow_origin inv_flow_note
    IFS=$'\x1f' read -r inv_mode inv_label inv_prompt_status inv_prompt_path inv_flows_summary \
      inv_inline_enabled inv_tmux_enabled inv_flows_path inv_flows_explicit inv_invalid_entries \
      inv_apps_path inv_apps_count inv_apps_ignored <<<"$mode_line"

    echo "  - mode.$inv_mode.prompt: $inv_prompt_status"
    case "$inv_prompt_status" in
      empty|missing)
        warnings=$((warnings + 1))
        add_suggestion "Populate $inv_label prompt: tmux-whisper mode edit $inv_label"
        ;;
    esac

    if [[ "$inv_flows_explicit" == "1" ]]; then
      inv_flow_origin="explicit"
    else
      inv_flow_origin="default"
    fi
    inv_flow_note=""
    if [[ -n "$inv_invalid_entries" ]]; then
      inv_flow_note="; invalid=${inv_invalid_entries//,/, }"
      warnings=$((warnings + 1))
      add_suggestion "Review flow filter for '$inv_mode': tmux-whisper mode flows $inv_mode"
    fi
    echo "  - mode.$inv_mode.flows: $inv_flows_summary ($inv_flow_origin$inv_flow_note)"

    if [[ "$inv_apps_count" =~ ^[0-9]+$ && "$inv_apps_count" -gt 0 ]]; then
      if [[ "$inv_apps_ignored" == "1" ]]; then
        warnings=$((warnings + 1))
        echo "  - mode.$inv_mode.apps: $inv_apps_count mapping(s) ignored (inline flow disabled)"
        add_suggestion "$(doctor_mode_flow_fix_suggestion "$inv_mode" "inline")"
      else
        echo "  - mode.$inv_mode.apps: $inv_apps_count mapping(s)"
      fi
    fi
  done <<<"$mode_inventory_lines"
  echo ""

  local _age_s
  _age_s() {
    local f="${1:-}"
    [[ -f "$f" ]] || { echo "-"; return 0; }
    local now mtime
    now="$(date +%s)"
    mtime="$(stat -f %m "$f" 2>/dev/null || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(stat -c %Y "$f" 2>/dev/null || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if [[ "$mtime" -le 0 ]]; then
      echo "?"
      return 0
    fi
    echo $((now - mtime))
  }

  echo "State files:"
  local state_files=(
    "$STATE_FILE"
    "$INLINE_STATE_FILE"
  )
  local sf
  local stale_state_files=()
  for sf in "${state_files[@]}"; do
    if [[ ! -f "$sf" ]]; then
      echo "  - $(basename "$sf"): absent"
      continue
    fi
    local sf_pid sf_target sf_mode
    sf_pid="$( ( source "$sf" 2>/dev/null || true; printf "%s" "${pid:-}" ) 2>/dev/null || true)"
    sf_target="$( ( source "$sf" 2>/dev/null || true; printf "%s" "${target_pane:-${target_app:-}}" ) 2>/dev/null || true)"
    sf_mode="$( ( source "$sf" 2>/dev/null || true; printf "%s" "${model_id:-}" ) 2>/dev/null || true)"
    local age
    age="$(_age_s "$sf")"
    if [[ -n "$sf_pid" ]] && kill -0 "$sf_pid" 2>/dev/null; then
      echo "  - $(basename "$sf"): active pid=$sf_pid age=${age}s target=${sf_target:-n/a} model=${sf_mode:-n/a}"
    else
      echo "  - $(basename "$sf"): stale (pid=${sf_pid:-none}, age=${age}s)"
      warnings=$((warnings + 1))
      stale_state_files+=("$sf")
    fi
  done
  if [[ "${#stale_state_files[@]}" -gt 0 ]]; then
    add_suggestion "Clean stale state files: rm -f ${stale_state_files[*]}"
  fi
  echo ""

  echo "Processing markers:"
  local proc_dir="${DICTATE_PROCESSING_DIR:-/tmp/dictate-processing}"
  local proc_total=0
  local proc_live=0
  local proc_stale=0
  if [[ -d "$proc_dir" ]]; then
    local pf
    for pf in "$proc_dir"/*; do
      [[ -f "$pf" ]] || continue
      proc_total=$((proc_total + 1))
      local marker_pid line
      marker_pid=""
      line="$(head -n 1 "$pf" 2>/dev/null || true)"
      if [[ "$line" =~ ^pid=([0-9]+)$ ]]; then
        marker_pid="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[0-9]+$ ]]; then
        marker_pid="$line"
      fi
      if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null; then
        proc_live=$((proc_live + 1))
      else
        proc_stale=$((proc_stale + 1))
      fi
    done
  fi
  echo "  - total: $proc_total"
  echo "  - live: $proc_live"
  echo "  - stale: $proc_stale"
  if [[ "$proc_stale" -gt 0 ]]; then
    warnings=$((warnings + 1))
    add_suggestion "Clean stale processing markers: rm -rf $proc_dir"
  fi
  echo ""

  echo "tmux queue:"
  local tmux_total=0
  local tmux_rec=0
  local tmux_proc=0
  local jf st marker_pid now mtime age
  now="$(date +%s)"
  if [[ -d "$TMUX_JOBS_DIR" ]]; then
    for jf in "$TMUX_JOBS_DIR"/*; do
      [[ -f "$jf" ]] || continue
      st="$(sed -n 's/^status=//p' "$jf" 2>/dev/null | head -n 1 || true)"
      marker_pid="$(sed -n 's/^pid=//p' "$jf" 2>/dev/null | head -n 1 || true)"
      mtime="$(stat -f %m "$jf" 2>/dev/null || true)"
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(stat -c %Y "$jf" 2>/dev/null || true)"
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
      age=$((now - mtime))
        case "$st" in
          recording|processing)
            if [[ -z "$marker_pid" || ! "$marker_pid" =~ ^[0-9]+$ ]]; then
              warnings=$((warnings + 1))
              echo "  - stale job: $(basename "$jf") status=${st:-unknown} age=${age}s pid=${marker_pid:-none}"
              add_suggestion "Clean stale tmux job markers: rm -rf $TMUX_JOBS_DIR"
              continue
            fi
            if ! kill -0 "$marker_pid" 2>/dev/null; then
              warnings=$((warnings + 1))
              echo "  - stale job: $(basename "$jf") status=${st:-unknown} age=${age}s pid=${marker_pid:-none}"
              add_suggestion "Clean stale tmux job markers: rm -rf $TMUX_JOBS_DIR"
              continue
            fi
            ;;
        esac
      tmux_total=$((tmux_total + 1))
      case "$st" in
        recording) tmux_rec=$((tmux_rec + 1)) ;;
        processing) tmux_proc=$((tmux_proc + 1)) ;;
      esac
    done
  fi
  echo "  - total: $tmux_total"
  echo "  - recording: $tmux_rec"
  echo "  - processing: $tmux_proc"
  echo ""

  echo "Summary:"
  echo "  issues: $issues"
  echo "  warnings: $warnings"
  if [[ "$issues" -eq 0 && "$warnings" -eq 0 ]]; then
    echo "  status: healthy"
  elif [[ "$issues" -eq 0 ]]; then
    echo "  status: ok with warnings"
  else
    echo "  status: needs attention"
  fi

  if [[ "${#suggestions[@]}" -gt 0 ]]; then
    echo ""
    echo "Suggested fixes:"
    local suggestion
    for suggestion in "${suggestions[@]}"; do
      echo "  - $suggestion"
    done
  fi
}

status() {
  local output_format="text"
  local preset="default"
  while [[ $# -gt 0 ]]; do
    case "${1:-}" in
      --json)
        output_format="json"
        ;;
      --preset)
        shift
        [[ $# -gt 0 ]] || die "usage: tmux-whisper status [--json] [--preset compact]"
        case "${1:-}" in
          default|compact)
            preset="${1:-default}"
            ;;
          *)
            die "usage: tmux-whisper status [--json] [--preset compact]"
            ;;
        esac
        ;;
      *)
        die "usage: tmux-whisper status [--json] [--preset compact]"
        ;;
    esac
    shift
  done

  load_backend_runtime_cache >/dev/null 2>&1 || true
  local inline_state="$INLINE_STATE_FILE"
  local proc_dir="${DICTATE_PROCESSING_DIR:-/tmp/dictate-processing}"

  onoff() {
    [[ "${1:-0}" == "1" ]] && echo "ON" || echo "OFF"
  }

  join_with_separator() {
    local sep="${1:- | }"
    shift || true
    local item out=""
    for item in "$@"; do
      [[ -n "$item" ]] || continue
      if [[ -n "$out" ]]; then
        out+="$sep$item"
      else
        out="$item"
      fi
    done
    printf '%s' "$out"
  }

  age_s() {
    local f="${1:-}"
    [[ -f "$f" ]] || { echo "-"; return 0; }
    local now mtime
    now="$(date +%s)"
    mtime="$(stat -f %m "$f" 2>/dev/null || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(stat -c %Y "$f" 2>/dev/null || true)"
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    [[ "$mtime" -gt 0 ]] || { echo "?"; return 0; }
    echo $((now - mtime))
  }

  count_processing_markers() {
    local total=0 live=0 stale=0
    local pf marker_pid line
    if [[ -d "$proc_dir" ]]; then
      for pf in "$proc_dir"/*; do
        [[ -f "$pf" ]] || continue
        total=$((total + 1))
        marker_pid=""
        line="$(head -n 1 "$pf" 2>/dev/null || true)"
        if [[ "$line" =~ ^pid=([0-9]+)$ ]]; then
          marker_pid="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[0-9]+$ ]]; then
          marker_pid="$line"
        fi
        if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null; then
          live=$((live + 1))
        else
          stale=$((stale + 1))
          rm -f "$pf" 2>/dev/null || true
        fi
      done
    fi
    echo "$total $live $stale"
  }

  count_tmux_jobs_snapshot() {
    local total=0 rec=0 proc=0
    local jf st marker_pid now mtime age
    now="$(date +%s)"
    if [[ -d "$TMUX_JOBS_DIR" ]]; then
      for jf in "$TMUX_JOBS_DIR"/*; do
        [[ -f "$jf" ]] || continue
        st="$(sed -n 's/^status=//p' "$jf" 2>/dev/null | head -n 1 || true)"
        marker_pid="$(sed -n 's/^pid=//p' "$jf" 2>/dev/null | head -n 1 || true)"
        mtime="$(stat -f %m "$jf" 2>/dev/null || true)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$(stat -c %Y "$jf" 2>/dev/null || true)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age=$((now - mtime))
        if [[ "$age" -gt 1800 ]]; then
          rm -f "$jf" 2>/dev/null || true
          continue
        fi
        case "$st" in
          recording|processing)
            if [[ -z "$marker_pid" || ! "$marker_pid" =~ ^[0-9]+$ ]]; then
              rm -f "$jf" 2>/dev/null || true
              continue
            fi
            if ! kill -0 "$marker_pid" 2>/dev/null; then
              rm -f "$jf" 2>/dev/null || true
              continue
            fi
            ;;
        esac
        total=$((total + 1))
        case "$st" in
          recording) rec=$((rec + 1)) ;;
          processing) proc=$((proc + 1)) ;;
        esac
      done
    fi
    echo "$total $rec $proc"
  }

  describe_state_file() {
    local label="${1:-}"
    local file="${2:-}"
    [[ -n "$label" && -n "$file" ]] || return 0
    if [[ ! -f "$file" ]]; then
      echo "  $label: idle"
      return 0
    fi

    local st_pid st_target st_app st_model st_lang st_age st_label
    st_pid="$( ( source "$file" 2>/dev/null || true; printf "%s" "${pid:-}" ) 2>/dev/null || true)"
    st_target="$( ( source "$file" 2>/dev/null || true; printf "%s" "${target_pane:-}" ) 2>/dev/null || true)"
    st_app="$( ( source "$file" 2>/dev/null || true; printf "%s" "${target_app:-}" ) 2>/dev/null || true)"
    st_model="$( ( source "$file" 2>/dev/null || true; printf "%s" "${model_id:-}" ) 2>/dev/null || true)"
    st_lang="$( ( source "$file" 2>/dev/null || true; printf "%s" "${language:-}" ) 2>/dev/null || true)"
    st_age="$(age_s "$file")"

    if [[ "$label" == "tmux" ]]; then
      st_label="$st_target"
      [[ -n "$st_target" ]] && st_label="$(tmux_describe_pane "$st_target")"
    else
      st_label="${st_app:-n/a}"
    fi

    if [[ -n "$st_pid" ]] && kill -0 "$st_pid" 2>/dev/null; then
      echo "  $label: active pid=$st_pid age=${st_age}s target=${st_label:-n/a} model=${st_model:-n/a} lang=${st_lang:-en}"
    else
      echo "  $label: stale state file (pid=${st_pid:-none}, age=${st_age}s)"
    fi
  }

  local inline_mode_setting mode_inline mode_inline_source
  if [[ -f "$MODE_FILE" ]]; then
    inline_mode_setting="$(head -n 1 "$MODE_FILE" 2>/dev/null | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  else
    inline_mode_setting="auto"
  fi
  if [[ -z "$inline_mode_setting" || "$inline_mode_setting" == "auto" ]]; then
    mode_inline_source="auto"
  else
    mode_inline_source="fixed"
  fi
  mode_inline="$(canonical_mode_name "$(get_current_mode)")"
  if ! mode_exists "$mode_inline"; then
    mode_inline="$(default_inline_mode)"
  fi

  local mode_tmux_raw mode_tmux
  mode_tmux_raw="${DICTATE_TMUX_MODE:-${CFG_TMUX_MODE:-code}}"
  mode_tmux="$(canonical_mode_name "$mode_tmux_raw")"
  if ! mode_exists "$mode_tmux" || ! mode_allows_flow "$mode_tmux" "tmux"; then
    mode_tmux="$(first_mode_for_flow "tmux")"
  fi

  local backend_requested swift_model_path swift_model_version swift_socket_path
  backend_requested="$(resolve_transcribe_backend)"
  swift_model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  swift_model_version="$(resolve_swift_parakeet_model_version "${swift_model_path:-}")"
  swift_socket_path="$(resolve_swift_parakeet_socket_path)"

  local post_inline post_inline_requested post_tmux post_tmux_requested
  post_inline_requested="${DICTATE_POSTPROCESS:-${CFG_POSTPROCESS_ENABLED:-0}}"
  if bool_is_on "$post_inline_requested"; then
    post_inline_requested="1"
  else
    post_inline_requested="0"
  fi
  post_inline="$post_inline_requested"
  post_tmux_requested="$(resolve_tmux_postprocess_requested)"
  post_tmux="$(resolve_tmux_postprocess_effective)"
  local cerebras_key_set="0"
  [[ -n "${CEREBRAS_API_KEY:-}" ]] && cerebras_key_set="1"
  if [[ "$cerebras_key_set" != "1" ]]; then
    post_inline="0"
  fi

  local inline_autosend inline_process_sound inline_target inline_send_mode tmux_autosend tmux_target tmux_process_sound
  inline_autosend="${DICTATE_AUTOSEND:-${CFG_INLINE_AUTOSEND:-1}}"
  inline_process_sound="${DICTATE_INLINE_PROCESS_SOUND:-${CFG_INLINE_PROCESS_SOUND:-1}}"
  inline_target="$(inline_paste_target_label "${DICTATE_INLINE_PASTE_TARGET:-${CFG_INLINE_PASTE_TARGET:-restore}}")"
  inline_send_mode="$(inline_send_mode_label "${DICTATE_INLINE_SEND_MODE:-${CFG_INLINE_SEND_MODE:-enter}}")"
  tmux_autosend="${DICTATE_TMUX_AUTOSEND:-${CFG_TMUX_AUTOSEND:-1}}"
  tmux_target="${DICTATE_TMUX_PASTE_TARGET:-${CFG_TMUX_PASTE_TARGET:-origin}}"
  tmux_process_sound="${DICTATE_TMUX_PROCESS_SOUND:-${CFG_TMUX_PROCESS_SOUND:-0}}"
  local tmux_send_mode keep_logs_val
  tmux_send_mode="${DICTATE_TMUX_SEND_MODE:-${CFG_TMUX_SEND_MODE:-auto}}"
  case "$tmux_send_mode" in
    auto|enter|codex) ;;
    *) tmux_send_mode="auto" ;;
  esac
  keep_logs_val="${DICTATE_KEEP_LOGS:-${CFG_DEBUG_KEEP_LOGS:-0}}"

  local clean_enabled repeats_level silence_trim
  clean_enabled="${DICTATE_CLEAN:-0}"
  repeats_level="${DICTATE_REPEATS_LEVEL:-${CFG_CLEAN_REPEATS_LEVEL:-1}}"
  silence_trim="${DICTATE_SILENCE_TRIM:-${CFG_AUDIO_SILENCE_TRIM:-0}}"
  local vocab_clean
  vocab_clean="${DICTATE_VOCAB_CLEAN:-1}"
  if bool_is_on "$vocab_clean"; then
    vocab_clean="1"
  else
    vocab_clean="0"
  fi

  local llm_model llm_max_tokens llm_chunk_words
  llm_model="${DICTATE_LLM_MODEL:-${CFG_POSTPROCESS_LLM:-llama3.1-8b}}"
  llm_max_tokens="${DICTATE_LLM_MAX_TOKENS:-${CFG_POSTPROCESS_MAX_TOKENS:-}}"
  llm_chunk_words="${DICTATE_LLM_CHUNK_WORDS:-${CFG_POSTPROCESS_CHUNK_WORDS:-}}"

  lookup_override() {
    local list="${1:-}"
    local key="${2:-}"
    [[ -n "$list" && -n "$key" ]] || return 1
    local IFS=';'
    read -r -a pairs <<<"$list"
    local pair
    for pair in "${pairs[@]}"; do
      [[ "$pair" == "$key="* ]] && { echo "${pair#*=}"; return 0; }
    done
    return 1
  }

  lookup_override_for_mode() {
    local list="${1:-}"
    local mode="${2:-}"
    local key value
    key="$(mode_override_key "$mode")"
    value="$(lookup_override "$list" "$key" 2>/dev/null || true)"
    [[ -n "$value" ]] && echo "$value"
  }

  local budget_short_llm budget_short_max budget_short_chunk
  local budget_long_llm budget_long_max budget_long_chunk
  budget_short_llm="$(lookup_override_for_mode "${CFG_POSTPROCESS_BUDGET_PROFILE_LLM_OVERRIDES:-}" "short" 2>/dev/null || true)"
  budget_short_max="$(lookup_override_for_mode "${CFG_POSTPROCESS_BUDGET_PROFILE_MAX_TOKENS_OVERRIDES:-}" "short" 2>/dev/null || true)"
  budget_short_chunk="$(lookup_override_for_mode "${CFG_POSTPROCESS_BUDGET_PROFILE_CHUNK_WORDS_OVERRIDES:-}" "short" 2>/dev/null || true)"
  budget_long_llm="$(lookup_override_for_mode "${CFG_POSTPROCESS_BUDGET_PROFILE_LLM_OVERRIDES:-}" "long" 2>/dev/null || true)"
  budget_long_max="$(lookup_override_for_mode "${CFG_POSTPROCESS_BUDGET_PROFILE_MAX_TOKENS_OVERRIDES:-}" "long" 2>/dev/null || true)"
  budget_long_chunk="$(lookup_override_for_mode "${CFG_POSTPROCESS_BUDGET_PROFILE_CHUNK_WORDS_OVERRIDES:-}" "long" 2>/dev/null || true)"

  local audio_name audio_idx audio_src audio_source_mode
  audio_source_mode="$(normalize_audio_source "${DICTATE_AUDIO_SOURCE:-${CFG_AUDIO_SOURCE:-auto}}")"
  audio_name="${DICTATE_AUDIO_NAME:-${CFG_AUDIO_DEVICE_NAME:-}}"
  audio_idx="${DICTATE_AUDIO_INDEX:-}"
  audio_src="(none)"
  if [[ -n "$audio_idx" ]]; then
      audio_src="env:DICTATE_AUDIO_INDEX"
  elif [[ -n "${CFG_AUDIO_DEVICE_INDEX:-}" ]]; then
    audio_idx="${CFG_AUDIO_DEVICE_INDEX}"
    audio_src="config:audio.device_index"
  else
    if command -v ffmpeg >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
      local detect_meta detect_src _detect_ms _detect_note
      detect_meta="$(detect_audio_index 2>/dev/null || true)"
      IFS=$'\t' read -r audio_idx detect_src _detect_ms _detect_note <<<"$detect_meta"
      if [[ -n "$audio_idx" ]]; then
        audio_src="${detect_src:-detect:source(${audio_source_mode})}"
      fi
    else
      audio_src="detect skipped (missing ffmpeg/python3)"
    fi
  fi

  local key_status="UNSET"
  [[ -n "${CEREBRAS_API_KEY:-}" ]] && key_status="SET"

  local cfg_schema_status cfg_schema_version cfg_parse_error
  cfg_schema_status="$(config_schema_status)"
  cfg_schema_version="$(config_schema_version_label)"
  cfg_parse_error="${CFG_CONFIG_PARSE_ERROR:-}"

  local proc_total proc_live proc_stale
  read -r proc_total proc_live proc_stale < <(count_processing_markers)

  local tmux_total tmux_rec tmux_proc
  read -r tmux_total tmux_rec tmux_proc < <(count_tmux_jobs_snapshot)

  local state_tmux_summary state_inline_summary
  local tmux_state tmux_pid tmux_age tmux_display tmux_model tmux_lang tmux_raw_target
  local inline_state_status inline_pid inline_age inline_display inline_model inline_lang inline_raw_target
  state_tmux_summary="$(state_file_summary_tsv tmux "$STATE_FILE")"
  state_inline_summary="$(state_file_summary_tsv inline "$inline_state")"
  IFS=$'\t' read -r tmux_state tmux_pid tmux_age tmux_display tmux_model tmux_lang tmux_raw_target <<<"$state_tmux_summary"
  IFS=$'\t' read -r inline_state_status inline_pid inline_age inline_display inline_model inline_lang inline_raw_target <<<"$state_inline_summary"

  local backend_readiness summary_state summary_headline summary_next_action summary_active_flow
  local model_ready="0" socket_live="0" stale_runtime="0"
  if [[ -n "$swift_model_path" && -d "$swift_model_path" ]]; then
    model_ready="1"
  fi
  if [[ -S "$swift_socket_path" ]]; then
    socket_live="1"
  fi
  if [[ "$model_ready" != "1" ]]; then
    backend_readiness="missing_model"
  elif [[ "$socket_live" == "1" ]]; then
    backend_readiness="warm"
  else
    backend_readiness="cold"
  fi
  if [[ "$tmux_state" == "stale" || "$inline_state_status" == "stale" || "$proc_stale" -gt 0 ]]; then
    stale_runtime="1"
  fi

  summary_active_flow="none"
  if [[ "$proc_live" -gt 0 || "$tmux_proc" -gt 0 ]]; then
    summary_state="processing"
    summary_headline="Dictation is still processing a recent run."
    if [[ "$tmux_proc" -gt 0 ]]; then
      summary_active_flow="tmux"
    elif [[ "$inline_state_status" == "active" ]]; then
      summary_active_flow="inline"
    fi
    summary_next_action="Wait for transcription and paste to finish."
  elif [[ "$tmux_state" == "active" || "$tmux_rec" -gt 0 ]]; then
    summary_state="recording"
    summary_active_flow="tmux"
    summary_headline="Tmux dictation is recording right now."
    summary_next_action="Stop the current run with your hotkey or tmux-whisper stop."
  elif [[ "$inline_state_status" == "active" ]]; then
    summary_state="recording"
    summary_active_flow="inline"
    summary_headline="Inline dictation is recording right now."
    summary_next_action="Stop the current run with your hotkey or tmux-whisper stop."
  elif [[ "$stale_runtime" == "1" ]]; then
    summary_state="attention"
    summary_headline="Runtime markers look stale."
    summary_next_action="Run tmux-whisper doctor to inspect or tmux-whisper cancel if a run got stuck."
  elif [[ "$cfg_schema_status" == "invalid" ]]; then
    summary_state="attention"
    summary_headline="Config file is invalid TOML."
    summary_next_action="Preview repair with tmux-whisper config repair --dry-run, then run tmux-whisper config repair."
  elif [[ "$cfg_schema_status" == "mismatch" ]]; then
    summary_state="attention"
    summary_headline="Config schema needs repair."
    summary_next_action="Preview repair with tmux-whisper config repair --dry-run, then run tmux-whisper config repair."
  elif [[ "$backend_readiness" == "missing_model" ]]; then
    summary_state="not_ready"
    summary_headline="Parakeet model path is missing or invalid."
    summary_next_action="Set swift_parakeet.model_path in ~/.config/dictate/config.toml."
  elif [[ "$backend_readiness" == "cold" ]]; then
    summary_state="ready"
    summary_headline="Dictation is ready, but the backend is cold."
    summary_next_action="Use your normal hotkey, or run tmux-whisper warmup to pre-load the daemon."
  else
    summary_state="ready"
    summary_headline="Dictation is ready."
    summary_next_action="Use your normal hotkey to start recording."
  fi

  local more_detail_commands=()
  case "$summary_state" in
    recording)
      local record_stream="record"
      if [[ "$summary_active_flow" == "inline" ]]; then
        record_stream="inline-record"
      fi
      more_detail_commands=(
        "tmux-whisper stop"
        "tmux-whisper watch --preset compact"
        "tmux-whisper logs follow $record_stream"
      )
      ;;
    processing)
      local transcribe_stream="transcribe"
      if [[ "$summary_active_flow" == "inline" ]]; then
        transcribe_stream="inline-transcribe"
      fi
      more_detail_commands=(
        "tmux-whisper watch --preset compact"
        "tmux-whisper last"
        "tmux-whisper history sessions 5"
        "tmux-whisper logs follow $transcribe_stream"
      )
      ;;
    attention|not_ready)
      more_detail_commands=(
        "tmux-whisper doctor"
        "tmux-whisper debug"
        "tmux-whisper config repair --dry-run"
      )
      ;;
    *)
      more_detail_commands=(
        "tmux-whisper watch --preset compact"
        "tmux-whisper last"
        "tmux-whisper bench"
        "tmux-whisper history sessions 5"
      )
      ;;
  esac
  local more_detail_lines
  more_detail_lines="$(printf '%s\n' "${more_detail_commands[@]}")"

  local override_vars=(
    DICTATE_AUDIO_SOURCE DICTATE_AUDIO_INDEX DICTATE_AUDIO_NAME
    DICTATE_TMUX_MODE
    DICTATE_SWIFT_PARAKEET_MODEL_PATH DICTATE_SWIFT_PARAKEET_MODEL_VERSION DICTATE_SWIFT_PARAKEET_SOCKET_PATH
    DICTATE_POSTPROCESS DICTATE_TMUX_POSTPROCESS DICTATE_VOCAB_CLEAN
    DICTATE_AUTOSEND DICTATE_TMUX_AUTOSEND
    DICTATE_INLINE_PASTE_TARGET DICTATE_INLINE_SEND_MODE
    DICTATE_INLINE_ACTIVATE_DELAY_MS DICTATE_INLINE_SEND_DELAY_MS
    DICTATE_TMUX_PASTE_TARGET DICTATE_TMUX_PROCESS_SOUND
    DICTATE_TMUX_SEND_MODE
    DICTATE_TMUX_SEND_DELAY_MS DICTATE_TMUX_CODEX_TAB_DELAY_MS
    DICTATE_CLEAN DICTATE_REPEATS_LEVEL DICTATE_SILENCE_TRIM
    DICTATE_TRIM_WITH_POSTPROCESS DICTATE_REPEATS_WITH_POSTPROCESS
    DICTATE_LLM_MODEL DICTATE_LLM_MAX_TOKENS DICTATE_LLM_CHUNK_WORDS DICTATE_BRITISH_SPELLING
    DICTATE_LANGUAGE
    DICTATE_TARGET_APP DICTATE_TARGET_PANE
    DICTATE_KEEP_LOGS
    CEREBRAS_API_KEY
  )
  local env_override_lines
  env_override_lines="$(collect_set_env_overrides "${override_vars[@]}")"

  if [[ "$output_format" == "json" ]]; then
    local postprocess_note=""
    if [[ "$cerebras_key_set" != "1" && ( "$post_inline_requested" == "1" || "$post_tmux_requested" == "1" ) ]]; then
      postprocess_note="disabled at runtime (CEREBRAS_API_KEY missing)"
    fi

    env \
      JSON_STATE_FILE_PATH="$STATE_FILE" \
      JSON_INLINE_STATE_FILE_PATH="$inline_state" \
      JSON_STATE_TMUX="$state_tmux_summary" \
      JSON_STATE_INLINE="$state_inline_summary" \
      JSON_PROC_TOTAL="$proc_total" \
      JSON_PROC_LIVE="$proc_live" \
      JSON_PROC_STALE="$proc_stale" \
      JSON_PROC_DIR="$proc_dir" \
      JSON_TMUX_TOTAL="$tmux_total" \
      JSON_TMUX_RECORDING="$tmux_rec" \
      JSON_TMUX_PROCESSING="$tmux_proc" \
      JSON_TMUX_JOBS_DIR="$TMUX_JOBS_DIR" \
      JSON_SUMMARY_STATE="$summary_state" \
      JSON_SUMMARY_HEADLINE="$summary_headline" \
      JSON_SUMMARY_NEXT_ACTION="$summary_next_action" \
      JSON_SUMMARY_ACTIVE_FLOW="$summary_active_flow" \
      JSON_BACKEND_READINESS="$backend_readiness" \
      JSON_CONFIG_SCHEMA_VERSION="$cfg_schema_version" \
      JSON_CONFIG_SCHEMA_STATUS="$cfg_schema_status" \
      JSON_CONFIG_SCHEMA_PARSE_ERROR="$cfg_parse_error" \
      JSON_BACKEND="$backend_requested" \
      JSON_MODE_INLINE="$mode_inline" \
      JSON_MODE_INLINE_DISPLAY="$(mode_display_name "$mode_inline")" \
      JSON_MODE_INLINE_SOURCE="$mode_inline_source" \
      JSON_MODE_TMUX="$mode_tmux" \
      JSON_MODE_TMUX_DISPLAY="$(mode_display_name "$mode_tmux")" \
      JSON_SWIFT_MODEL_PATH="$swift_model_path" \
      JSON_SWIFT_MODEL_VERSION="$swift_model_version" \
      JSON_SWIFT_SOCKET_PATH="$swift_socket_path" \
      JSON_LANGUAGE="${DICTATE_LANGUAGE:-en}" \
      JSON_POST_INLINE_REQUESTED="$post_inline_requested" \
      JSON_POST_INLINE_EFFECTIVE="$post_inline" \
      JSON_POST_TMUX_REQUESTED="$post_tmux_requested" \
      JSON_POST_TMUX_EFFECTIVE="$post_tmux" \
      JSON_POSTPROCESS_NOTE="$postprocess_note" \
      JSON_CEREBRAS_KEY_SET="$cerebras_key_set" \
      JSON_LLM_MODEL="$llm_model" \
      JSON_LLM_MAX_TOKENS="$llm_max_tokens" \
      JSON_LLM_CHUNK_WORDS="$llm_chunk_words" \
      JSON_BUDGET_THRESHOLD="${CFG_POSTPROCESS_BUDGET_LONG_WORDS_THRESHOLD:-120}" \
      JSON_BUDGET_SHORT_LLM="${budget_short_llm:-${CFG_POSTPROCESS_LLM:-llama3.1-8b}}" \
      JSON_BUDGET_SHORT_MAX="${budget_short_max:-${CFG_POSTPROCESS_MAX_TOKENS:-}}" \
      JSON_BUDGET_SHORT_CHUNK="${budget_short_chunk:-${CFG_POSTPROCESS_CHUNK_WORDS:-}}" \
      JSON_BUDGET_LONG_LLM="${budget_long_llm:-${CFG_POSTPROCESS_LLM:-llama3.1-8b}}" \
      JSON_BUDGET_LONG_MAX="${budget_long_max:-${CFG_POSTPROCESS_MAX_TOKENS:-}}" \
      JSON_BUDGET_LONG_CHUNK="${budget_long_chunk:-${CFG_POSTPROCESS_CHUNK_WORDS:-}}" \
      JSON_BRITISH_SPELLING="${DICTATE_BRITISH_SPELLING:-1}" \
      JSON_CLEAN_REGEX="$clean_enabled" \
      JSON_CLEAN_REPEATS_LEVEL="$repeats_level" \
      JSON_CLEAN_VOCAB_ONLY="$vocab_clean" \
      JSON_SILENCE_TRIM="$silence_trim" \
      JSON_SILENCE_TRIM_MODE="${CFG_AUDIO_SILENCE_TRIM_MODE:-edges}" \
      JSON_INLINE_AUTOSEND="$inline_autosend" \
      JSON_INLINE_PROCESS_SOUND="$inline_process_sound" \
      JSON_INLINE_TARGET="$inline_target" \
      JSON_INLINE_SEND_MODE="$inline_send_mode" \
      JSON_TMUX_AUTOSEND="$tmux_autosend" \
      JSON_TMUX_TARGET="$tmux_target" \
      JSON_TMUX_PROCESS_SOUND="$tmux_process_sound" \
      JSON_TMUX_SEND_MODE="$tmux_send_mode" \
      JSON_KEEP_LOGS="$keep_logs_val" \
      JSON_AUDIO_SOURCE="$audio_source_mode" \
      JSON_AUDIO_DEVICE_NAME="$audio_name" \
      JSON_AUDIO_MAC_NAME="${CFG_AUDIO_MAC_NAME:-}" \
      JSON_AUDIO_IPHONE_NAME="${CFG_AUDIO_IPHONE_NAME:-}" \
      JSON_AUDIO_DEVICE_INDEX_FALLBACK="${CFG_AUDIO_DEVICE_INDEX:-}" \
      JSON_AUDIO_INDEX_RESOLVED="$audio_idx" \
      JSON_AUDIO_INDEX_SOURCE="$audio_src" \
      JSON_SOUND_MASTER="${CFG_AUDIO_SOUNDS_ENABLED:-1}" \
      JSON_SOUND_START="${CFG_AUDIO_SOUNDS_START_ENABLED:-1}" \
      JSON_SOUND_STOP="${CFG_AUDIO_SOUNDS_STOP_ENABLED:-1}" \
      JSON_SOUND_PROCESS="${CFG_AUDIO_SOUNDS_PROCESS_ENABLED:-1}" \
      JSON_SOUND_ERROR="${CFG_AUDIO_SOUNDS_ERROR_ENABLED:-1}" \
      JSON_SOUND_CANCEL="${CFG_AUDIO_SOUNDS_CANCEL_ENABLED:-1}" \
      JSON_KEY_STATUS="$key_status" \
      JSON_ENV_OVERRIDES="$env_override_lines" \
      JSON_MORE_DETAIL="$more_detail_lines" \
      python3 - <<'PYEOF'
import json
import os

def s(name: str) -> str:
    return os.environ.get(name, "")

def maybe(name: str):
    value = s(name)
    return value if value else None

def to_int(name: str):
    value = s(name)
    try:
        return int(value)
    except Exception:
        return None

def to_bool_flag(name: str) -> bool:
    return s(name) == "1"

def parse_state(line: str, path_name: str):
    cols = line.split("\t") if line else []
    cols += [""] * (7 - len(cols))
    state, pid, age, display, model, language, raw_target = cols[:7]
    try:
        age_value = int(age)
    except Exception:
        age_value = None
    return {
        "path": path_name,
        "state": state or "idle",
        "pid": int(pid) if pid.isdigit() else None,
        "age_seconds": age_value,
        "display_target": display or None,
        "model": model or None,
        "language": language or None,
        "raw_target": raw_target or None,
        "active": state == "active",
        "stale": state == "stale",
    }

overrides = {}
for line in s("JSON_ENV_OVERRIDES").splitlines():
    if not line:
        continue
    key, value = line.split("\t", 1)
    overrides[key] = value

data = {
    "command": "status",
    "summary": {
        "state": s("JSON_SUMMARY_STATE"),
        "headline": s("JSON_SUMMARY_HEADLINE"),
        "next_action": s("JSON_SUMMARY_NEXT_ACTION"),
        "active_flow": None if s("JSON_SUMMARY_ACTIVE_FLOW") in ("", "none") else s("JSON_SUMMARY_ACTIVE_FLOW"),
        "backend_readiness": s("JSON_BACKEND_READINESS"),
        "config_schema": {
            "version": s("JSON_CONFIG_SCHEMA_VERSION"),
            "status": s("JSON_CONFIG_SCHEMA_STATUS"),
            "parse_error": maybe("JSON_CONFIG_SCHEMA_PARSE_ERROR"),
        },
    },
    "runtime": {
        "tmux": parse_state(s("JSON_STATE_TMUX"), s("JSON_STATE_FILE_PATH")),
        "inline": parse_state(s("JSON_STATE_INLINE"), s("JSON_INLINE_STATE_FILE_PATH")),
        "processing_markers": {
            "path": s("JSON_PROC_DIR"),
            "total": to_int("JSON_PROC_TOTAL") or 0,
            "live": to_int("JSON_PROC_LIVE") or 0,
            "stale": to_int("JSON_PROC_STALE") or 0,
        },
        "tmux_queue": {
            "path": s("JSON_TMUX_JOBS_DIR"),
            "total": to_int("JSON_TMUX_TOTAL") or 0,
            "recording": to_int("JSON_TMUX_RECORDING") or 0,
            "processing": to_int("JSON_TMUX_PROCESSING") or 0,
        },
    },
    "effective_settings": {
        "backend": s("JSON_BACKEND"),
        "language": s("JSON_LANGUAGE"),
        "mode": {
            "inline": {
                "name": maybe("JSON_MODE_INLINE"),
                "display_name": maybe("JSON_MODE_INLINE_DISPLAY"),
                "source": s("JSON_MODE_INLINE_SOURCE"),
            },
            "tmux": {
                "name": maybe("JSON_MODE_TMUX"),
                "display_name": maybe("JSON_MODE_TMUX_DISPLAY"),
            },
        },
        "swift_parakeet": {
            "model": {
                "path": maybe("JSON_SWIFT_MODEL_PATH"),
                "version": maybe("JSON_SWIFT_MODEL_VERSION"),
            },
            "socket": s("JSON_SWIFT_SOCKET_PATH"),
        },
        "postprocess": {
            "inline": {
                "requested": to_bool_flag("JSON_POST_INLINE_REQUESTED"),
                "effective": to_bool_flag("JSON_POST_INLINE_EFFECTIVE"),
            },
            "tmux": {
                "requested": to_bool_flag("JSON_POST_TMUX_REQUESTED"),
                "effective": to_bool_flag("JSON_POST_TMUX_EFFECTIVE"),
            },
            "mode_prompt": {
                "inline": "active" if to_bool_flag("JSON_POST_INLINE_EFFECTIVE") else "inactive",
                "tmux": "active" if to_bool_flag("JSON_POST_TMUX_EFFECTIVE") else "inactive",
            },
            "cerebras_api_key_set": to_bool_flag("JSON_CEREBRAS_KEY_SET"),
            "note": maybe("JSON_POSTPROCESS_NOTE"),
        },
        "llm": {
            "model": s("JSON_LLM_MODEL"),
            "max_tokens": to_int("JSON_LLM_MAX_TOKENS"),
            "chunk_words": to_int("JSON_LLM_CHUNK_WORDS"),
        },
        "budget": {
            "auto_long_words_threshold": to_int("JSON_BUDGET_THRESHOLD"),
            "auto_numeric_sizing": "dynamic",
            "profiles": {
                "short": {
                    "llm": maybe("JSON_BUDGET_SHORT_LLM"),
                    "max_tokens": to_int("JSON_BUDGET_SHORT_MAX"),
                    "chunk_words": to_int("JSON_BUDGET_SHORT_CHUNK"),
                },
                "long": {
                    "llm": maybe("JSON_BUDGET_LONG_LLM"),
                    "max_tokens": to_int("JSON_BUDGET_LONG_MAX"),
                    "chunk_words": to_int("JSON_BUDGET_LONG_CHUNK"),
                },
            },
        },
        "british_spelling": to_bool_flag("JSON_BRITISH_SPELLING"),
        "clean": {
            "regex": to_bool_flag("JSON_CLEAN_REGEX"),
            "repeats_level": to_int("JSON_CLEAN_REPEATS_LEVEL"),
            "vocab_only_when_postprocess_off": to_bool_flag("JSON_CLEAN_VOCAB_ONLY"),
        },
        "silence_trim": {
            "enabled": to_bool_flag("JSON_SILENCE_TRIM"),
            "mode": s("JSON_SILENCE_TRIM_MODE"),
        },
        "inline": {
            "autosend": to_bool_flag("JSON_INLINE_AUTOSEND"),
            "process_sound": to_bool_flag("JSON_INLINE_PROCESS_SOUND"),
            "target": maybe("JSON_INLINE_TARGET"),
            "send_mode": maybe("JSON_INLINE_SEND_MODE"),
        },
        "tmux": {
            "autosend": to_bool_flag("JSON_TMUX_AUTOSEND"),
            "target": maybe("JSON_TMUX_TARGET"),
            "process_sound": to_bool_flag("JSON_TMUX_PROCESS_SOUND"),
            "send_mode": maybe("JSON_TMUX_SEND_MODE"),
        },
        "debug": {"keep_logs": to_bool_flag("JSON_KEEP_LOGS")},
        "audio": {
            "source": maybe("JSON_AUDIO_SOURCE"),
            "device_name": maybe("JSON_AUDIO_DEVICE_NAME"),
            "mac_name": maybe("JSON_AUDIO_MAC_NAME"),
            "iphone_name": maybe("JSON_AUDIO_IPHONE_NAME"),
            "device_index_fallback": to_int("JSON_AUDIO_DEVICE_INDEX_FALLBACK"),
            "index_resolved": {
                "index": to_int("JSON_AUDIO_INDEX_RESOLVED"),
                "source": maybe("JSON_AUDIO_INDEX_SOURCE"),
            },
        },
        "sounds": {
            "master": to_bool_flag("JSON_SOUND_MASTER"),
            "start": to_bool_flag("JSON_SOUND_START"),
            "stop": to_bool_flag("JSON_SOUND_STOP"),
            "process": to_bool_flag("JSON_SOUND_PROCESS"),
            "error": to_bool_flag("JSON_SOUND_ERROR"),
            "cancel": to_bool_flag("JSON_SOUND_CANCEL"),
        },
        "cerebras_api_key": s("JSON_KEY_STATUS"),
    },
    "active_env_overrides": overrides,
    "more_detail": [line for line in s("JSON_MORE_DETAIL").splitlines() if line],
}

print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
    return 0
  fi

  compact_state_brief() {
    local state="${1:-idle}"
    local pid="${2:-}"
    local age="${3:-}"
    if [[ "$state" == "active" ]]; then
      local parts=("active")
      [[ "$pid" =~ ^[0-9]+$ ]] && parts+=("pid=$pid")
      [[ "$age" =~ ^[0-9]+$ ]] && parts+=("age=${age}s")
      join_with_separator "," "${parts[@]}"
      return 0
    fi
    if [[ "$state" == "stale" ]]; then
      if [[ "$age" =~ ^[0-9]+$ ]]; then
        printf 'stale,age=%ss' "$age"
      else
        printf 'stale'
      fi
      return 0
    fi
    printf '%s' "${state:-idle}"
  }

  if [[ "$preset" == "compact" ]]; then
    echo "Tmux Whisper status (compact)"
    echo ""
    echo "Summary: state=$summary_state backend=$backend_readiness flow=$summary_active_flow config=${cfg_schema_version}/${cfg_schema_status}"
    echo "Modes: inline=$(mode_display_name "$mode_inline") [$mode_inline_source], tmux=$(mode_display_name "$mode_tmux")"
    echo "Runtime: tmux=$(compact_state_brief "$tmux_state" "$tmux_pid" "$tmux_age") inline=$(compact_state_brief "$inline_state_status" "$inline_pid" "$inline_age") proc=${proc_live:-0}/${proc_total:-0} stale=${proc_stale:-0} queue=${tmux_rec:-0}/${tmux_proc:-0}"
    echo "Headline: $summary_headline"
    echo "Next: $summary_next_action"
    echo "More: $(join_with_separator ' | ' "${more_detail_commands[@]}")"
    return 0
  fi

  echo "Tmux Whisper status"
  echo ""
  echo "Summary:"
  echo "  state: $summary_state"
  echo "  headline: $summary_headline"
  echo "  backend_readiness: $backend_readiness"
  echo "  active_flow: $summary_active_flow"
  echo "  next_action: $summary_next_action"
  echo ""
  echo "Runtime:"
  describe_state_file "tmux" "$STATE_FILE"
  describe_state_file "inline" "$inline_state"
  echo "  processing markers: total=${proc_total:-0} live=${proc_live:-0} stale=${proc_stale:-0}"
  echo "  tmux queue: total=${tmux_total:-0} recording=${tmux_rec:-0} processing=${tmux_proc:-0}"

  echo ""
  echo "Effective settings:"
  echo "  backend: $backend_requested"
  echo "  config.schema: ${cfg_schema_version} (status=${cfg_schema_status})"
  [[ -n "$cfg_parse_error" ]] && echo "  config.parse_error: $cfg_parse_error"
  [[ -n "$cfg_parse_error" ]] && echo "  config.source: ${CFG_CONFIG_SOURCE:-defaults}"
  echo "  mode.inline: $(mode_display_name "$mode_inline") ($mode_inline_source)"
  echo "  mode.tmux: $(mode_display_name "$mode_tmux")"
  echo "  swift_parakeet.model: ${swift_model_path:-<missing>} (${swift_model_version})"
  echo "  swift_parakeet.socket: $swift_socket_path"
  echo "  language: ${DICTATE_LANGUAGE:-en}"
  echo "  postprocess.inline: $(onoff "$post_inline")"
  echo "  postprocess.tmux: $(onoff "$post_tmux")"
  if [[ "$post_inline" == "1" ]]; then
    echo "  mode_prompt.inline: active"
  else
    echo "  mode_prompt.inline: inactive (postprocess not active)"
  fi
  if [[ "$post_tmux" == "1" ]]; then
    echo "  mode_prompt.tmux: active"
  else
    echo "  mode_prompt.tmux: inactive (postprocess not active)"
  fi
  if [[ "$cerebras_key_set" != "1" && ( "$post_inline_requested" == "1" || "$post_tmux_requested" == "1" ) ]]; then
    echo "  postprocess.note: disabled at runtime (CEREBRAS_API_KEY missing)"
  fi
  echo "  llm: $llm_model"
  [[ -n "$llm_max_tokens" ]] && echo "  llm.max_tokens: $llm_max_tokens"
  [[ -n "$llm_chunk_words" ]] && echo "  llm.chunk_words: $llm_chunk_words"
  echo "  budget.auto_long_words_threshold: ${CFG_POSTPROCESS_BUDGET_LONG_WORDS_THRESHOLD:-120}"
  echo "  budget.auto_numeric_sizing: dynamic (max_tokens/chunk_words interpolate short->long by transcript words; clamp at threshold)"
  echo "  budget_profile.short: llm=${budget_short_llm:-${CFG_POSTPROCESS_LLM:-llama3.1-8b}} max_tokens=${budget_short_max:-${CFG_POSTPROCESS_MAX_TOKENS:-<unset>}} chunk_words=${budget_short_chunk:-${CFG_POSTPROCESS_CHUNK_WORDS:-<unset>}}"
  echo "  budget_profile.long: llm=${budget_long_llm:-${CFG_POSTPROCESS_LLM:-llama3.1-8b}} max_tokens=${budget_long_max:-${CFG_POSTPROCESS_MAX_TOKENS:-<unset>}} chunk_words=${budget_long_chunk:-${CFG_POSTPROCESS_CHUNK_WORDS:-<unset>}}"
  echo "  british_spelling: $(onoff "${DICTATE_BRITISH_SPELLING:-1}")"
  echo "  clean.regex: $(onoff "$clean_enabled")"
  echo "  clean.repeats_level: $repeats_level"
  echo "  clean.vocab_only_when_postprocess_off: $(onoff "$vocab_clean")"
  echo "  silence_trim: $(onoff "$silence_trim") (${CFG_AUDIO_SILENCE_TRIM_MODE:-edges})"
  echo "  inline.autosend: $(onoff "$inline_autosend")"
  echo "  inline.process_sound: $(onoff "$inline_process_sound")"
  echo "  inline.target: $inline_target"
  echo "  inline.send_mode: $inline_send_mode"
  echo "  tmux.autosend: $(onoff "$tmux_autosend")"
  echo "  tmux.target: $tmux_target"
  echo "  tmux.process_sound: $(onoff "$tmux_process_sound")"
  echo "  tmux.send_mode: $tmux_send_mode"
  echo "  debug.keep_logs: $(onoff "$keep_logs_val")"
  echo "  audio.source: ${audio_source_mode}"
  echo "  audio.device_name: ${audio_name:-<none>}"
  echo "  audio.mac_name: ${CFG_AUDIO_MAC_NAME:-<none>}"
  echo "  audio.iphone_name: ${CFG_AUDIO_IPHONE_NAME:-<none>}"
  echo "  audio.device_index_fallback: ${CFG_AUDIO_DEVICE_INDEX:-<none>}"
  echo "  audio.index_resolved: ${audio_idx:-<none>} (source: $audio_src)"
  echo "  sounds: master=$(onoff "${CFG_AUDIO_SOUNDS_ENABLED:-1}") start=$(onoff "${CFG_AUDIO_SOUNDS_START_ENABLED:-1}") stop=$(onoff "${CFG_AUDIO_SOUNDS_STOP_ENABLED:-1}") process=$(onoff "${CFG_AUDIO_SOUNDS_PROCESS_ENABLED:-1}") error=$(onoff "${CFG_AUDIO_SOUNDS_ERROR_ENABLED:-1}") cancel=$(onoff "${CFG_AUDIO_SOUNDS_CANCEL_ENABLED:-1}")"
  echo "  cerebras_api_key: $key_status"

  echo ""
  echo "Active env overrides:"
  local shown=0 var val
  for var in "${override_vars[@]}"; do
    val="${!var-}"
    [[ -n "$val" ]] || continue
    if [[ "$var" == "CEREBRAS_API_KEY" ]]; then
      echo "  $var=<set>"
    else
      echo "  $var=$val"
    fi
    shown=$((shown + 1))
  done
  if [[ "$shown" -eq 0 ]]; then
    echo "  (none)"
  fi

  echo ""
  echo "More detail:"
  local command
  for command in "${more_detail_commands[@]}"; do
    echo "  $command"
  done
}
