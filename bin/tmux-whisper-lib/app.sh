#!/usr/bin/env bash

# Back-end commands for the native menu-bar app. The app owns the hotkey,
# capture, sounds and paste/send; these commands give it settings and run the
# exact inline processing pipeline (transcription, cleanup, history, usage)
# without delivering the text.

app_delivery_settings_env() {
  local autosend="${DICTATE_AUTOSEND:-${CFG_INLINE_AUTOSEND:-1}}"
  local send_mode paste_target activate_delay_ms send_delay_ms
  send_mode="$(normalize_inline_send_mode "${DICTATE_INLINE_SEND_MODE:-${CFG_INLINE_SEND_MODE:-enter}}")"
  paste_target="$(normalize_inline_paste_target "${DICTATE_INLINE_PASTE_TARGET:-${CFG_INLINE_PASTE_TARGET:-restore}}")"
  activate_delay_ms="${DICTATE_INLINE_ACTIVATE_DELAY_MS:-90}"
  send_delay_ms="${DICTATE_INLINE_SEND_DELAY_MS:-35}"
  [[ "$activate_delay_ms" =~ ^[0-9]+$ ]] || activate_delay_ms=90
  [[ "$send_delay_ms" =~ ^[0-9]+$ ]] || send_delay_ms=35
  printf 'APP_AUTOSEND=%q\nAPP_SEND_MODE=%q\nAPP_PASTE_TARGET=%q\nAPP_ACTIVATE_DELAY_MS=%q\nAPP_SEND_DELAY_MS=%q\n' \
    "$autosend" "$send_mode" "$paste_target" "$activate_delay_ms" "$send_delay_ms"
}

# Cleanup settings exactly as the CLI resolves them (env, ~/.zshenv, config),
# kept as raw strings so the app can interpret them with the CLI's own rules.
# Prints one JSON object (the "cleanup" section of app-config).
app_cleanup_settings_json() {
  APPCLEAN_CONFIG_DIR="$DICTATE_CONFIG_DIR" \
  APPCLEAN_CLEAN="${DICTATE_CLEAN:-0}" \
  APPCLEAN_REPEATS_LEVEL="${DICTATE_REPEATS_LEVEL:-${CFG_CLEAN_REPEATS_LEVEL:-1}}" \
  APPCLEAN_VOCAB_CLEAN="${DICTATE_VOCAB_CLEAN:-1}" \
  APPCLEAN_BRITISH_SPELLING="${DICTATE_BRITISH_SPELLING:-1}" \
  APPCLEAN_CODE_PARAGRAPH_MIN_WORDS="${DICTATE_CODE_PARAGRAPH_MIN_WORDS:-70}" \
  APPCLEAN_LONG_PARAGRAPH_MIN_WORDS="${DICTATE_LONG_PARAGRAPH_MIN_WORDS:-55}" \
  APPCLEAN_FORCE_MODE="${DICTATE_FORCE_MODE:-}" \
  APPCLEAN_POSTPROCESS="$(resolve_inline_postprocess_effective)" \
  APPCLEAN_LOCALE_CTYPE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" \
  APPCLEAN_LOCALE_COLLATE="${LC_ALL:-${LC_COLLATE:-${LANG:-}}}" \
  APPCLEAN_CHILD_LC_ALL="$(printenv LC_ALL || true)" \
  APPCLEAN_CHILD_LC_CTYPE="$(printenv LC_CTYPE || true)" \
  APPCLEAN_CHILD_LC_COLLATE="$(printenv LC_COLLATE || true)" \
  APPCLEAN_CHILD_LANG="$(printenv LANG || true)" \
  python3 - <<'PYEOF'
import json, os
e = os.environ

C_LOCALES = ("", "C", "POSIX")

def effective_locale(category):
    # The shell's own view (APPCLEAN_LOCALE_*, which includes unexported
    # variables from ~/.zshenv) and the exported environment that grep/sed/sort
    # inherit (APPCLEAN_CHILD_*, read with printenv) can disagree; report a
    # non-C value if either side has one. Not os.environ: Python coerces a C
    # locale to LC_CTYPE=C.UTF-8 in its own environment (PEP 538).
    shell = e["APPCLEAN_LOCALE_" + category]
    child = (e["APPCLEAN_CHILD_LC_ALL"] or e["APPCLEAN_CHILD_LC_" + category]
             or e["APPCLEAN_CHILD_LANG"] or "")
    return shell if shell not in C_LOCALES else child

print(json.dumps({
    "config_dir": e["APPCLEAN_CONFIG_DIR"],
    "clean": e["APPCLEAN_CLEAN"],
    "repeats_level": e["APPCLEAN_REPEATS_LEVEL"],
    "vocab_clean": e["APPCLEAN_VOCAB_CLEAN"],
    "british_spelling": e["APPCLEAN_BRITISH_SPELLING"],
    "code_paragraph_min_words": e["APPCLEAN_CODE_PARAGRAPH_MIN_WORDS"],
    "long_paragraph_min_words": e["APPCLEAN_LONG_PARAGRAPH_MIN_WORDS"],
    "force_mode": e["APPCLEAN_FORCE_MODE"] or None,
    "postprocess": e["APPCLEAN_POSTPROCESS"] == "1",
    # Mode detection (grep -i, sed, glob order) and the blank check depend on
    # these; the native pipeline only reproduces the C locale.
    "locale_ctype": effective_locale("CTYPE"),
    "locale_collate": effective_locale("COLLATE"),
}))
PYEOF
}

