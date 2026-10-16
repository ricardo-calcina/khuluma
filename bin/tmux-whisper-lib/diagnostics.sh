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

collect_set_env_overrides() {
  local var val
  for var in "$@"; do
    val="${!var-}"
    [[ -n "$val" ]] || continue
    printf '%s\t%s\n' "$var" "$val"
  done
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

  local shared_lib_ok="0" internal_lib_ok="0" config_file_ok="0"
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

  local vocab_path vocab_present="0" vocab_rules="0" legacy_modes="0"
  vocab_path="$DICTATE_CONFIG_DIR/vocab"
  if [[ -f "$vocab_path" ]]; then
    vocab_present="1"
    vocab_rules="$(vocab_rule_count "$vocab_path")"
  fi
  if legacy_modes_present; then
    legacy_modes="1"
    warnings=$((warnings + 1))
    doctor_json_add_suggestion "Fold the old modes/*/vocab into vocab: tmux-whisper migrate-modes"
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
    JSON_VOCAB_PATH="$vocab_path" \
    JSON_VOCAB_PRESENT="$vocab_present" \
    JSON_VOCAB_RULES="$vocab_rules" \
    JSON_LEGACY_MODES="$legacy_modes" \
    JSON_PROC_DIR="$proc_dir" \
    JSON_PROC_TOTAL="$proc_total" \
    JSON_PROC_LIVE="$proc_live" \
    JSON_PROC_STALE="$proc_stale" \
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
    "vocab": {
        "path": s("JSON_VOCAB_PATH"),
        "present": to_bool_flag("JSON_VOCAB_PRESENT"),
        "rules": to_int("JSON_VOCAB_RULES") or 0,
        "legacy_modes_present": to_bool_flag("JSON_LEGACY_MODES"),
    },
    "processing_markers": {
        "path": s("JSON_PROC_DIR"),
        "total": to_int("JSON_PROC_TOTAL") or 0,
        "live": to_int("JSON_PROC_LIVE") or 0,
        "stale": to_int("JSON_PROC_STALE") or 0,
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
        swift) add_suggestion "Install Swift/Xcode so tmux-whisperd can be built" ;;
      esac
    fi
  }

  echo "Dependencies:"
  check_required_dep python3
  check_required_dep ffmpeg
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

  echo "Vocab:"
  if [[ -f "$DICTATE_CONFIG_DIR/vocab" ]]; then
    echo "  - vocab: $DICTATE_CONFIG_DIR/vocab ($(vocab_rule_count "$DICTATE_CONFIG_DIR/vocab") rules)"
  else
    echo "  - vocab: none yet (add with: tmux-whisper vocab add \"wrong::right\")"
  fi
  if legacy_modes_present; then
    warnings=$((warnings + 1))
    echo "  - modes/: found but no longer read (modes were removed in v0.11)"
    add_suggestion "Fold the old modes/*/vocab into vocab: tmux-whisper migrate-modes"
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

  local backend_requested swift_model_path swift_model_version swift_socket_path
  backend_requested="$(resolve_transcribe_backend)"
  swift_model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  swift_model_version="$(resolve_swift_parakeet_model_version "${swift_model_path:-}")"
  swift_socket_path="$(resolve_swift_parakeet_socket_path)"

  local inline_autosend inline_process_sound inline_target inline_send_mode
  inline_autosend="${DICTATE_AUTOSEND:-${CFG_INLINE_AUTOSEND:-1}}"
  inline_process_sound="${DICTATE_INLINE_PROCESS_SOUND:-${CFG_INLINE_PROCESS_SOUND:-1}}"
  inline_target="$(inline_paste_target_label "${DICTATE_INLINE_PASTE_TARGET:-${CFG_INLINE_PASTE_TARGET:-restore}}")"
  inline_send_mode="$(inline_send_mode_label "${DICTATE_INLINE_SEND_MODE:-${CFG_INLINE_SEND_MODE:-enter}}")"
  local keep_logs_val
  keep_logs_val="${DICTATE_KEEP_LOGS:-${CFG_DEBUG_KEEP_LOGS:-0}}"

  local clean_enabled repeats_level
  clean_enabled="${DICTATE_CLEAN:-0}"
  repeats_level="${DICTATE_REPEATS_LEVEL:-${CFG_CLEAN_REPEATS_LEVEL:-1}}"
  local vocab_clean
  vocab_clean="${DICTATE_VOCAB_CLEAN:-1}"
  if bool_is_on "$vocab_clean"; then
    vocab_clean="1"
  else
    vocab_clean="0"
  fi

  local cfg_schema_status cfg_schema_version cfg_parse_error
  cfg_schema_status="$(config_schema_status)"
  cfg_schema_version="$(config_schema_version_label)"
  cfg_parse_error="${CFG_CONFIG_PARSE_ERROR:-}"

  local proc_total proc_live proc_stale
  read -r proc_total proc_live proc_stale < <(count_processing_markers)

  local backend_readiness summary_state summary_headline summary_next_action summary_active_flow
  local model_ready="0" socket_live="0"
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

  summary_active_flow="none"
  if [[ "$proc_live" -gt 0 ]]; then
    summary_state="processing"
    summary_active_flow="inline"
    summary_headline="Dictation is still processing a recent run."
    summary_next_action="Wait for transcription and paste to finish."
  elif [[ "$proc_stale" -gt 0 ]]; then
    summary_state="attention"
    summary_headline="Runtime markers look stale."
    summary_next_action="Run tmux-whisper doctor to inspect them."
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
    processing)
      more_detail_commands=(
        "tmux-whisper last"
        "tmux-whisper history sessions 5"
      )
      ;;
    attention|not_ready)
      more_detail_commands=(
        "tmux-whisper doctor"
        "tmux-whisper config repair --dry-run"
      )
      ;;
    *)
      more_detail_commands=(
        "tmux-whisper last"
        "tmux-whisper bench"
        "tmux-whisper history sessions 5"
      )
      ;;
  esac
  local more_detail_lines
  more_detail_lines="$(printf '%s\n' "${more_detail_commands[@]}")"

  local override_vars=(
    DICTATE_SWIFT_PARAKEET_MODEL_PATH DICTATE_SWIFT_PARAKEET_MODEL_VERSION DICTATE_SWIFT_PARAKEET_SOCKET_PATH
    DICTATE_VOCAB_CLEAN
    DICTATE_AUTOSEND
    DICTATE_INLINE_PASTE_TARGET DICTATE_INLINE_SEND_MODE
    DICTATE_INLINE_ACTIVATE_DELAY_MS DICTATE_INLINE_SEND_DELAY_MS
    DICTATE_CLEAN DICTATE_REPEATS_LEVEL DICTATE_BRITISH_SPELLING
    DICTATE_LANGUAGE
    DICTATE_KEEP_LOGS
  )
  local env_override_lines
  env_override_lines="$(collect_set_env_overrides "${override_vars[@]}")"

  if [[ "$output_format" == "json" ]]; then
    env \
      JSON_PROC_TOTAL="$proc_total" \
      JSON_PROC_LIVE="$proc_live" \
      JSON_PROC_STALE="$proc_stale" \
      JSON_PROC_DIR="$proc_dir" \
      JSON_SUMMARY_STATE="$summary_state" \
      JSON_SUMMARY_HEADLINE="$summary_headline" \
      JSON_SUMMARY_NEXT_ACTION="$summary_next_action" \
      JSON_SUMMARY_ACTIVE_FLOW="$summary_active_flow" \
      JSON_BACKEND_READINESS="$backend_readiness" \
      JSON_CONFIG_SCHEMA_VERSION="$cfg_schema_version" \
      JSON_CONFIG_SCHEMA_STATUS="$cfg_schema_status" \
      JSON_CONFIG_SCHEMA_PARSE_ERROR="$cfg_parse_error" \
      JSON_BACKEND="$backend_requested" \
      JSON_SWIFT_MODEL_PATH="$swift_model_path" \
      JSON_SWIFT_MODEL_VERSION="$swift_model_version" \
      JSON_SWIFT_SOCKET_PATH="$swift_socket_path" \
      JSON_LANGUAGE="${DICTATE_LANGUAGE:-en}" \
      JSON_BRITISH_SPELLING="${DICTATE_BRITISH_SPELLING:-1}" \
      JSON_CLEAN_REGEX="$clean_enabled" \
      JSON_CLEAN_REPEATS_LEVEL="$repeats_level" \
      JSON_CLEAN_VOCAB="$vocab_clean" \
      JSON_INLINE_AUTOSEND="$inline_autosend" \
      JSON_INLINE_PROCESS_SOUND="$inline_process_sound" \
      JSON_INLINE_TARGET="$inline_target" \
      JSON_INLINE_SEND_MODE="$inline_send_mode" \
      JSON_KEEP_LOGS="$keep_logs_val" \
      JSON_SOUND_MASTER="${CFG_AUDIO_SOUNDS_ENABLED:-1}" \
      JSON_SOUND_START="${CFG_AUDIO_SOUNDS_START_ENABLED:-1}" \
      JSON_SOUND_STOP="${CFG_AUDIO_SOUNDS_STOP_ENABLED:-1}" \
      JSON_SOUND_PROCESS="${CFG_AUDIO_SOUNDS_PROCESS_ENABLED:-1}" \
      JSON_SOUND_ERROR="${CFG_AUDIO_SOUNDS_ERROR_ENABLED:-1}" \
      JSON_SOUND_CANCEL="${CFG_AUDIO_SOUNDS_CANCEL_ENABLED:-1}" \
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
        "processing_markers": {
            "path": s("JSON_PROC_DIR"),
            "total": to_int("JSON_PROC_TOTAL") or 0,
            "live": to_int("JSON_PROC_LIVE") or 0,
            "stale": to_int("JSON_PROC_STALE") or 0,
        },
    },
    "effective_settings": {
        "backend": s("JSON_BACKEND"),
        "language": s("JSON_LANGUAGE"),
        "swift_parakeet": {
            "model": {
                "path": maybe("JSON_SWIFT_MODEL_PATH"),
                "version": maybe("JSON_SWIFT_MODEL_VERSION"),
            },
            "socket": s("JSON_SWIFT_SOCKET_PATH"),
        },
        "british_spelling": to_bool_flag("JSON_BRITISH_SPELLING"),
        "clean": {
            "regex": to_bool_flag("JSON_CLEAN_REGEX"),
            "repeats_level": to_int("JSON_CLEAN_REPEATS_LEVEL"),
            "vocab": to_bool_flag("JSON_CLEAN_VOCAB"),
        },
        "inline": {
            "autosend": to_bool_flag("JSON_INLINE_AUTOSEND"),
            "process_sound": to_bool_flag("JSON_INLINE_PROCESS_SOUND"),
            "target": maybe("JSON_INLINE_TARGET"),
            "send_mode": maybe("JSON_INLINE_SEND_MODE"),
        },
        "debug": {"keep_logs": to_bool_flag("JSON_KEEP_LOGS")},
        "sounds": {
            "master": to_bool_flag("JSON_SOUND_MASTER"),
            "start": to_bool_flag("JSON_SOUND_START"),
            "stop": to_bool_flag("JSON_SOUND_STOP"),
            "process": to_bool_flag("JSON_SOUND_PROCESS"),
            "error": to_bool_flag("JSON_SOUND_ERROR"),
            "cancel": to_bool_flag("JSON_SOUND_CANCEL"),
        },
    },
    "active_env_overrides": overrides,
    "more_detail": [line for line in s("JSON_MORE_DETAIL").splitlines() if line],
}

