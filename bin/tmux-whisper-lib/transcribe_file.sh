#!/usr/bin/env bash

# Audio-file transcription: `tmux-whisper transcribe <file>...`.
#
# Files are decoded by ffmpeg into a private 16 kHz mono WAV and sent to the
# same warm Parakeet daemon used for dictation. The original file is never
# handed to the dictation pipeline (which pads/trims its WAV in place), and the
# output is the raw transcript: no vocab, spelling, filler, or LLM
# cleanup. File transcripts are not deliveries, so they never touch history,
# the usage ledger, sounds, or paste targets.

transcribe_file_usage() {
  cat <<'EOF'
usage: tmux-whisper transcribe <file|->... [options]

Transcribe audio files (m4a, mp3, wav, aac, ogg/opus, flac, video audio
tracks — anything ffmpeg decodes) with the local Parakeet model and print the
raw transcript. Use `-` to read one file from stdin.

Output (default: stdout):
  -o, --output FILE   write to FILE (single input only)
  --beside            write <name>.txt (or .json) next to each input
  --out-dir DIR       write <name>.txt (or .json) into DIR
  -c, --clipboard     also copy the transcript(s) to the clipboard
  --force             overwrite existing output files

Format:
  --format txt|json   txt (default) or one JSON object per input:
                      {file, text, audio_duration_ms, processing_ms, model, engine}

Other:
  --no-tail-rescue    skip the extra pass over the final seconds of audio
  -q, --quiet         no progress messages on stderr

Long files keep the Parakeet daemon busy; dictation waits until they finish.
EOF
}

transcribe_file_log() {
  [[ "${TRANSCRIBE_FILE_QUIET:-0}" == "1" ]] && return 0
  printf '%s\n' "$*" >&2
}

transcribe_file_format_duration() {
  local ms="${1:-}"
  [[ "$ms" =~ ^[0-9]+$ ]] || { printf '%s' "unknown length"; return 0; }
  local total_s=$(( (ms + 500) / 1000 ))
  if (( total_s >= 3600 )); then
    printf '%dh %02dm %02ds' $(( total_s / 3600 )) $(( total_s % 3600 / 60 )) $(( total_s % 60 ))
  elif (( total_s >= 60 )); then
    printf '%dm %02ds' $(( total_s / 60 )) $(( total_s % 60 ))
  else
    printf '%ds' "$total_s"
  fi
}

transcribe_file_json_record() {
  local file="$1" text="$2" duration_ms="$3" processing_ms="$4" model="$5" engine="$6"
  TF_FILE="$file" TF_TEXT="$text" TF_DURATION="$duration_ms" TF_PROCESSING="$processing_ms" \
  TF_MODEL="$model" TF_ENGINE="$engine" python3 -c '
import json, os
def as_int(name):
    value = os.environ.get(name, "")
    return int(value) if value.isdigit() else None
print(json.dumps({
    "file": os.environ["TF_FILE"],
    "text": os.environ["TF_TEXT"],
    "audio_duration_ms": as_int("TF_DURATION"),
    "processing_ms": as_int("TF_PROCESSING"),
    "model": os.environ["TF_MODEL"],
    "engine": os.environ["TF_ENGINE"],
}, ensure_ascii=False))
'
}

# Publish an output file atomically so a failed run never leaves a partial one.
transcribe_file_write_output() {
  local dest="$1" content="$2" force="$3"
  if [[ -e "$dest" && "$force" != "1" ]]; then
    echo "tmux-whisper: output exists (use --force to overwrite): $dest" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null || {
    echo "tmux-whisper: cannot create output directory: $(dirname "$dest")" >&2
    return 1
  }
  local tmp
  tmp="$(mktemp "$(dirname "$dest")/.tmux-whisper-transcript.XXXXXX")" || {
    echo "tmux-whisper: cannot write output: $dest" >&2
    return 1
  }
  # Removed by the EXIT trap if the run is interrupted mid-write.
  TRANSCRIBE_FILE_PENDING_TMP="$tmp"
  # mktemp creates 0600; give the transcript normal umask-based permissions.
  chmod "$(printf '%o' $(( 0666 & ~$(umask) )))" "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$content" >"$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    TRANSCRIBE_FILE_PENDING_TMP=""
    echo "tmux-whisper: cannot write output: $dest" >&2
    return 1
  fi
  if [[ "$force" == "1" ]]; then
    mv -f "$tmp" "$dest"
  elif ln "$tmp" "$dest" 2>/dev/null; then
    # link(2) refuses atomically when the name exists, so a file that appeared
    # after the existence check is never replaced.
    rm -f "$tmp"
  elif [[ ! -e "$dest" ]]; then
    # Filesystems without hard links (exFAT/FAT recorders): -n still refuses
    # an existing file, with only a tiny check-then-rename window.
    mv -n "$tmp" "$dest"
  fi
  # A surviving temp file means the output was not published.
  if [[ -e "$tmp" ]]; then
    rm -f "$tmp" 2>/dev/null || true
    TRANSCRIBE_FILE_PENDING_TMP=""
    if [[ "$force" != "1" && -e "$dest" ]]; then
      echo "tmux-whisper: output exists (use --force to overwrite): $dest" >&2
    else
      echo "tmux-whisper: cannot write output: $dest" >&2
    fi
    return 1
  fi
  TRANSCRIBE_FILE_PENDING_TMP=""
  transcribe_file_log "Wrote $dest"
  return 0
}