# Transcription settings for Lowkey's native path, resolved as the CLI's
# inline transcription would use them. Numeric env overrides stay raw strings
# so the app can apply the CLI's exact parsing (and fall back when unsure).
app_transcription_settings_json() {
  local model_path model_version="" ffmpeg_ok="0" silence_trim="0" keep_logs="0" tail_rescue="0" chunking="0"
  model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  [[ -n "$model_path" ]] && model_version="$(resolve_swift_parakeet_model_version "$model_path")"
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && ffmpeg_ok="1"
  bool_is_on "${DICTATE_SILENCE_TRIM:-${CFG_AUDIO_SILENCE_TRIM:-0}}" && silence_trim="1"
  keep_logs_enabled && keep_logs="1"
  bool_is_on "${DICTATE_SWIFT_PARAKEET_TAIL_RESCUE:-1}" && tail_rescue="1"
  bool_is_on "${DICTATE_SWIFT_PARAKEET_CHUNKING:-0}" && chunking="1"

  APPTR_SOCKET="$(resolve_swift_parakeet_socket_path)" \
  APPTR_MODEL_PATH="$model_path" \
  APPTR_MODEL_VERSION="$model_version" \
  APPTR_MODEL_LABEL="$(current_transcribe_model_label)" \
  APPTR_LANGUAGE="${DICTATE_LANGUAGE:-en}" \
  APPTR_TAIL_PAD_MS="${DICTATE_TRANSCRIBE_TAIL_PAD_MS:-500}" \
  APPTR_TAIL_RESCUE="$tail_rescue" \
  APPTR_TAIL_RESCUE_MS="${DICTATE_SWIFT_PARAKEET_TAIL_RESCUE_MS:-}" \
  APPTR_TAIL_RESCUE_MIN_MS="${DICTATE_SWIFT_PARAKEET_TAIL_RESCUE_MIN_MS:-}" \
  APPTR_CHUNKING="$chunking" \
  APPTR_SILENCE_TRIM="$silence_trim" \
  APPTR_KEEP_LOGS="$keep_logs" \
  APPTR_FFMPEG="$ffmpeg_ok" \
  APPTR_TIMEOUT="${DICTATE_SWIFT_PARAKEET_TIMEOUT_SECONDS:-600}" \
  APPTR_PROCESSING_DIR="$PROCESSING_DIR" \
  python3 - <<'PYEOF'
import json, os
e = os.environ
flag = lambda name: e[name] == "1"
print(json.dumps({
    "socket_path": e["APPTR_SOCKET"],
    "model_path": e["APPTR_MODEL_PATH"] or None,
    "model_version": e["APPTR_MODEL_VERSION"] or None,
    "model_label": e["APPTR_MODEL_LABEL"],
    "language": e["APPTR_LANGUAGE"],
    "tail_pad_ms": e["APPTR_TAIL_PAD_MS"],
    "tail_rescue": flag("APPTR_TAIL_RESCUE"),
    "tail_rescue_ms": e["APPTR_TAIL_RESCUE_MS"],
    "tail_rescue_min_ms": e["APPTR_TAIL_RESCUE_MIN_MS"],
    "chunking": flag("APPTR_CHUNKING"),
    "silence_trim": flag("APPTR_SILENCE_TRIM"),
    "keep_logs": flag("APPTR_KEEP_LOGS"),
    "ffmpeg": flag("APPTR_FFMPEG"),
    "timeout_seconds": e["APPTR_TIMEOUT"],
    "processing_dir": e["APPTR_PROCESSING_DIR"],
}))
PYEOF
}