print(json.dumps(data, indent=2, sort_keys=True))
PYEOF
    return 0
  fi

  if [[ "$preset" == "compact" ]]; then
    echo "Tmux Whisper status (compact)"
    echo ""
    echo "Summary: state=$summary_state backend=$backend_readiness flow=$summary_active_flow config=${cfg_schema_version}/${cfg_schema_status}"
    echo "Runtime: proc=${proc_live:-0}/${proc_total:-0} stale=${proc_stale:-0}"
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
  echo "  processing markers: total=${proc_total:-0} live=${proc_live:-0} stale=${proc_stale:-0}"

  echo ""
  echo "Effective settings:"
  echo "  backend: $backend_requested"
  echo "  config.schema: ${cfg_schema_version} (status=${cfg_schema_status})"
  [[ -n "$cfg_parse_error" ]] && echo "  config.parse_error: $cfg_parse_error"
  [[ -n "$cfg_parse_error" ]] && echo "  config.source: ${CFG_CONFIG_SOURCE:-defaults}"
  echo "  swift_parakeet.model: ${swift_model_path:-<missing>} (${swift_model_version})"
  echo "  swift_parakeet.socket: $swift_socket_path"
  echo "  language: ${DICTATE_LANGUAGE:-en}"
  echo "  british_spelling: $(onoff "${DICTATE_BRITISH_SPELLING:-1}")"
  echo "  clean.regex: $(onoff "$clean_enabled")"
  echo "  clean.repeats_level: $repeats_level"
  echo "  clean.vocab: $(onoff "$vocab_clean")"
  echo "  inline.autosend: $(onoff "$inline_autosend")"
  echo "  inline.process_sound: $(onoff "$inline_process_sound")"
  echo "  inline.target: $inline_target"
  echo "  inline.send_mode: $inline_send_mode"
  echo "  debug.keep_logs: $(onoff "$keep_logs_val")"
  echo "  sounds: master=$(onoff "${CFG_AUDIO_SOUNDS_ENABLED:-1}") start=$(onoff "${CFG_AUDIO_SOUNDS_START_ENABLED:-1}") stop=$(onoff "${CFG_AUDIO_SOUNDS_STOP_ENABLED:-1}") process=$(onoff "${CFG_AUDIO_SOUNDS_PROCESS_ENABLED:-1}") error=$(onoff "${CFG_AUDIO_SOUNDS_ERROR_ENABLED:-1}") cancel=$(onoff "${CFG_AUDIO_SOUNDS_CANCEL_ENABLED:-1}")"

  echo ""
  echo "Active env overrides:"
  local shown=0 var val
  for var in "${override_vars[@]}"; do
    val="${!var-}"
    [[ -n "$val" ]] || continue
    echo "  $var=$val"
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