# Usage: transcribe_file_destination <input> <output> <beside> <out_dir> <ext>
# Prints nothing when the transcript goes to stdout.
transcribe_file_destination() {
  local input="$1" output="$2" beside="$3" out_dir="$4" ext="$5" name
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
    return 0
  fi
  [[ "$beside" == "1" || -n "$out_dir" ]] || return 0
  name="$(basename "$input")"
  [[ "$name" == ?*.* ]] && name="${name%.*}"
  if [[ "$beside" == "1" ]]; then
    printf '%s\n' "$(dirname "$input")/$name.$ext"
  else
    printf '%s\n' "$out_dir/$name.$ext"
  fi
}

manage_transcribe() {
  local output="" out_dir="" beside="0" clipboard="0" force="0" format="txt"
  local tail_rescue="${DICTATE_SWIFT_PARAKEET_TAIL_RESCUE:-1}"
  local -a inputs=()
  TRANSCRIBE_FILE_QUIET=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) transcribe_file_usage; return 0 ;;
      -o|--output)
        [[ $# -ge 2 && -n "$2" ]] || die "transcribe: $1 requires a file path"
        output="$2"; shift ;;
      --output=*) output="${1#*=}" ;;
      --out-dir)
        [[ $# -ge 2 && -n "$2" ]] || die "transcribe: --out-dir requires a directory"
        out_dir="$2"; shift ;;
      --out-dir=*) out_dir="${1#*=}" ;;
      --beside) beside="1" ;;
      -c|--clipboard) clipboard="1" ;;
      --force) force="1" ;;
      --format)
        [[ $# -ge 2 ]] || die "transcribe: --format requires txt or json"
        format="$2"; shift ;;
      --format=*) format="${1#*=}" ;;
      --no-tail-rescue) tail_rescue="0" ;;
      -q|--quiet) TRANSCRIBE_FILE_QUIET=1 ;;
      --) shift; inputs+=("$@"); break ;;
      -) inputs+=("-") ;;
      -*) die "transcribe: unknown option: $1 (run: tmux-whisper transcribe --help)" ;;
      *) inputs+=("$1") ;;
    esac
    shift
  done

  case "$format" in
    txt|json) ;;
    *) die "transcribe: --format must be txt or json" ;;
  esac
  (( ${#inputs[@]} > 0 )) || { transcribe_file_usage >&2; exit 2; }

  local destinations=0
  [[ -n "$output" ]] && destinations=$((destinations + 1))
  [[ -n "$out_dir" ]] && destinations=$((destinations + 1))
  [[ "$beside" == "1" ]] && destinations=$((destinations + 1))
  (( destinations <= 1 )) || die "transcribe: use only one of -o, --out-dir, --beside"
  if [[ -n "$output" ]] && (( ${#inputs[@]} > 1 )); then
    die "transcribe: -o takes a single input; use --out-dir or --beside for several"
  fi

  local input stdin_count=0
  for input in "${inputs[@]}"; do
    if [[ "$input" == "-" ]]; then
      stdin_count=$((stdin_count + 1))
      continue
    fi
    [[ -f "$input" && -r "$input" ]] || die "transcribe: not a readable file: $input"
  done
  (( stdin_count <= 1 )) || die "transcribe: stdin (-) can only be used once"
  if (( stdin_count == 1 )) && [[ "$beside" == "1" || -n "$out_dir" ]]; then
    die "transcribe: stdin (-) has no file name; write to stdout or use -o"
  fi

  need ffmpeg
  need python3
  local model_path
  model_path="$(resolve_swift_parakeet_model_path 2>/dev/null || true)"
  [[ -n "$model_path" ]] || die "no local Parakeet model found. Expected under $DEFAULT_SWIFT_PARAKEET_MODELS_DIR or set swift_parakeet.model_path"

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-whisper-transcribe.XXXXXX")" || die "transcribe: cannot create a temporary directory"
  TRANSCRIBE_FILE_PENDING_TMP=""
  # shellcheck disable=SC2064
  trap "rm -rf '$work_dir'; [[ -z \"\${TRANSCRIBE_FILE_PENDING_TMP:-}\" ]] || rm -f \"\$TRANSCRIBE_FILE_PENDING_TMP\"" EXIT
  trap 'exit 130' INT TERM

  # Keep file jobs out of the dictation transcribe log, which the tmux worker
  # truncates and deletes.
  TRANSCRIBE_LOG="${DICTATE_TRANSCRIBE_FILE_LOG:-$TMPDIR/tmux-whisper-file.transcribe.log}"
  : >"$TRANSCRIBE_LOG" 2>/dev/null || TRANSCRIBE_LOG="/dev/null"

  # Start (or build) the daemon up front so a missing backend is reported
  # clearly instead of as a failure of the first file.
  local socket_path
  socket_path="$(resolve_swift_parakeet_socket_path)"
  if ! swift_parakeet_ping "$socket_path" >/dev/null 2>&1; then
    transcribe_file_log "Starting the Parakeet daemon (the first run after an install can take a few minutes)..."
    if ! ensure_swift_parakeet_daemon "$socket_path"; then
      if grep -q "error: Build failed" "$TRANSCRIBE_LOG" 2>/dev/null; then
        die "Parakeet daemon unavailable: building tmux-whisperd failed (see $TRANSCRIBE_LOG)"
      fi
      die "Parakeet daemon unavailable: could not start tmux-whisperd (see $TRANSCRIBE_LOG)"
    fi
  fi

  local base_timeout="${DICTATE_SWIFT_PARAKEET_TIMEOUT_SECONDS:-600}"
  [[ "$base_timeout" =~ ^[0-9]+$ ]] || base_timeout=600

  local total="${#inputs[@]}" index=0 failures=0 ext="$format"
  local combined="" label src wav duration_ms started_ms elapsed_ms text record dest timeout_s

  for input in "${inputs[@]}"; do
    index=$((index + 1))
    if [[ "$input" == "-" ]]; then
      label="stdin"
      src="$work_dir/stdin.input"
      if ! cat >"$src"; then
        echo "tmux-whisper: failed to read stdin" >&2
        failures=$((failures + 1)); continue
      fi
    else
      label="$input"
      src="$input"
    fi

    # Resolve the destination first so an existing output fails fast instead
    # of after a long transcription.
    dest="$(transcribe_file_destination "$input" "$output" "$beside" "$out_dir" "$ext")"
    if [[ -n "$dest" ]]; then
      if [[ "$dest" -ef "$input" ]]; then
        echo "tmux-whisper: refusing to overwrite the input file: $input" >&2
        failures=$((failures + 1)); continue
      fi
      if [[ -e "$dest" && "$force" != "1" ]]; then
        echo "tmux-whisper: output exists (use --force to overwrite): $dest" >&2
        failures=$((failures + 1)); continue
      fi
    fi

    wav="$work_dir/input-$index.wav"
    # Decode to a private copy; pad sub-second clips to the 1s Parakeet minimum.
    if ! ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" -vn \
      -af "apad=whole_dur=1.05" -ac 1 -ar 16000 -c:a pcm_s16le "$wav" \
      >>"$TRANSCRIBE_LOG" 2>&1; then
      echo "tmux-whisper: could not decode audio: $label (see $TRANSCRIBE_LOG)" >&2
      failures=$((failures + 1)); continue
    fi

    duration_ms="$(audio_duration_ms "$wav" 2>/dev/null || true)"
    if [[ "$duration_ms" == "0" ]]; then
      echo "tmux-whisper: no audio found in: $label" >&2
      failures=$((failures + 1)); continue
    fi

    # The daemon replies once at the end, so the socket read must outlast the
    # whole transcription of long files.
    timeout_s="$base_timeout"
    if [[ "$duration_ms" =~ ^[0-9]+$ ]] && (( duration_ms / 1000 > timeout_s )); then
      timeout_s=$(( duration_ms / 1000 ))
    fi

    if (( total > 1 )); then
      transcribe_file_log "[$index/$total] Transcribing $label ($(transcribe_file_format_duration "$duration_ms"))..."
    else
      transcribe_file_log "Transcribing $label ($(transcribe_file_format_duration "$duration_ms"))..."
    fi

    started_ms="$(now_ms)"
    DICTATE_LAST_BACKEND_ENGINE=""
    DICTATE_LAST_BACKEND_MODEL=""
    if ! text="$(DICTATE_SWIFT_PARAKEET_TIMEOUT_SECONDS="$timeout_s" \
      DICTATE_SWIFT_PARAKEET_TAIL_RESCUE="$tail_rescue" \
      transcribe_swift_parakeet_tail_rescue_cli "$wav" "${DICTATE_LANGUAGE:-en}" "file")"; then
      echo "tmux-whisper: transcription failed: $label (see $TRANSCRIBE_LOG)" >&2
      failures=$((failures + 1)); continue
    fi
    elapsed_ms=$(( $(now_ms) - started_ms ))
    text="$(printf '%s' "$text" | sanitize_transcript_artifacts)"

    if [[ -z "${text//[[:space:]]/}" ]]; then
      echo "tmux-whisper: no speech detected in: $label" >&2
      failures=$((failures + 1)); continue
    fi
    transcribe_file_log "Done in $(transcribe_file_format_duration "$elapsed_ms")."

    if [[ "$format" == "json" ]]; then
      record="$(transcribe_file_json_record "$label" "$text" "$duration_ms" "$elapsed_ms" \
        "${DICTATE_LAST_BACKEND_MODEL:-$(basename "$model_path")}" "${DICTATE_LAST_BACKEND_ENGINE:-swift_parakeet}")"
    else
      record="$text"
    fi

    if [[ -n "$dest" ]]; then
      transcribe_file_write_output "$dest" "$record" "$force" || { failures=$((failures + 1)); continue; }
    elif [[ "$format" == "txt" ]] && (( total > 1 )); then
      (( index > 1 )) && printf '\n'
      printf '==> %s <==\n%s\n' "$label" "$record"
    else
      printf '%s\n' "$record"
    fi

    if [[ -n "$combined" ]]; then
      combined+=$'\n\n'
    fi
    combined+="$text"
  done

  if [[ "$clipboard" == "1" && -n "$combined" ]]; then
    if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$combined" | pbcopy; then
      transcribe_file_log "Copied transcript to clipboard."
    else
      echo "tmux-whisper: could not copy to clipboard" >&2
      failures=$((failures + 1))
    fi
  fi

  (( failures == 0 )) || exit 1
}

# --- Finder Quick Action ------------------------------------------------------
# `tmux-whisper finder install` writes a Services workflow so Finder shows
# "Transcribe with Tmux Whisper" for audio/video files (right-click > Quick
# Actions). The workflow only locates and runs the installed handler script,
# so handler updates ship with normal upgrades.

FINDER_QUICK_ACTION_NAME="Transcribe with Tmux Whisper"

finder_quick_action_path() {
  printf '%s\n' "${DICTATE_SERVICES_DIR:-$HOME/Library/Services}/$FINDER_QUICK_ACTION_NAME.workflow"
}

finder_transcribe_handler_path() {
  local root candidate
  root="$(integration_source_root 2>/dev/null || true)"
  for candidate in \
    "${root:+$root/integrations/finder/tmux-whisper-transcribe.sh}" \
    "$SCRIPT_DIR/../share/tmux-whisper/integrations/finder/tmux-whisper-transcribe.sh" \
    "$SCRIPT_DIR/../integrations/finder/tmux-whisper-transcribe.sh"
  do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    (cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")")
    return 0
  done
  return 1
}

finder_write_quick_action() {
  local workflow="$1" handler="$2"
  FQA_WORKFLOW="$workflow" FQA_HANDLER="$handler" FQA_NAME="$FINDER_QUICK_ACTION_NAME" python3 - <<'PYEOF'
import os
import plistlib
import shlex

workflow = os.environ["FQA_WORKFLOW"]
handler = os.environ["FQA_HANDLER"]
name = os.environ["FQA_NAME"]
contents = os.path.join(workflow, "Contents")
os.makedirs(contents, exist_ok=True)

info = {
    "CFBundleDevelopmentRegion": "en_US",
    "CFBundleIdentifier": "com.ricardo-nth.tmux-whisper.transcribe-quick-action",
    "CFBundleName": name,
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "NSServices": [{
        "NSIconName": "NSActionTemplate",
        "NSMenuItem": {"default": name},
        "NSMessage": "runWorkflowAsService",
        "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
        "NSSendFileTypes": ["public.audio", "public.movie"],
    }],
}

command = f"""# Generated by `tmux-whisper finder install`.
for handler in {shlex.quote(handler)} \\
  "$HOME/.local/share/tmux-whisper/integrations/finder/tmux-whisper-transcribe.sh" \\
  /opt/homebrew/share/tmux-whisper/integrations/finder/tmux-whisper-transcribe.sh \\
  /usr/local/share/tmux-whisper/integrations/finder/tmux-whisper-transcribe.sh; do
  [ -x "$handler" ] && exec "$handler" "$@"
done
/usr/bin/osascript -e 'display notification "Handler not found. Run: tmux-whisper finder install" with title "Tmux Whisper"'
exit 1
"""

document = {
    "AMApplicationBuild": "533",
    "AMApplicationVersion": "2.10",
    "AMDocumentVersion": "2",
    "actions": [{
        "action": {
            "AMAccepts": {"Container": "List", "Optional": True, "Types": ["com.apple.cocoa.path"]},
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": {
                "COMMAND_STRING": {}, "CheckedForUserDefaultShell": {},
                "inputMethod": {}, "shell": {}, "source": {},
            },
            "AMProvides": {"Container": "List", "Types": ["com.apple.cocoa.string"]},
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script",
            "ActionParameters": {
                "COMMAND_STRING": command,
                "CheckedForUserDefaultShell": True,
                "inputMethod": 1,  # pass selected files as arguments
                "shell": "/bin/bash",
                "source": "",
            },
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": False,
            "CanShowWhenRun": True,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "UnlocalizedApplications": ["Automator"],
        },
        "isViewVisible": 1,
    }],
    "connectors": {},
    "workflowMetaData": {
        "serviceApplicationBundleID": "com.apple.finder",
        "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
        "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
        "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
        "serviceProcessesInput": 0,
        "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
    },
}

with open(os.path.join(contents, "Info.plist"), "wb") as fh:
    plistlib.dump(info, fh)
with open(os.path.join(contents, "document.wflow"), "wb") as fh:
    plistlib.dump(document, fh)
PYEOF
}

# Mark the service enabled for Finder's context menu, the same entry System
# Settings > Keyboard Shortcuts > Services writes. Only for the real Services
# folder, so tests with DICTATE_SERVICES_DIR never touch user preferences.
finder_enable_service() {
  [[ -z "${DICTATE_SERVICES_DIR:-}" ]] || return 0
  command -v defaults >/dev/null 2>&1 || return 0
  defaults write pbs NSServicesStatus -dict-add \
    "com.ricardo-nth.tmux-whisper.transcribe-quick-action - $FINDER_QUICK_ACTION_NAME - runWorkflowAsService" \
    '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "presentation_modes" = { ContextMenu = 1; FinderPreview = 1; ServicesMenu = 1; TouchBar = 0; }; }' \
    >/dev/null 2>&1 || true
}

finder_refresh_services() {
  [[ -x /System/Library/CoreServices/pbs ]] || return 0
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
}

manage_finder() {
  local action="${1:-status}"
  local workflow handler
  workflow="$(finder_quick_action_path)"

  case "$action" in
    status|"")
      handler="$(finder_transcribe_handler_path 2>/dev/null || true)"
      echo "Finder Quick Action: $FINDER_QUICK_ACTION_NAME"
      echo "  workflow: $workflow ($([[ -f "$workflow/Contents/document.wflow" ]] && echo installed || echo "not installed"))"
      echo "  handler: ${handler:-not found}"
      echo "  log: ${DICTATE_FINDER_TRANSCRIBE_LOG:-/tmp/tmux-whisper-finder.log}"
      [[ -f "$workflow/Contents/document.wflow" ]] || echo "Install with: tmux-whisper finder install"
      ;;
    install)
      need python3
      handler="$(finder_transcribe_handler_path)" || die "Finder handler script not found; reinstall tmux-whisper (./install.sh --force or brew reinstall)"
      if [[ -e "$workflow" ]]; then
        rm -rf "$workflow" || die "cannot replace $workflow"
      fi
      finder_write_quick_action "$workflow" "$handler" || die "failed to write $workflow"
      finder_enable_service
      finder_refresh_services
      echo "Installed Finder Quick Action: $FINDER_QUICK_ACTION_NAME"
      echo "  workflow: $workflow"
      echo "  handler: $handler"
      echo "Right-click audio files in Finder > Quick Actions > $FINDER_QUICK_ACTION_NAME."
      echo "It writes <name>.txt next to each file and copies the transcript to the clipboard."
      echo "If it doesn't appear yet, relaunch Finder (Option-right-click its Dock icon > Relaunch)."
      ;;
    remove|uninstall)
      if [[ -e "$workflow" ]]; then
        rm -rf "$workflow" || die "cannot remove $workflow"
        finder_refresh_services
        echo "Removed Finder Quick Action: $workflow"
      else
        echo "Finder Quick Action not installed: $workflow"
      fi
      ;;
    *) die "usage: tmux-whisper finder [status|install|remove]" ;;
  esac
}