# tmux-whisper app-config --json
app_config_json() {
  [[ "${1:-}" == "--json" || -z "${1:-}" ]] || die "usage: tmux-whisper app-config --json"
  need python3
  eval "$(app_delivery_settings_env)"
  local event
  local -a sound_env=()
  for event in start stop process error cancel; do
    sound_env+=("APPCFG_SOUND_${event}_PATH=$(dictate_sound_path "$event" 2>/dev/null || true)")
    if sound_enabled "$event"; then
      sound_env+=("APPCFG_SOUND_${event}_ENABLED=1")
    else
      sound_env+=("APPCFG_SOUND_${event}_ENABLED=0")
    fi
  done

  env "${sound_env[@]}" \
    APPCFG_CLI_VERSION="$TMUX_WHISPER_CLI_VERSION" \
    APPCFG_HOTKEY="${DICTATE_APP_HOTKEY:-${CFG_APP_HOTKEY:-ctrl+option+space}}" \
    APPCFG_AUTOSEND="$APP_AUTOSEND" \
    APPCFG_SEND_MODE="$APP_SEND_MODE" \
    APPCFG_PASTE_TARGET="$APP_PASTE_TARGET" \
    APPCFG_ACTIVATE_DELAY_MS="$APP_ACTIVATE_DELAY_MS" \
    APPCFG_SEND_DELAY_MS="$APP_SEND_DELAY_MS" \
    APPCFG_PROCESS_SOUND="${CFG_INLINE_PROCESS_SOUND:-1}" \
    APPCFG_CLEANUP_JSON="$(app_cleanup_settings_json)" \
    APPCFG_TRANSCRIPTION_JSON="$(app_transcription_settings_json)" \
    APPCFG_NATIVE_PIPELINE="${DICTATE_APP_NATIVE_PIPELINE:-${CFG_APP_NATIVE_PIPELINE:-1}}" \
    APPCFG_CONFIG_ERROR="${CFG_CONFIG_PARSE_ERROR:-}" \
    APPCFG_CONFIG_SOURCE="${CFG_CONFIG_SOURCE:-file}" \
    APPCFG_VERIFY_PIPELINE="${DICTATE_APP_VERIFY_PIPELINE:-${CFG_APP_VERIFY_PIPELINE:-1}}" \
    APPCFG_SUPERVISE_DAEMON="${DICTATE_APP_SUPERVISE_DAEMON:-${CFG_APP_SUPERVISE_DAEMON:-1}}" \
    python3 - <<'PYEOF'
import json, os
e = os.environ
def flag(name):
    return e.get(name, "0") == "1"
sounds = {}
for event in ("start", "stop", "process", "error", "cancel"):
    path = e.get(f"APPCFG_SOUND_{event}_PATH", "")
    sounds[event] = {"enabled": flag(f"APPCFG_SOUND_{event}_ENABLED") and bool(path), "path": path or None}
print(json.dumps({
    "schema_version": 1,
    "cli_version": e["APPCFG_CLI_VERSION"],
    "hotkey": e["APPCFG_HOTKEY"],
    "sounds": sounds,
    "inline": {
        "autosend": flag("APPCFG_AUTOSEND"),
        "send_mode": e["APPCFG_SEND_MODE"],
        "paste_target": e["APPCFG_PASTE_TARGET"],
        "process_sound": flag("APPCFG_PROCESS_SOUND"),
        "activate_delay_ms": int(e["APPCFG_ACTIVATE_DELAY_MS"]),
        "send_delay_ms": int(e["APPCFG_SEND_DELAY_MS"]),
    },
    "cleanup": json.loads(e["APPCFG_CLEANUP_JSON"]),
    "transcription": json.loads(e["APPCFG_TRANSCRIPTION_JSON"]),
    # config.toml failed to parse: settings come from the last valid copy
    # ("last_good") or, if there is none, the defaults.
    "config": {"error": e["APPCFG_CONFIG_ERROR"] or None, "source": e["APPCFG_CONFIG_SOURCE"]},
    "pipeline": {
        "native": e["APPCFG_NATIVE_PIPELINE"].lower() in ("1", "true", "yes", "on"),
        "verify": e["APPCFG_VERIFY_PIPELINE"].lower() in ("1", "true", "yes", "on"),
        # Lowkey keeps the daemon warm (it still never launches one itself).
        "supervise": e["APPCFG_SUPERVISE_DAEMON"].lower() in ("1", "true", "yes", "on"),
    },
    # What this CLI supports, so a newer app can tell an older CLI apart:
    # take_markers: Lowkey's whole-take markers count as busy and dead ones
    #   are pruned; lifecycle_lock: daemon starts/restarts are serialized;
    #   warmup_json: `warmup --json` reports ready/warming/unavailable.
    "capabilities": ["take_markers", "lifecycle_lock", "warmup_json"],
}))
PYEOF
}

# tmux-whisper inline process <wav> [--app NAME] [--record-ms N]
#   [--startup-ms N] [--started-at-ms EPOCH_MS] --json
# Prints one JSON object: {ok, status, text, raw_text, mode, message,
# delivery: {...}, timings: {...}}. Human progress goes to the log, never
# stdout. The caller owns the WAV file.
inline_process_json() {
  local wav="" app="" record_ms="0" startup_ms="0" started_at_ms=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) ;;
      --app) [[ $# -ge 2 ]] || die "inline process: --app requires a value"; app="$2"; shift ;;
      --record-ms) [[ $# -ge 2 ]] || die "inline process: --record-ms requires a value"; record_ms="$2"; shift ;;
      --startup-ms) [[ $# -ge 2 ]] || die "inline process: --startup-ms requires a value"; startup_ms="$2"; shift ;;
      --started-at-ms) [[ $# -ge 2 ]] || die "inline process: --started-at-ms requires a value"; started_at_ms="$2"; shift ;;
      -*) die "inline process: unknown option: $1" ;;
      *) [[ -z "$wav" ]] || die "inline process: only one WAV file"; wav="$1" ;;
    esac
    shift
  done
  [[ -n "$wav" ]] || die "usage: tmux-whisper inline process <wav> [--app NAME] [--record-ms N] --json"
  [[ -f "$wav" ]] || die "inline process: not a file: $wav"
  [[ "$record_ms" =~ ^[0-9]+$ ]] || record_ms=0
  [[ "$startup_ms" =~ ^[0-9]+$ ]] || startup_ms=0
  [[ "$started_at_ms" =~ ^[0-9]+$ ]] || started_at_ms=""
  need python3

  local log work_wav rc=0
  log="$(mktemp "${TMPDIR:-/tmp}/tmux-whisper-app-process.XXXXXX")" || die "inline process: cannot create a temporary file"
  # The pipeline pads/trims its WAV in place and removes it afterwards; work
  # on a private copy so the caller's file is left alone.
  work_wav="$(mktemp "${TMPDIR:-/tmp}/tmux-whisper-app-take.XXXXXX")" || die "inline process: cannot create a temporary file"
  # This runs as its own CLI process, so an EXIT trap also covers early exits.
  # shellcheck disable=SC2064
  trap "rm -f '$log' '$work_wav'" EXIT
  cp "$wav" "$work_wav" || die "inline process: cannot read $wav"
  INLINE_DELIVERY_MODE="external"
  INLINE_EXTERNAL_TEXT=""
  INLINE_EXTERNAL_RAW_TEXT=""
  INLINE_EXTERNAL_MODE=""
  INLINE_EXTERNAL_TIMINGS=""
  # An empty session id is never "superseded" by CLI inline recordings.
  process_inline_recording "$work_wav" "$app" "$(current_transcribe_model_label)" "$record_ms" \
    "$startup_ms" "0" "0" "0" "app:avaudioengine" "" "" "self" "$started_at_ms" >"$log" 2>&1 || rc=$?

  eval "$(app_delivery_settings_env)"
  APPPROC_RC="$rc" \
  APPPROC_TEXT="$INLINE_EXTERNAL_TEXT" \
  APPPROC_RAW="$INLINE_EXTERNAL_RAW_TEXT" \
  APPPROC_MODE="$INLINE_EXTERNAL_MODE" \
  APPPROC_TIMINGS="$INLINE_EXTERNAL_TIMINGS" \
  APPPROC_LOG="$log" \
  APPPROC_AUTOSEND="$APP_AUTOSEND" \
  APPPROC_SEND_MODE="$APP_SEND_MODE" \
  APPPROC_PASTE_TARGET="$APP_PASTE_TARGET" \
  APPPROC_ACTIVATE_DELAY_MS="$APP_ACTIVATE_DELAY_MS" \
  APPPROC_SEND_DELAY_MS="$APP_SEND_DELAY_MS" \
  python3 - <<'PYEOF'
import json, os
e = os.environ
lines = [l.strip() for l in open(e["APPPROC_LOG"], encoding="utf-8", errors="replace") if l.strip()]
text = e.get("APPPROC_TEXT", "")
ok = e.get("APPPROC_RC") == "0" and bool(text.strip())
if ok:
    status = "ok"
elif any("No speech detected" in l for l in lines):
    status = "no_speech"
elif any(l.startswith("Skipping stale inline result") for l in lines):
    status = "superseded"
else:
    status = "failed"
timings = {}
for part in e.get("APPPROC_TIMINGS", "").split():
    key, _, value = part.partition("=")
    if value.isdigit():
        timings[key] = int(value)
message = None if ok else (next((l for l in reversed(lines) if not l.startswith("⏳")), None) or "processing failed")
print(json.dumps({
    "ok": ok,
    "status": status,
    "text": text if ok else "",
    "raw_text": e.get("APPPROC_RAW", "") if ok else "",
    "mode": e.get("APPPROC_MODE") or None,
    "message": message,
    "delivery": {
        "autosend": e.get("APPPROC_AUTOSEND") == "1",
        "send_mode": e["APPPROC_SEND_MODE"],
        "paste_target": e["APPPROC_PASTE_TARGET"],
        "activate_delay_ms": int(e["APPPROC_ACTIVATE_DELAY_MS"]),
        "send_delay_ms": int(e["APPPROC_SEND_DELAY_MS"]),
    },
    "timings": timings,
}, ensure_ascii=False))
PYEOF
  rm -f "$log" "$work_wav" 2>/dev/null || true
  return 0
}

# tmux-whisper inline cleanup [--app NAME] --json   (transcript on stdin)
# Runs only the deterministic text cleanup of an inline take (artefacts,
# fillers/repeats, mode, vocab, paragraphs, British spelling), never the LLM.
# Used to generate Lowkey's TextPipeline parity fixtures and for shadow
# compares. Prints {ok, status, raw_text, text, mode, cleanup}.
inline_cleanup_json() {
  local app=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) ;;
      --app) [[ $# -ge 2 ]] || die "inline cleanup: --app requires a value"; app="$2"; shift ;;
      *) die "usage: tmux-whisper inline cleanup [--app NAME] --json < transcript" ;;
    esac
    shift
  done
  need python3

  local raw txt="" final="" mode="" status="no_speech"
  # $(...) drops trailing newlines, like the transcription capture does.
  raw="$(cat)"
  cleanup_raw_transcript "$raw" "0"
  txt="$CLEANUP_TEXT"
  if [[ -n "${txt//[[:space:]]/}" ]]; then
    status="ok"
    resolve_inline_mode "$app"
    mode="$RESOLVED_MODE"
    finish_transcript_text "$txt" "$mode" "0"
    final="$CLEANUP_TEXT"
  fi

  APPCLEANUP_STATUS="$status" \
  APPCLEANUP_RAW="$txt" \
  APPCLEANUP_TEXT="$final" \
  APPCLEANUP_MODE="$mode" \
  APPCLEANUP_SETTINGS="$(app_cleanup_settings_json)" \
  python3 - <<'PYEOF'
import json, os
e = os.environ
ok = e["APPCLEANUP_STATUS"] == "ok"
print(json.dumps({
    "ok": ok,
    "status": e["APPCLEANUP_STATUS"],
    "raw_text": e["APPCLEANUP_RAW"] if ok else "",
    "text": e["APPCLEANUP_TEXT"] if ok else "",
    "mode": e["APPCLEANUP_MODE"] if ok else None,
    "cleanup": json.loads(e["APPCLEANUP_SETTINGS"]),
}))
PYEOF
}

# tmux-whisper inline record --json   (one take as JSON on stdin)
# Persistence for Lowkey's native path, run after delivery: the same bench
# row, usage ledger entry and history file `inline process` writes, from the
# CLI's own writers so formats and locking stay single-sourced. Usage is only
# counted for a delivered take; status "recovered" (a take saved at quit and
# transcribed without pasting) gets history but no usage. Payload: take_id, status, delivered,
# raw_text, text, mode, app, record_ms, transcribe_ms, clean_ms, paste_ms,
# total_ms, startup_ms, started_at_ms, delivered_at_ms, capture_wav_ms,
# capture_wav_bytes, startup_source, and wav_path (the padded WAV, only with
# [debug] keep_logs; this command takes ownership and removes it).
inline_record_json() {
  [[ "${1:-}" == "--json" && $# -eq 1 ]] || die "usage: tmux-whisper inline record --json < take.json"
  need python3
  local payload shell_vars
  payload="$(cat)"
  shell_vars="$(APPREC_PAYLOAD="$payload" python3 - <<'PYEOF'
import json, os, re, shlex, sys
try:
    p = json.loads(os.environ["APPREC_PAYLOAD"])
    if not isinstance(p, dict):
        raise ValueError("payload must be an object")
except Exception as exc:
    sys.exit(f"inline record: invalid payload: {exc}")

def text(key):
    value = p.get(key)
    return "" if value is None else str(value)

def ms(key):
    value = p.get(key)
    return str(value) if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else ""

status = text("status")
if not re.fullmatch(r"[a-z_]+", status):
    sys.exit("inline record: status must be a lowercase word")
out = {
    "REC_TAKE_ID": text("take_id"),
    "REC_STATUS": status,
    "REC_DELIVERED": "1" if p.get("delivered") is True else "0",
    "REC_RAW": text("raw_text"),
    "REC_TEXT": text("text"),
    "REC_MODE": text("mode"),
    "REC_APP": text("app"),
    "REC_STARTUP_SOURCE": text("startup_source") or "app:native",
    "REC_WAV_PATH": text("wav_path"),
    "REC_MODEL": text("model"),
}
for key in ("record_ms", "transcribe_ms", "clean_ms", "paste_ms", "total_ms", "startup_ms",
            "started_at_ms", "delivered_at_ms", "capture_wav_ms", "capture_wav_bytes"):
    out["REC_" + key.upper()] = ms(key)
for key, value in out.items():
    print(f"{key}={shlex.quote(value)}")
PYEOF
)" || die "inline record: invalid payload"
  eval "$shell_vars"

  # Lowkey spools each take and replays leftovers at launch (after a quit
  # timeout or crash), so the same take can arrive twice: record it once.
  local ledger="$AUDIO_CACHE_DIR/recorded-takes"
  if [[ -n "$REC_TAKE_ID" && -f "$ledger" ]] && grep -qxF -- "$REC_TAKE_ID" "$ledger" 2>/dev/null; then
    APPREC_TAKE_ID="$REC_TAKE_ID" python3 -c '
import json, os
print(json.dumps({"ok": True, "take_id": os.environ["APPREC_TAKE_ID"], "duplicate": True,
                  "usage_recorded": True, "history_saved": True}))'
    return 0
  fi

  local model_id mode record_ms transcribe_ms clean_ms paste_ms total_ms usage_recorded="0" history_saved="0"
  # The app's snapshot of the model label; resolve it now only for older apps.
  model_id="${REC_MODEL:-$(current_transcribe_model_label)}"
  mode="${REC_MODE:-none}"
  record_ms="${REC_RECORD_MS:-0}"
  transcribe_ms="${REC_TRANSCRIBE_MS:-0}"
  clean_ms="${REC_CLEAN_MS:-0}"
  paste_ms="${REC_PASTE_MS:-0}"
  total_ms="${REC_TOTAL_MS:-0}"

  if [[ "$REC_STATUS" == "ok" && "$REC_DELIVERED" == "1" ]]; then
    local usage_full_elapsed_ms="$total_ms"
    if [[ "$REC_STARTED_AT_MS" =~ ^[0-9]+$ && "$REC_DELIVERED_AT_MS" =~ ^[0-9]+$ ]]; then
      usage_full_elapsed_ms=$(( REC_DELIVERED_AT_MS - REC_STARTED_AT_MS ))
      (( usage_full_elapsed_ms < 0 )) && usage_full_elapsed_ms=0
    fi
    if usage_record_delivery "inline" "$REC_TEXT" "$record_ms" "$usage_full_elapsed_ms"; then
      usage_recorded="1"
    else
      echo "[usage] unable to record delivered dictation summary" >&2
    fi
  fi

  append_bench_entry "inline" "$REC_STATUS" "$model_id" "$mode" "0" "${#REC_RAW}" "${#REC_TEXT}" \
    "$record_ms" "$transcribe_ms" "$clean_ms" "0" "$paste_ms" "$total_ms" \
    "${REC_STARTUP_MS:-0}" "0" "0" "0" "$REC_STARTUP_SOURCE"

  case "$REC_STATUS" in
    ok|no_speech|recovered) signal_just_processed ;;
    *)
      touch "$ERROR_FLAG" 2>/dev/null || true
      swiftbar_refresh
      ;;
  esac

  # Debug archive ([debug] keep_logs), as inline process writes it: the padded
  # WAV the app transcribed plus a .meta file. The app hands the WAV over;
  # archiving removes it.
  INLINE_CAPTURE_WAV_MS="$REC_CAPTURE_WAV_MS"
  INLINE_CAPTURE_WAV_BYTES="$REC_CAPTURE_WAV_BYTES"
  INLINE_CAPTURE_GAP_TO_RECORD_MS=""
  if [[ "$REC_CAPTURE_WAV_MS" =~ ^[0-9]+$ && "$record_ms" =~ ^[0-9]+$ ]]; then
    INLINE_CAPTURE_GAP_TO_RECORD_MS=$(( REC_CAPTURE_WAV_MS - record_ms ))
  fi
  if [[ -n "$REC_WAV_PATH" ]]; then
    local archive_prefix=""
    archive_prefix="$(inline_archive_prefix "${REC_TAKE_ID:-lowkey}" 2>/dev/null || true)"
    archive_inline_debug_artifacts "$archive_prefix" "$REC_WAV_PATH" "" "" "$REC_STATUS" \
      "$record_ms" "$transcribe_ms" "$clean_ms" "0" "$paste_ms" "$total_ms" "$REC_TAKE_ID"
  fi

  # A take recovered at quit was never pasted: history, but no usage.
  if [[ ( "$REC_STATUS" == "ok" && "$REC_DELIVERED" == "1" ) || "$REC_STATUS" == "recovered" ]]; then
    local history_app="${REC_APP:-current}"
    save_history "$REC_RAW" "$REC_TEXT" "$mode" "$history_app" "$record_ms" "$transcribe_ms" "$clean_ms" "0" "$paste_ms" "$total_ms" \
      && history_saved="1"
  fi

  # Mark the take recorded so a replay never counts usage twice. A recovered
  # take (no usage) whose history failed stays unmarked so a replay retries it.
  if [[ -n "$REC_TAKE_ID" && ( "$REC_STATUS" != "recovered" || "$history_saved" == "1" ) ]]; then
    mkdir -p "$AUDIO_CACHE_DIR" 2>/dev/null || true
    printf '%s\n' "$REC_TAKE_ID" >>"$ledger" 2>/dev/null || true
    if [[ "$(wc -l <"$ledger" 2>/dev/null | tr -d ' ')" -gt 1000 ]]; then
      tail -n 500 "$ledger" >"${ledger}.tmp.$$" 2>/dev/null && mv -f "${ledger}.tmp.$$" "$ledger" 2>/dev/null || true
    fi
  fi

  APPREC_TAKE_ID="$REC_TAKE_ID" APPREC_USAGE="$usage_recorded" APPREC_HISTORY="$history_saved" python3 -c '
import json, os
e = os.environ
print(json.dumps({"ok": True, "take_id": e["APPREC_TAKE_ID"], "duplicate": False, "usage_recorded": e["APPREC_USAGE"] == "1",
                  "history_saved": e["APPREC_HISTORY"] == "1"}))'
}
