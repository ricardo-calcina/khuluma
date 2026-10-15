#!/usr/bin/env bash

# History helpers are split out so operator-facing CLI work can evolve without
# adding more weight to the main runtime/dispatch file.

# Save a dictation to history
# Usage: save_history "raw_transcript" "processed_text" "mode" "app" [record_ms] [transcribe_ms] [clean_ms] [postprocess_ms] [paste_ms] [total_ms]
save_history() {
  local raw="$1"
  local processed="$2"
  local mode="${3:-unknown}"
  local app="${4:-unknown}"
  local record_ms="${5:-}"
  local transcribe_ms="${6:-}"
  local clean_ms="${7:-}"
  local postprocess_ms="${8:-}"
  local paste_ms="${9:-}"
  local total_ms="${10:-}"

  mkdir -p "$HISTORY_DIR"

  # Get retention days from config (default 7)
  local retention="${DICTATE_HISTORY_RETENTION_DAYS:-${CFG_HISTORY_RETENTION_DAYS:-7}}"
  [[ "$retention" =~ ^[0-9]+$ ]] || retention=7

  # Clean old entries first
  cleanup_history "$retention"

  # Generate timestamp filename. Claim it with noclobber so two takes saved
  # in the same second (Lowkey's background recorder plus a CLI flow) never
  # overwrite each other; later ones get _2, _3, ... which sort after it.
  local ts
  ts="$(date '+%Y-%m-%dT%H-%M-%S')"
  local filename="$HISTORY_DIR/${ts}.json"
  local collision=1
  while ! ( set -C; : >"$filename" ) 2>/dev/null; do
    collision=$((collision + 1))
    (( collision > 50 )) && break
    filename="$HISTORY_DIR/${ts}_${collision}.json"
  done

  # Escape for JSON
  local raw_escaped processed_escaped mode_escaped app_escaped
  raw_escaped="$(printf '%s' "$raw" | jq -Rs .)"
  processed_escaped="$(printf '%s' "$processed" | jq -Rs .)"
  mode_escaped="$(printf '%s' "$mode" | jq -Rs .)"
  app_escaped="$(printf '%s' "$app" | jq -Rs .)"

  local metrics_lines=""
  append_metric_line() {
    local key="$1"
    local val="$2"
    [[ "$val" =~ ^[0-9]+$ ]] || return 0
    if [[ -n "$metrics_lines" ]]; then
      metrics_lines="${metrics_lines},"$'\n'
    fi
    metrics_lines="${metrics_lines}    \"${key}\": ${val}"
  }
  append_metric_line "record_ms" "$record_ms"
  append_metric_line "transcribe_ms" "$transcribe_ms"
  append_metric_line "clean_ms" "$clean_ms"
  append_metric_line "postprocess_ms" "$postprocess_ms"
  append_metric_line "paste_ms" "$paste_ms"
  append_metric_line "total_ms" "$total_ms"

  local audio_lines=""
  append_audio_line() {
    local key="$1"
    local val="$2"
    local kind="${3:-number}"
    [[ -n "$val" ]] || return 0
    if [[ "$kind" == "number" ]]; then
      [[ "$val" =~ ^[0-9]+$ ]] || return 0
    fi
    if [[ -n "$audio_lines" ]]; then
      audio_lines="${audio_lines},"$'\n'
    fi
    if [[ "$kind" == "string" ]]; then
      local escaped
      escaped="$(printf '%s' "$val" | jq -Rs .)"
      audio_lines="${audio_lines}    \"${key}\": ${escaped}"
    else
      audio_lines="${audio_lines}    \"${key}\": ${val}"
    fi
  }
  append_audio_line "capture_wav_ms" "${INLINE_CAPTURE_WAV_MS:-}"
  append_audio_line "capture_wav_bytes" "${INLINE_CAPTURE_WAV_BYTES:-}"
  append_audio_line "capture_gap_to_record_ms" "${INLINE_CAPTURE_GAP_TO_RECORD_MS:-}"
  append_audio_line "capture_gap_to_record_plus_grace_ms" "${INLINE_CAPTURE_GAP_TO_RECORD_PLUS_GRACE_MS:-}"
  append_audio_line "archive_wav_ms" "${INLINE_ARCHIVE_WAV_MS:-}"
  append_audio_line "archive_wav_bytes" "${INLINE_ARCHIVE_WAV_BYTES:-}"
  append_audio_line "wav_retention_days" "${INLINE_DEBUG_WAV_RETENTION_DAYS:-}"
  append_audio_line "debug_archive_prefix" "${INLINE_DEBUG_ARCHIVE_PREFIX:-}" "string"
  append_audio_line "retention_note" "${INLINE_DEBUG_AUDIO_RETENTION_NOTE:-}" "string"

  local budget_obs_lines=""
  if [[ "${DICTATE_LAST_POSTPROCESS_BUDGET_OBS_ACTIVE:-0}" == "1" ]]; then
    local _profile _llm
    local profile_escaped llm_escaped
    _profile="${DICTATE_LAST_POSTPROCESS_BUDGET_PROFILE:-}"
    _llm="${DICTATE_LAST_POSTPROCESS_BUDGET_LLM_MODEL:-}"
    profile_escaped="$(printf '%s' "$_profile" | jq -Rs .)"
    llm_escaped="$(printf '%s' "$_llm" | jq -Rs .)"
    budget_obs_lines="    \"numeric_sizing\": \"auto_dynamic\","$'\n'
    budget_obs_lines="${budget_obs_lines}    \"profile\": ${profile_escaped}"
    [[ "${DICTATE_LAST_POSTPROCESS_BUDGET_THRESHOLD:-}" =~ ^[0-9]+$ ]] && budget_obs_lines="${budget_obs_lines},"$'\n'"    \"threshold_words\": ${DICTATE_LAST_POSTPROCESS_BUDGET_THRESHOLD}"
    [[ "${DICTATE_LAST_POSTPROCESS_BUDGET_WORD_COUNT:-}" =~ ^[0-9]+$ ]] && budget_obs_lines="${budget_obs_lines},"$'\n'"    \"word_count\": ${DICTATE_LAST_POSTPROCESS_BUDGET_WORD_COUNT}"
    [[ "${DICTATE_LAST_POSTPROCESS_BUDGET_MAX_TOKENS:-}" =~ ^[0-9]+$ ]] && budget_obs_lines="${budget_obs_lines},"$'\n'"    \"max_tokens\": ${DICTATE_LAST_POSTPROCESS_BUDGET_MAX_TOKENS}"
    [[ "${DICTATE_LAST_POSTPROCESS_BUDGET_CHUNK_WORDS:-}" =~ ^[0-9]+$ ]] && budget_obs_lines="${budget_obs_lines},"$'\n'"    \"chunk_words\": ${DICTATE_LAST_POSTPROCESS_BUDGET_CHUNK_WORDS}"
    [[ "${DICTATE_LAST_POSTPROCESS_BUDGET_CHUNK_COUNT:-}" =~ ^[0-9]+$ ]] && budget_obs_lines="${budget_obs_lines},"$'\n'"    \"chunk_count\": ${DICTATE_LAST_POSTPROCESS_BUDGET_CHUNK_COUNT}"
    [[ -n "$_llm" ]] && budget_obs_lines="${budget_obs_lines},"$'\n'"    \"llm\": ${llm_escaped}"
  fi

  local extra_fields=""
  if [[ -n "$metrics_lines" ]]; then
    extra_fields="${extra_fields},"$'\n'"  \"metrics\": {"$'\n'"${metrics_lines}"$'\n'"  }"
  fi
  if [[ -n "$audio_lines" ]]; then
    extra_fields="${extra_fields},"$'\n'"  \"audio\": {"$'\n'"${audio_lines}"$'\n'"  }"
  fi
  if [[ -n "$budget_obs_lines" ]]; then
    extra_fields="${extra_fields},"$'\n'"  \"postprocess_budget\": {"$'\n'"${budget_obs_lines}"$'\n'"  }"
  fi

  cat > "$filename" <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "mode": $mode_escaped,
  "app": $app_escaped,
  "raw": $raw_escaped,
  "processed": $processed_escaped${extra_fields}
}
EOF
}

# Remove history entries older than N days
cleanup_history() {
  local days="${1:-7}"
  [[ -d "$HISTORY_DIR" ]] || return 0

  # Find and delete files older than N days
  find "$HISTORY_DIR" -name "*.json" -type f -mtime +"$days" -delete 2>/dev/null || true
}

history_audio_retention_days() {
  local days="${DICTATE_HISTORY_AUDIO_RETENTION_DAYS:-${CFG_HISTORY_AUDIO_RETENTION_DAYS:-2}}"
  [[ "$days" =~ ^[0-9]+$ ]] || days=2
  printf "%s\n" "$days"
}

cleanup_inline_debug_audio() {
  local days="${1:-$(history_audio_retention_days)}"
  local dir
  dir="$(inline_debug_archive_dir 2>/dev/null || true)"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  [[ "$days" =~ ^[0-9]+$ ]] || days=2

  if [[ "$days" == "0" ]]; then
    find "$dir" -name "*.wav" -type f -delete 2>/dev/null || true
  else
    find "$dir" -name "*.wav" -type f -mtime +"$days" -delete 2>/dev/null || true
  fi
}

history_entry_file_by_index() {
  local n="${1:-1}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  [[ -d "$HISTORY_DIR" ]] || return 1
  ls -1t "$HISTORY_DIR"/*.json 2>/dev/null | sed -n "${n}p"
}

history_entry_json() {
  local n="${1:-1}"
  local file
  file="$(history_entry_file_by_index "$n")"
  if [[ -z "$file" || ! -f "$file" ]]; then
    die "history entry $n not found"
  fi

  jq --argjson index "$n" --arg file "$file" '
    {
      index: $index,
      file: $file,
      entry: .
    }
  ' "$file"
}

history_files_ordered() {
  local spec="${1:-all}"
  [[ -d "$HISTORY_DIR" ]] || return 0

  case "$spec" in
    ""|all)
      ls -1t "$HISTORY_DIR"/*.json 2>/dev/null || true
      ;;
    *)
      [[ "$spec" =~ ^[0-9]+$ ]] || die "history export expects N or all"
      ls -1t "$HISTORY_DIR"/*.json 2>/dev/null | head -n "$spec" || true
      ;;
  esac
}

history_typing_wpm_assumed() {
  local wpm="${DICTATE_HISTORY_TYPING_WPM:-40}"
  [[ "$wpm" =~ ^[0-9]+$ ]] || wpm=40
  if [[ "$wpm" -le 0 ]]; then
    wpm=40
  fi
  echo "$wpm"
}

history_format_duration_ms() {
  local ms="${1:-0}"
  if [[ ! "$ms" =~ ^-?[0-9]+$ ]]; then
    echo "?"
    return 0
  fi

  local sign=""
  if [[ "$ms" -lt 0 ]]; then
    sign="-"
    ms=$(( -ms ))
  fi

  awk -v ms="$ms" -v sign="$sign" '
    BEGIN {
      seconds = ms / 1000.0
      if (seconds < 60) {
        printf "%s%.1fs", sign, seconds
      } else if (seconds < 3600) {
        mins = int(seconds / 60)
        secs = int(seconds + 0.5) - (mins * 60)
        if (secs >= 60) {
          mins += 1
          secs -= 60
        }
        printf "%s%dm %02ds", sign, mins, secs
      } else {
        hours = int(seconds / 3600)
        mins = int((seconds - (hours * 3600)) / 60)
        secs = int(seconds + 0.5) - (hours * 3600) - (mins * 60)
        if (secs >= 60) {
          mins += 1
          secs -= 60
        }
        if (mins >= 60) {
          hours += 1
          mins -= 60
        }
        printf "%s%dh %02dm %02ds", sign, hours, mins, secs
      }
    }
  '
}

history_format_signed_duration_ms() {
  local ms="${1:-0}"
  if [[ ! "$ms" =~ ^-?[0-9]+$ ]]; then
    echo "?"
    return 0
  fi
  if [[ "$ms" -gt 0 ]]; then
    printf '+%s\n' "$(history_format_duration_ms "$ms")"
  else
    history_format_duration_ms "$ms"
  fi
}

# Durable, transcript-free accounting for successful deliveries. This ledger is
# intentionally separate from history/: transcript retention can prune history
# without changing the usage total or implying older data was recovered.
usage_summary_file() {
  printf '%s\n' "${DICTATE_USAGE_SUMMARY_FILE:-$DICTATE_CONFIG_DIR/usage.json}"
}

# Record exactly one completed delivery. Python's advisory lock serializes
# concurrent inline/tmux workers; writing a fsynced temporary file and replacing
# it means readers only ever see a complete previous or next JSON document.
#
# Each delivery also lands in a per-day bucket (`daily.days`, keyed by the
# local calendar date of the delivery) for streaks, records and activity.
# `daily.baseline_count` is the total before the delivery that created the
# section, so deliveries an older writer recorded without a bucket stay
# visible as untracked. A malformed `daily` never costs a delivery: totals
# are still recorded and the section is left alone. A take id makes the
# write exactly-once: ids live in `recent_take_ids` (pruned after 14 days),
# checked and updated in the same locked write as the totals.
# Usage: usage_record_delivery <inline|tmux> <processed_text> <record_ms> <full_elapsed_ms>
#          [--take-id ID] [--local-date YYYY-MM-DD]
usage_record_delivery() {
  local flow="${1:-}"
  local processed="${2:-}"
  local record_ms="${3:-0}"
  local full_elapsed_ms="${4:-0}"
  local take_id="" local_date=""
  if [[ $# -ge 4 ]]; then shift 4; else set --; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --take-id) [[ $# -ge 2 ]] || return 1; take_id="$2"; shift 2 ;;
      --local-date) [[ $# -ge 2 ]] || return 1; local_date="$2"; shift 2 ;;
      *) return 1 ;;
    esac
  done
  [[ "$flow" == "inline" || "$flow" == "tmux" ]] || return 1
  [[ "$record_ms" =~ ^[0-9]+$ ]] || return 1
  [[ "$full_elapsed_ms" =~ ^[0-9]+$ ]] || return 1
  # Return instead of `need`: a missing interpreter must not exit the worker.
  command -v python3 >/dev/null 2>&1 || return 1

  python3 -c '
import datetime
import fcntl
import json
import os
import re
import sys
import tempfile
import time

path, flow, record_ms, full_elapsed_ms, take_id, local_date = sys.argv[1:]
processed = sys.stdin.read()
TAKE_ID_DAYS = 14
TAKE_ID_MAX = 5000

def now_iso():
    override = os.environ.get("DICTATE_USAGE_NOW", "").strip()
    if override:
        return override
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def local_today(stamp):
    # The local calendar date of the same instant as `stamp` (system time
    # zone; TZ in tests).
    try:
        parsed = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        parsed = datetime.datetime.now(datetime.timezone.utc)
    return parsed.astimezone().date()

def civil_date(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None

def plain_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0

def as_nonnegative_int(value, name):
    if isinstance(value, bool):
        raise ValueError(f"usage summary {name} must be an integer")
    value = int(value)
    if value < 0:
        raise ValueError(f"usage summary {name} must not be negative")
    return value

os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
lock_path = path + ".lock"
with open(lock_path, "a+", encoding="utf-8") as lock:
    # Bounded wait: a stuck lock holder must never stall the delivery worker.
    deadline = time.monotonic() + 2.0
    while True:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise SystemExit("tmux-whisper: usage summary is locked by another process; skipping this delivery")
            time.sleep(0.05)
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                payload = json.load(fh)
        except Exception as exc:
            raise SystemExit(f"tmux-whisper: usage summary is unreadable; refusing to overwrite it: {exc}")
    else:
        payload = {
            "schema_version": 1,
            "tracking_started_at": now_iso(),
            "delivered_dictations": {"count": 0, "by_flow": {"inline": 0, "tmux": 0}},
            "processed_words": 0,
            "recording_duration_ms": 0,
            "full_elapsed_duration_ms": 0,
        }

    if payload.get("schema_version") != 1 or not isinstance(payload.get("delivered_dictations"), dict):
        raise SystemExit("tmux-whisper: unsupported usage summary schema; refusing to overwrite it")
    deliveries = payload["delivered_dictations"]
    by_flow = deliveries.get("by_flow")
    if not isinstance(by_flow, dict):
        raise SystemExit("tmux-whisper: usage summary is missing flow counts; refusing to overwrite it")

    stamp = now_iso()
    today = local_today(stamp)
    day = civil_date(local_date) or today
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", take_id):
        take_id = ""
    take_ids = payload.get("recent_take_ids")
    if take_ids is not None and not isinstance(take_ids, dict):
        print("tmux-whisper: usage take ids are unreadable; starting them again", file=sys.stderr)
        take_ids = None
    take_ids = dict(take_ids or {})
    if take_id and take_id in take_ids:
        # Already counted (a replay): nothing to change.
        raise SystemExit(0)

    count_before = as_nonnegative_int(deliveries.get("count", 0), "delivered_dictations.count")
    deliveries["count"] = count_before + 1
    by_flow["inline"] = as_nonnegative_int(by_flow.get("inline", 0), "delivered_dictations.by_flow.inline")
    by_flow["tmux"] = as_nonnegative_int(by_flow.get("tmux", 0), "delivered_dictations.by_flow.tmux")
    by_flow[flow] += 1
    words = len(re.findall(r"\b\w+\b", processed, flags=re.UNICODE))
    payload["processed_words"] = as_nonnegative_int(payload.get("processed_words", 0), "processed_words") + words
    payload["recording_duration_ms"] = as_nonnegative_int(payload.get("recording_duration_ms", 0), "recording_duration_ms") + int(record_ms)
    payload["full_elapsed_duration_ms"] = as_nonnegative_int(payload.get("full_elapsed_duration_ms", 0), "full_elapsed_duration_ms") + int(full_elapsed_ms)

    daily = payload.get("daily")
    if daily is None:
        daily = {"started_at": stamp, "baseline_count": count_before, "days": {}}
        payload["daily"] = daily
    day_fields = ("count", "inline", "tmux", "words", "recording_ms", "full_elapsed_ms",
                  "longest_recording_ms", "most_words")
    days = daily.get("days") if isinstance(daily, dict) else None
    bucket = days.get(day.isoformat(), dict.fromkeys(day_fields, 0)) if isinstance(days, dict) else None
    if (isinstance(daily, dict) and plain_int(daily.get("baseline_count")) and isinstance(bucket, dict)
            and all(plain_int(bucket.get(k)) for k in day_fields)):
        bucket = {k: bucket[k] for k in day_fields}
        bucket["count"] += 1
        bucket[flow] += 1
        bucket["words"] += words
        bucket["recording_ms"] += int(record_ms)
        bucket["full_elapsed_ms"] += int(full_elapsed_ms)
        bucket["longest_recording_ms"] = max(bucket["longest_recording_ms"], int(record_ms))
        bucket["most_words"] = max(bucket["most_words"], words)
        days[day.isoformat()] = bucket
    else:
        print("tmux-whisper: daily usage is unreadable; recorded the totals only", file=sys.stderr)

    if take_id:
        cutoff = today - datetime.timedelta(days=TAKE_ID_DAYS)
        take_ids = {k: v for k, v in take_ids.items() if (civil_date(v) or cutoff) > cutoff}
        take_ids[take_id] = day.isoformat()
        if len(take_ids) > TAKE_ID_MAX:
            take_ids = dict(sorted(take_ids.items(), key=lambda item: item[1])[-TAKE_ID_MAX:])
        payload["recent_take_ids"] = take_ids

    fd, tmp_path = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp-", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
        try:
            directory_fd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
' "$(usage_summary_file)" "$flow" "$record_ms" "$full_elapsed_ms" "$take_id" "$local_date" <<<"$processed"
}

# Print a stable, content-free usage summary suitable for a menu-bar wrapper.
# Usage: usage_summary [json_output] [days]   days: "" (none), N or "all";
# with days, the JSON gains a `daily` section (per-day buckets for the last N
# local calendar dates including today) built from validated numbers only.
usage_summary() {
  local json_output="${1:-0}"
  local days_arg="${2:-}"
  local summary_file
  summary_file="$(usage_summary_file)"
  local typing_wpm
  typing_wpm="$(history_typing_wpm_assumed)"
  need python3

  python3 - "$summary_file" "$typing_wpm" "$json_output" "$days_arg" <<'PYEOF'
import datetime
import json
import os
import re
import sys

path, wpm_raw, json_raw, days_raw = sys.argv[1:]
wpm = int(wpm_raw)
json_output = json_raw == "1"
stored = None

def nonnegative(value, default=0):
    try:
        value = int(value)
        return value if value >= 0 else default
    except Exception:
        return default

if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            stored = json.load(fh)
    except Exception as exc:
        raise SystemExit(f"tmux-whisper: usage summary is unreadable: {exc}")
    if stored.get("schema_version") != 1 or not isinstance(stored.get("delivered_dictations"), dict):
        raise SystemExit("tmux-whisper: unsupported usage summary schema")
    tracking_started_at = stored.get("tracking_started_at") or None
    deliveries = stored["delivered_dictations"]
    by_flow = deliveries.get("by_flow") if isinstance(deliveries.get("by_flow"), dict) else {}
    count = nonnegative(deliveries.get("count"))
    inline = nonnegative(by_flow.get("inline"))
    tmux = nonnegative(by_flow.get("tmux"))
    words = nonnegative(stored.get("processed_words"))
    recording_ms = nonnegative(stored.get("recording_duration_ms"))
    full_elapsed_ms = nonnegative(stored.get("full_elapsed_duration_ms"))
else:
    tracking_started_at = None
    count = inline = tmux = words = recording_ms = full_elapsed_ms = 0

def plain_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0

def civil_date(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None

def local_today():
    override = os.environ.get("DICTATE_USAGE_NOW", "").strip()
    try:
        parsed = datetime.datetime.fromisoformat(override.replace("Z", "+00:00")) if override else None
    except ValueError:
        parsed = None
    return (parsed or datetime.datetime.now(datetime.timezone.utc)).astimezone().date()

# Only the allow-listed numbers of each bucket leave this function; the stored
# section is never passed through.
DAY_FIELDS = ("count", "words", "recording_ms", "full_elapsed_ms", "longest_recording_ms", "most_words")
daily_section = stored.get("daily") if isinstance(stored, dict) else None
daily_started_at = None
daily_status = "not_started"
daily_baseline = 0
daily_days = []
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})")
if daily_section is not None:
    # All or nothing: a section with any bad value is reported unreadable
    # rather than shown with missing or invented days.
    days_obj = daily_section.get("days") if isinstance(daily_section, dict) else None
    started = daily_section.get("started_at") if isinstance(daily_section, dict) else None
    daily_status = "unreadable"
    if (isinstance(days_obj, dict) and isinstance(started, str) and TIMESTAMP.fullmatch(started)
            and plain_int(daily_section.get("baseline_count"))):
        parsed = []
        for key, bucket in days_obj.items():
            date = civil_date(key)
            if date is None or not isinstance(bucket, dict):
                break
            if not all(plain_int(bucket.get(k)) for k in DAY_FIELDS + ("inline", "tmux")):
                break
            entry = {"date": date.isoformat()}
            entry.update({k: bucket[k] for k in DAY_FIELDS})
            entry["by_flow"] = {"inline": bucket["inline"], "tmux": bucket["tmux"]}
            parsed.append(entry)
        else:
            daily_status = "active"
            daily_started_at = started
            daily_baseline = daily_section["baseline_count"]
            daily_days = sorted(parsed, key=lambda d: d["date"])

typing_equivalent_ms = int(round((words * 60000) / wpm)) if words else 0
estimated_time_difference_ms = typing_equivalent_ms - full_elapsed_ms
payload = {
    "command": "usage",
    "schema_version": 1,
    "coverage": {
        "tracking_started_at": tracking_started_at,
        "status": "active" if tracking_started_at else "not_started",
        "scope": "successful_delivered_dictations_recorded_since_tracking_started",
        "history_backfill": False,
        "retention_independent": True,
        "daily_tracking_started_at": daily_started_at,
    },
    "delivered_dictations": {"count": count, "by_flow": {"inline": inline, "tmux": tmux}},
    "processed_words": words,
    "recording_duration_ms": recording_ms,
    "full_elapsed_duration_ms": full_elapsed_ms,
    "typing_assumption": {"wpm": wpm, "typing_equivalent_duration_ms": typing_equivalent_ms},
    "estimated_time_difference_ms": estimated_time_difference_ms,
}

if days_raw:
    today = local_today()
    # Over all stored buckets, never the returned slice.
    untracked = max(0, count - daily_baseline - sum(d["count"] for d in daily_days)) if daily_status == "active" else 0
    if days_raw == "all":
        start = min([civil_date(d["date"]) for d in daily_days] + [today])
        end = max([civil_date(d["date"]) for d in daily_days] + [today])
    else:
        start = today - datetime.timedelta(days=int(days_raw) - 1)
        end = today
    payload["daily"] = {
        "status": daily_status,
        "started_at": daily_started_at,
        "as_of_local_date": today.isoformat(),
        "range": {"from": start.isoformat(), "to": end.isoformat()},
        "untracked_deliveries": untracked,
        "days": [d for d in daily_days if start.isoformat() <= d["date"] <= end.isoformat()],
    }

def fmt(ms):
    sign = "-" if ms < 0 else ""
    ms = abs(ms)
    seconds = ms / 1000
    if seconds < 60:
        return f"{sign}{seconds:.1f}s"
    total_seconds = round(seconds)
    hours, rem = divmod(total_seconds, 3600)
    minutes, seconds = divmod(rem, 60)
    if hours:
        return f"{sign}{hours}h {minutes:02d}m {seconds:02d}s"
    return f"{sign}{minutes}m {seconds:02d}s"

if json_output:
    print(json.dumps(payload, indent=2, sort_keys=True))
elif not tracking_started_at:
    print("No successful delivered dictations recorded yet.")
    print("Tracking starts with the next delivery; transcript history is not backfilled.")
else:
    print("Dictation usage (tracked deliveries only)")
    print(f"  tracking_started_at: {tracking_started_at}")
    print(f"  delivered_dictations: {count} (inline={inline}, tmux={tmux})")
    print(f"  processed_words: {words}")
    print(f"  recording_duration: {fmt(recording_ms)}")
    print(f"  full_elapsed_duration: {fmt(full_elapsed_ms)}")
    print(f"  typing_equivalent: {fmt(typing_equivalent_ms)} @ {wpm} wpm assumed")
    print(f"  estimated_time_difference: {fmt(estimated_time_difference_ms) if estimated_time_difference_ms <= 0 else '+' + fmt(estimated_time_difference_ms)} (typing equivalent minus full elapsed)")
    print("  coverage: new successful deliveries since tracking_started_at; transcript history is not backfilled.")
PYEOF
}

# List recent history entries
list_history() {
  local limit="${1:-20}"

  if [[ ! -d "$HISTORY_DIR" ]]; then
    echo "No history yet."
    return 0
  fi

  local files
  files="$(ls -1t "$HISTORY_DIR"/*.json 2>/dev/null | head -n "$limit")"

  if [[ -z "$files" ]]; then
    echo "No history entries."
    return 0
  fi

  echo "Recent dictations (newest first):"
  echo ""

  local i=1
  while IFS= read -r f; do
    local basename ts mode preview
    basename="$(basename "$f" .json)"
    ts="${basename/T/ }"
    ts="${ts//-/:}"
    # Fix: first 2 colons in date should be dashes
    ts="$(echo "$ts" | sed -E 's/:/-/; s/:/-/')"
    mode="$(jq -r '.mode // "?"' "$f" 2>/dev/null)"
    preview="$(jq -r '.processed // .raw' "$f" 2>/dev/null | head -c 60 | tr '\n' ' ')"
    printf "%2d. [%s] (%s) %s...\n" "$i" "$ts" "$mode" "$preview"
    ((i++))
  done <<< "$files"
}

list_history_json() {
  local limit="${1:-20}"
  [[ "$limit" =~ ^[0-9]+$ ]] || die "history list limit must be an integer"
  need python3

  python3 - "$HISTORY_DIR" "$limit" <<'PYEOF'
import glob, json, os, re, sys

history_dir = os.path.expanduser(sys.argv[1])
limit = int(sys.argv[2])
files = sorted(glob.glob(os.path.join(history_dir, "*.json")), reverse=True)[:limit]

def word_count(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text or ""))

entries = []
for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue

    raw = str(data.get("raw", "") or "")
    processed = str(data.get("processed", "") or "")
    preview = re.sub(r"\s+", " ", (processed or raw)).strip()
    if len(preview) > 120:
        preview = preview[:120]

    metrics = data.get("metrics")
    if not isinstance(metrics, dict):
        metrics = {}
    budget = data.get("postprocess_budget")
    if not isinstance(budget, dict):
        budget = {}
    audio = data.get("audio")
    if not isinstance(audio, dict):
        audio = {}

    entries.append(
        {
            "index": len(entries) + 1,
            "file": path,
            "filename": os.path.basename(path),
            "timestamp": str(data.get("timestamp", "") or ""),
            "mode": str(data.get("mode", "?") or "?"),
            "app": str(data.get("app", "?") or "?"),
            "preview": preview,
            "raw_words": word_count(raw),
            "processed_words": word_count(processed),
            "metrics": metrics,
            "audio": audio,
            "postprocess_budget": budget,
        }
    )

print(json.dumps(entries, indent=2, sort_keys=True))
PYEOF
}

search_history() {
  local query="${1:-}"
  local limit="${2:-20}"
  [[ -n "$query" ]] || die "history search requires a query"
  [[ "$limit" =~ ^[0-9]+$ ]] || die "history search limit must be an integer"
  need python3

  python3 - "$HISTORY_DIR" "$query" "$limit" <<'PYEOF'
import glob
import json
import os
import re
import sys

history_dir = os.path.expanduser(sys.argv[1])
query = sys.argv[2]
limit = int(sys.argv[3])
query_lower = query.lower()
files = sorted(glob.glob(os.path.join(history_dir, "*.json")), reverse=True)

def make_preview(text: str) -> str:
    preview = re.sub(r"\s+", " ", text or "").strip()
    if len(preview) > 80:
        preview = preview[:80]
    return preview

def display_timestamp(filename: str) -> str:
    stamp = os.path.splitext(os.path.basename(filename))[0]
    stamp = stamp.replace("T", " ")
    stamp = stamp.replace("-", ":")
    stamp = stamp.replace(":", "-", 2)
    return stamp

matches = []
for overall_index, path in enumerate(files, start=1):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue

    fields = {
        "mode": str(data.get("mode", "") or ""),
        "app": str(data.get("app", "") or ""),
        "raw": str(data.get("raw", "") or ""),
        "processed": str(data.get("processed", "") or ""),
    }
    match_fields = [name for name, value in fields.items() if query_lower in value.lower()]
    if not match_fields:
        continue

    preview = make_preview(fields["processed"] or fields["raw"])
    matches.append(
        {
            "index": overall_index,
            "file": path,
            "filename": os.path.basename(path),
            "display_timestamp": display_timestamp(path),
            "mode": fields["mode"] or "?",
            "app": fields["app"] or "?",
            "preview": preview,
            "match_fields": match_fields,
        }
    )
    if len(matches) >= limit:
        break

if not matches:
    print(f"No history entries matched: {query}")
    raise SystemExit(0)

print(f'History search: "{query}"')
print("")
for entry in matches:
    fields_summary = ",".join(entry["match_fields"])
    print(
        f'{entry["index"]:2d}. [{entry["display_timestamp"]}] '
        f'({entry["mode"]} @ {entry["app"]}) [{fields_summary}] {entry["preview"]}...'
    )
PYEOF
}

search_history_json() {
  local query="${1:-}"
  local limit="${2:-20}"
  [[ -n "$query" ]] || die "history search requires a query"
  [[ "$limit" =~ ^[0-9]+$ ]] || die "history search limit must be an integer"
  need python3

  python3 - "$HISTORY_DIR" "$query" "$limit" <<'PYEOF'
import glob
import json
import os
import re
import sys

history_dir = os.path.expanduser(sys.argv[1])
query = sys.argv[2]
limit = int(sys.argv[3])
query_lower = query.lower()
files = sorted(glob.glob(os.path.join(history_dir, "*.json")), reverse=True)

def word_count(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text or ""))

def make_preview(text: str) -> str:
    preview = re.sub(r"\s+", " ", text or "").strip()
    if len(preview) > 120:
        preview = preview[:120]
    return preview

entries = []
for overall_index, path in enumerate(files, start=1):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue

    raw = str(data.get("raw", "") or "")
    processed = str(data.get("processed", "") or "")
    mode = str(data.get("mode", "?") or "?")
    app = str(data.get("app", "?") or "?")
    field_values = {"mode": mode, "app": app, "raw": raw, "processed": processed}
    match_fields = [name for name, value in field_values.items() if query_lower in value.lower()]
    if not match_fields:
        continue

    metrics = data.get("metrics")
    if not isinstance(metrics, dict):
        metrics = {}
    budget = data.get("postprocess_budget")
    if not isinstance(budget, dict):
        budget = {}
    audio = data.get("audio")
    if not isinstance(audio, dict):
        audio = {}

    entries.append(
        {
            "index": overall_index,
            "file": path,
            "filename": os.path.basename(path),
            "timestamp": str(data.get("timestamp", "") or ""),
            "mode": mode,
            "app": app,
            "preview": make_preview(processed or raw),
            "raw_words": word_count(raw),
            "processed_words": word_count(processed),
            "match_fields": match_fields,
            "metrics": metrics,
            "audio": audio,
            "postprocess_budget": budget,
        }
    )
    if len(entries) >= limit:
        break

print(json.dumps(entries, indent=2, sort_keys=True))
PYEOF
}

history_render_entry_text() {
  local n="${1:-1}"
  local file="${2:-}"
  [[ -n "$file" && -f "$file" ]] || die "history entry $n not found"

  local timestamp mode app raw processed
  local metrics_lines audio_lines budget_lines
  timestamp="$(jq -r '.timestamp // ""' "$file" 2>/dev/null)"
  mode="$(jq -r '.mode // "?"' "$file")"
  app="$(jq -r '.app // "?"' "$file")"
  raw="$(jq -r '.raw // ""' "$file")"
  processed="$(jq -r '.processed // ""' "$file")"
  metrics_lines="$(jq -r '
    (.metrics // {}) as $m
    | ["record_ms","transcribe_ms","clean_ms","postprocess_ms","paste_ms","total_ms"][]
    | select($m[.] != null)
    | "\(.) : \($m[.])"
  ' "$file" 2>/dev/null || true)"
  audio_lines="$(jq -r '
    (.audio // {}) as $a
    | ["capture_wav_ms","capture_wav_bytes","capture_gap_to_record_ms","capture_gap_to_record_plus_grace_ms","archive_wav_ms","archive_wav_bytes","wav_retention_days","debug_archive_prefix","retention_note"][]
    | select($a[.] != null)
    | "\(.) : \($a[.])"
  ' "$file" 2>/dev/null || true)"
  budget_lines="$(jq -r '
    (.postprocess_budget // {}) as $b
    | ["numeric_sizing","profile","threshold_words","word_count","max_tokens","chunk_words","chunk_count","llm"][]
    | select($b[.] != null)
    | "\(.) : \($b[.])"
  ' "$file" 2>/dev/null || true)"

  echo "=== Entry $n ==="
  echo "File: $(basename "$file")"
  [[ -n "$timestamp" ]] && echo "Timestamp: $timestamp"
  echo "Mode: $mode"
  echo "App: $app"
  if [[ -n "${metrics_lines//[[:space:]]/}" ]]; then
    echo ""
    echo "--- Metrics ---"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "$line"
    done <<< "$metrics_lines"
  fi
  if [[ -n "${audio_lines//[[:space:]]/}" ]]; then
    echo ""
    echo "--- Audio Artifacts ---"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "$line"
    done <<< "$audio_lines"
  fi
  if [[ -n "${budget_lines//[[:space:]]/}" ]]; then
    echo ""
    echo "--- Postprocess Budget ---"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      echo "$line"
    done <<< "$budget_lines"
  fi
  echo ""
  echo "--- Raw transcript ---"
  echo "$raw"
  echo ""
  echo "--- Processed ---"
  echo "$processed"
}

export_history() {
  local spec="${1:-all}"
  local files
  files="$(history_files_ordered "$spec")"

  if [[ -z "$files" ]]; then
    echo "No history entries."
    return 0
  fi

  local i=1
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    history_render_entry_text "$i" "$file"
    ((i++))
    echo ""
  done <<< "$files"
}

export_history_json() {
  local spec="${1:-all}"
  local files
  files="$(history_files_ordered "$spec")"
  need python3

  if [[ -z "$files" ]]; then
    echo "[]"
    return 0
  fi

  HISTORY_EXPORT_FILES="$files" python3 - <<'PYEOF'
import json
import os
import re

files = [line for line in os.environ.get("HISTORY_EXPORT_FILES", "").splitlines() if line]

def word_count(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text or ""))

entries = []
for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue

    raw = str(data.get("raw", "") or "")
    processed = str(data.get("processed", "") or "")
    metrics = data.get("metrics")
    if not isinstance(metrics, dict):
        metrics = {}
    budget = data.get("postprocess_budget")
    if not isinstance(budget, dict):
        budget = {}
    audio = data.get("audio")
    if not isinstance(audio, dict):
        audio = {}

    entries.append(
        {
            "index": len(entries) + 1,
            "file": path,
            "filename": os.path.basename(path),
            "timestamp": str(data.get("timestamp", "") or ""),
            "mode": str(data.get("mode", "?") or "?"),
            "app": str(data.get("app", "?") or "?"),
            "raw": raw,
            "processed": processed,
            "raw_words": word_count(raw),
            "processed_words": word_count(processed),
            "metrics": metrics,
            "audio": audio,
            "postprocess_budget": budget,
        }
    )

print(json.dumps(entries, indent=2, sort_keys=True))
PYEOF
}

history_sessions() {
  local limit="${1:-10}"
  local json_output="${2:-0}"
  [[ "$limit" =~ ^[0-9]+$ ]] || die "history sessions limit must be an integer"
  (( limit > 0 )) || die "history sessions limit must be greater than zero"
  need python3

  python3 - "$HISTORY_DIR" "$limit" "$json_output" <<'PYEOF'
import glob
import json
import os
import re
import sys

history_dir = os.path.expanduser(sys.argv[1])
limit = int(sys.argv[2])
json_output = sys.argv[3] == "1"

files = sorted(glob.glob(os.path.join(history_dir, "*.json")), reverse=True)[:limit]

def word_count(text: str) -> int:
    return len(re.findall(r"\b\w+\b", text or ""))

def to_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

def fmt_ms(value) -> str:
    ms = to_int(value)
    if ms <= 0:
        return "0ms"
    seconds = ms / 1000.0
    if seconds < 60:
        return f"{seconds:.1f}s"
    total_seconds = int(round(seconds))
    minutes, rem_seconds = divmod(total_seconds, 60)
    return f"{minutes}m {rem_seconds:02d}s"

def preview_text(raw: str, processed: str) -> str:
    preview = re.sub(r"\s+", " ", (processed or raw or "")).strip()
    if len(preview) > 120:
        preview = preview[:120]
    return preview

def compact_debug_notes(audio):
    notes = []
    prefix = str(audio.get("debug_archive_prefix", "") or "")
    retention = str(audio.get("retention_note", "") or "")
    if prefix:
        notes.append(f"debug_archive_prefix={prefix}")
    if retention:
        notes.append(f"retention_note={retention}")
    for key in ("capture_gap_to_record_ms", "capture_gap_to_record_plus_grace_ms"):
        if key in audio:
            notes.append(f"{key}={audio[key]}ms")
    return notes

sessions = []
for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue

    raw = str(data.get("raw", "") or "")
    processed = str(data.get("processed", "") or "")
    metrics = data.get("metrics")
    if not isinstance(metrics, dict):
        metrics = {}
    audio = data.get("audio")
    if not isinstance(audio, dict):
        audio = {}
    budget = data.get("postprocess_budget")
    if not isinstance(budget, dict):
        budget = {}

    sessions.append(
        {
            "index": len(sessions) + 1,
            "file": path,
            "filename": os.path.basename(path),
            "timestamp": str(data.get("timestamp", "") or ""),
            "mode": str(data.get("mode", "?") or "?"),
            "app": str(data.get("app", "?") or "?"),
            "raw_words": word_count(raw),
            "processed_words": word_count(processed),
            "preview": preview_text(raw, processed),
            "metrics": metrics,
            "audio": audio,
            "debug_notes": compact_debug_notes(audio),
            "postprocess_budget": budget,
        }
    )

payload = {
    "command": "history",
    "subcommand": "sessions",
    "source": history_dir,
    "limit": limit,
    "sessions": sessions,
    "next_commands": [
        "tmux-whisper history stats",
        "tmux-whisper bench 10",
    ],
}

if json_output:
    print(json.dumps(payload, indent=2, sort_keys=True))
    raise SystemExit(0)

if not sessions:
    print("No history entries.")
    raise SystemExit(0)

print("Recent dictation sessions (newest first):")
print("")
for session in sessions:
    metrics = session["metrics"]
    audio = session["audio"]
    words = session["processed_words"] or session["raw_words"]
    timing_bits = []
    for key, label in (
        ("record_ms", "record"),
        ("transcribe_ms", "transcribe"),
        ("postprocess_ms", "postprocess"),
        ("paste_ms", "paste"),
        ("total_ms", "total"),
    ):
        if key in metrics:
            timing_bits.append(f"{label}={fmt_ms(metrics.get(key))}")
    timing_text = " ".join(timing_bits) if timing_bits else "timing=unavailable"
    print(
        f"{session['index']:2d}. {session['timestamp'] or session['filename']} "
        f"mode={session['mode']} app={session['app']} words={words} {timing_text}"
    )
    audio_bits = []
    if "capture_wav_ms" in audio:
        audio_bits.append(f"capture_wav={fmt_ms(audio.get('capture_wav_ms'))}")
    if "archive_wav_ms" in audio:
        audio_bits.append(f"archive_wav={fmt_ms(audio.get('archive_wav_ms'))}")
    if "capture_wav_bytes" in audio:
        audio_bits.append(f"capture_bytes={audio.get('capture_wav_bytes')}")
    if "archive_wav_bytes" in audio:
        audio_bits.append(f"archive_bytes={audio.get('archive_wav_bytes')}")
    if audio_bits:
        print("    audio: " + " ".join(audio_bits))
    if session["debug_notes"]:
        print("    debug: " + "; ".join(session["debug_notes"]))
    print("    preview: " + session["preview"])

print("")
print("Next:")
print("  tmux-whisper history stats")
print("  tmux-whisper bench 10")
PYEOF
}

# Show a specific history entry
show_history() {
  local n="${1:-1}"

  local file
  file="$(history_entry_file_by_index "$n")"

  if [[ -z "$file" || ! -f "$file" ]]; then
    die "history entry $n not found"
  fi
  history_render_entry_text "$n" "$file"
}

show_last_history() {
  local output_format="${1:-text}"
  local file
  file="$(history_entry_file_by_index 1)"

  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "No history entries."
    return 0
  fi

  if [[ "$output_format" == "json" ]]; then
    history_entry_json 1
    return 0
  fi

  local timestamp mode app raw processed
  local raw_words processed_words metrics_compact budget_compact preview
  local record_ms total_ms dictation_wpm typing_wpm typing_equivalent_ms typing_delta_ms
  timestamp="$(jq -r '.timestamp // ""' "$file" 2>/dev/null)"
  mode="$(jq -r '.mode // "?"' "$file" 2>/dev/null)"
  app="$(jq -r '.app // "?"' "$file" 2>/dev/null)"
  raw="$(jq -r '.raw // ""' "$file" 2>/dev/null)"
  processed="$(jq -r '.processed // ""' "$file" 2>/dev/null)"
  raw_words="$(printf '%s' "$raw" | wc -w | tr -d '[:space:]')"
  processed_words="$(printf '%s' "$processed" | wc -w | tr -d '[:space:]')"
  record_ms="$(jq -r '.metrics.record_ms // 0' "$file" 2>/dev/null)"
  total_ms="$(jq -r '.metrics.total_ms // 0' "$file" 2>/dev/null)"
  [[ "$record_ms" =~ ^[0-9]+$ ]] || record_ms=0
  [[ "$total_ms" =~ ^[0-9]+$ ]] || total_ms=0
  dictation_wpm=""
  if [[ "$record_ms" -gt 0 && "$raw_words" -gt 0 ]]; then
    dictation_wpm="$(awk -v words="$raw_words" -v ms="$record_ms" 'BEGIN { printf "%d", ((words * 60000) / ms) + 0.5 }')"
  fi
  typing_wpm="$(history_typing_wpm_assumed)"
  typing_equivalent_ms=0
  if [[ "$processed_words" -gt 0 ]]; then
    typing_equivalent_ms="$(awk -v words="$processed_words" -v wpm="$typing_wpm" 'BEGIN { printf "%d", ((words * 60000) / wpm) + 0.5 }')"
  fi
  typing_delta_ms=0
  if [[ "$typing_equivalent_ms" -gt 0 && "$total_ms" -gt 0 ]]; then
    typing_delta_ms=$((typing_equivalent_ms - total_ms))
  fi
  metrics_compact="$(jq -r '
    (.metrics // {}) as $m
    | ["record_ms","transcribe_ms","clean_ms","postprocess_ms","paste_ms","total_ms"]
    | map(select($m[.] != null) | "\(.)=\($m[.])ms")
    | join(" ")
  ' "$file" 2>/dev/null || true)"
  budget_compact="$(jq -r '
    (.postprocess_budget // {}) as $b
    | if ($b | length) == 0 then ""
      else
        [
          (if $b.profile != null then "profile=\($b.profile)" else empty end),
          (if $b.word_count != null then "words=\($b.word_count)" else empty end),
          (if $b.max_tokens != null then "max_tokens=\($b.max_tokens)" else empty end),
          (if $b.chunk_count != null then "chunks=\($b.chunk_count)" else empty end)
        ] | join(" ")
      end
  ' "$file" 2>/dev/null || true)"
  preview="$(printf '%s' "$processed" | tr '\n' ' ' | head -c 120)"

  echo "Latest dictation"
  echo "  timestamp: ${timestamp:-unknown}"
  echo "  mode: ${mode:-?}"
  echo "  app: ${app:-?}"
  echo "  raw_words: ${raw_words:-0}"
  echo "  processed_words: ${processed_words:-0}"
  if [[ "$record_ms" -gt 0 ]]; then
    echo "  capture_time: $(history_format_duration_ms "$record_ms")"
  fi
  if [[ "$total_ms" -gt 0 ]]; then
    echo "  end_to_end: $(history_format_duration_ms "$total_ms")"
  fi
  if [[ -n "$dictation_wpm" ]]; then
    echo "  dictation_pace: ${dictation_wpm} wpm (raw)"
  fi
  if [[ "$typing_equivalent_ms" -gt 0 ]]; then
    echo "  typing_equivalent: $(history_format_duration_ms "$typing_equivalent_ms") @ ${typing_wpm} wpm"
  fi
  if [[ "$typing_equivalent_ms" -gt 0 && "$total_ms" -gt 0 ]]; then
    echo "  typing_delta: $(history_format_signed_duration_ms "$typing_delta_ms") vs end-to-end"
  fi
  if [[ -n "${metrics_compact//[[:space:]]/}" ]]; then
    echo "  metrics: $metrics_compact"
  fi
  if [[ -n "${budget_compact//[[:space:]]/}" ]]; then
    echo "  budget: $budget_compact"
  fi
  echo "  preview: ${preview}..."
}

# Reprocess a history entry with a different mode
reprocess_history() {
  local n="${1:-1}"
  local target_mode="${2:-}"

  if [[ -z "${CEREBRAS_API_KEY:-}" ]]; then
    die "reprocess requires CEREBRAS_API_KEY"
  fi

  if [[ ! -d "$HISTORY_DIR" ]]; then
    die "no history directory"
  fi

  local file
  file="$(ls -1t "$HISTORY_DIR"/*.json 2>/dev/null | sed -n "${n}p")"

  if [[ -z "$file" || ! -f "$file" ]]; then
    die "history entry $n not found"
  fi

  local raw
  raw="$(jq -r '.raw // ""' "$file")"

  if [[ -z "$raw" ]]; then
    die "no raw transcript in entry $n"
  fi

  # Determine mode
  if [[ -z "$target_mode" ]]; then
    target_mode="$(get_current_mode)"
  else
    target_mode="$(canonical_mode_name "$target_mode")"
    if [[ ! -d "$DICTATE_CONFIG_DIR/modes/$(mode_to_dir_name "$target_mode")" ]]; then
      die "unknown mode: $target_mode"
    fi
  fi

  echo "🔄 Reprocessing entry $n with $(mode_display_name "$target_mode") mode..."

  local result
  result="$(DICTATE_FORCE_MODE="$target_mode" postprocess_llm "$raw" "")"
  result="$(printf "%s" "$result" | auto_paragraphs "$target_mode" | normalize_british_spelling)"

  printf "%s" "$result" | pbcopy

  echo "✅ Done. Result copied to clipboard:"
  echo ""
  echo "$result"
}

# Main history command handler
manage_history() {
  local json_output="0"
  local args=()
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--json" ]]; then
      json_output="1"
    else
      args+=("$arg")
    fi
  done
  set -- "${args[@]}"

  local subcmd="${1:-}"
  shift 2>/dev/null || true

  case "$subcmd" in
    ""|list)
      if [[ "$json_output" == "1" ]]; then
        list_history_json "${1:-20}"
      else
        list_history "${1:-20}"
      fi
      ;;
    search)
      if [[ "$json_output" == "1" ]]; then
        search_history_json "${1:-}" "${2:-20}"
      else
        search_history "${1:-}" "${2:-20}"
      fi
      ;;
    export)
      if [[ "$json_output" == "1" ]]; then
        export_history_json "${1:-all}"
      else
        export_history "${1:-all}"
      fi
      ;;
    stats)
      need python3
      local history_dir="$HISTORY_DIR"
      if [[ ! -d "$history_dir" ]]; then
        die "no history directory"
      fi
      python3 - "$history_dir" "$json_output" <<'PYEOF'
import glob, json, os, re, statistics, sys
from datetime import datetime, timedelta, timezone

history_dir = os.path.expanduser(sys.argv[1])
json_output = sys.argv[2] == "1"
files = sorted(glob.glob(os.path.join(history_dir, "*.json")))

METRIC_NAMES = ("record_ms", "transcribe_ms", "clean_ms", "postprocess_ms", "paste_ms", "total_ms")

def word_count(s: str) -> int:
    return len(re.findall(r"\b\w+\b", s or ""))

def to_int(value):
    try:
        return int(value)
    except Exception:
        return None

def parse_timestamp(value):
    if not value:
        return None
    raw = str(value).strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except Exception:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)

def resolve_now():
    override = os.environ.get("DICTATE_HISTORY_STATS_NOW", "").strip()
    if override:
        if re.fullmatch(r"-?\d+", override):
            return datetime.fromtimestamp(int(override), tz=timezone.utc)
        parsed = parse_timestamp(override)
        if parsed is not None:
            return parsed
    return datetime.now(timezone.utc)

def resolve_typing_wpm():
    raw = os.environ.get("DICTATE_HISTORY_TYPING_WPM", "40").strip()
    try:
        value = int(raw)
    except Exception:
        value = 40
    return value if value > 0 else 40

def pctl(arr, pct):
    vals = [int(round(float(x))) for x in arr]
    if not vals:
        return 0
    vals = sorted(vals)
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * pct
    lo = int(pos)
    hi = min(lo + 1, len(vals) - 1)
    frac = pos - lo
    return int(round(vals[lo] * (1 - frac) + vals[hi] * frac))

def metric_summary(arr):
    vals = [int(round(float(x))) for x in arr]
    if not vals:
        return {"n": 0, "sum": 0, "median": 0, "p95": 0, "max": 0}
    return {
        "n": len(vals),
        "sum": int(sum(vals)),
        "median": int(round(statistics.median(vals))),
        "p95": pctl(vals, 0.95),
        "max": max(vals),
    }

def summarize_rows(rows):
    return {
        "entries": len(rows),
        "raw_words": sum(r["raw_words"] for r in rows),
        "processed_words": sum(r["processed_words"] for r in rows),
        "record_ms": sum(r["metrics"].get("record_ms", 0) for r in rows),
        "total_ms": sum(r["metrics"].get("total_ms", 0) for r in rows),
    }

def ordered_breakdown(rows, field):
    buckets = {}
    for row in rows:
        key = row.get(field) or "?"
        bucket = buckets.setdefault(
            key,
            {"entries": 0, "raw_words": 0, "processed_words": 0, "record_ms": 0, "total_ms": 0},
        )
        bucket["entries"] += 1
        bucket["raw_words"] += row["raw_words"]
        bucket["processed_words"] += row["processed_words"]
        bucket["record_ms"] += row["metrics"].get("record_ms", 0)
        bucket["total_ms"] += row["metrics"].get("total_ms", 0)
    ordered = sorted(
        buckets.items(),
        key=lambda item: (-item[1]["entries"], -item[1]["processed_words"], str(item[0]).lower()),
    )
    return {key: value for key, value in ordered}

def format_duration_ms(ms):
    if ms is None:
        return "?"
    ms = int(round(ms))
    negative = ms < 0
    ms = abs(ms)
    seconds = ms / 1000.0
    if seconds < 60:
        body = f"{seconds:.1f}s"
    elif seconds < 3600:
        total_seconds = int(round(seconds))
        minutes, rem_seconds = divmod(total_seconds, 60)
        body = f"{minutes}m {rem_seconds:02d}s"
    else:
        total_seconds = int(round(seconds))
        hours, rem = divmod(total_seconds, 3600)
        minutes, rem_seconds = divmod(rem, 60)
        body = f"{hours}h {minutes:02d}m {rem_seconds:02d}s"
    return f"-{body}" if negative else body

def format_signed_duration_ms(ms):
    if ms is None:
        return "?"
    return f"+{format_duration_ms(ms)}" if ms > 0 else format_duration_ms(ms)

rows = []
for path in files:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue
    raw = data.get("raw", "") or ""
    processed = data.get("processed", "") or ""
    metrics_src = data.get("metrics") if isinstance(data.get("metrics"), dict) else {}
    metrics = {}
    for metric_name in METRIC_NAMES:
        metric_value = to_int(metrics_src.get(metric_name))
        if metric_value is not None:
            metrics[metric_name] = metric_value
    rows.append(
        {
            "timestamp": str(data.get("timestamp", "") or ""),
            "timestamp_dt": parse_timestamp(data.get("timestamp", "")),
            "mode": str(data.get("mode", "") or "?"),
            "app": str(data.get("app", "") or "?"),
            "raw": raw,
            "processed": processed,
            "raw_chars": len(raw),
            "processed_chars": len(processed),
            "raw_words": word_count(raw),
            "processed_words": word_count(processed),
            "metrics": metrics,
            "budget": data.get("postprocess_budget") if isinstance(data.get("postprocess_budget"), dict) else {},
        }
    )

typing_wpm = resolve_typing_wpm()
now_utc = resolve_now()

if not rows:
    empty_metric = metric_summary([])
    payload = {
        "entries": 0,
        "history_files": len(files),
        "raw_chars": empty_metric,
        "raw_words": empty_metric,
        "processed_chars": empty_metric,
        "processed_words": empty_metric,
        "approx_max_tokens_raw": 0,
        "recent": {"last_24h": summarize_rows([]), "last_7d": summarize_rows([])},
        "breakdowns": {"modes": {}, "apps": {}},
        "metrics": {name: empty_metric for name in METRIC_NAMES},
        "estimates": {
            "typing_wpm_assumed": typing_wpm,
            "typing_time_ms": 0,
            "delta_vs_capture_ms": 0,
            "delta_vs_end_to_end_ms": 0,
            "dictation_wpm_overall": 0,
            "dictation_wpm": empty_metric,
        },
        "postprocess_budget": {"entries": 0},
    }
    if json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print("No history entries found.")
    raise SystemExit(0)

raw_chars = [r["raw_chars"] for r in rows]
raw_words = [r["raw_words"] for r in rows]
proc_chars = [r["processed_chars"] for r in rows]
proc_words = [r["processed_words"] for r in rows]

budget_rows = []
for row in rows:
    budget = row["budget"]
    if budget:
        budget_rows.append(
            {
                "profile": str(budget.get("profile", "") or ""),
                "word_count": to_int(budget.get("word_count")) or 0,
                "threshold_words": to_int(budget.get("threshold_words")) or 0,
                "max_tokens": to_int(budget.get("max_tokens")) or 0,
                "chunk_words": to_int(budget.get("chunk_words")) or 0,
                "chunk_count": to_int(budget.get("chunk_count")) or 0,
                "postprocess_ms": row["metrics"].get("postprocess_ms", 0),
                "numeric_sizing": str(budget.get("numeric_sizing", "") or ""),
            }
        )

profile_counts = {}
for row in budget_rows:
    profile = row.get("profile") or "<unset>"
    profile_counts[profile] = profile_counts.get(profile, 0) + 1
numeric_modes = sorted({row.get("numeric_sizing", "") for row in budget_rows if row.get("numeric_sizing", "")})
thresholds = sorted({row.get("threshold_words", 0) for row in budget_rows if row.get("threshold_words", 0) > 0})

recent_24h_rows = [r for r in rows if r["timestamp_dt"] is not None and r["timestamp_dt"] >= (now_utc - timedelta(hours=24))]
recent_7d_rows = [r for r in rows if r["timestamp_dt"] is not None and r["timestamp_dt"] >= (now_utc - timedelta(days=7))]

metrics_payload = {
    metric_name: metric_summary([r["metrics"][metric_name] for r in rows if metric_name in r["metrics"]])
    for metric_name in METRIC_NAMES
}

typing_time_ms = int(round(sum((r["processed_words"] * 60000) / typing_wpm for r in rows if r["processed_words"] > 0)))
record_ms_total = metrics_payload["record_ms"]["sum"]
total_ms_total = metrics_payload["total_ms"]["sum"]
dictation_wpm_samples = [
    int(round((r["raw_words"] * 60000) / r["metrics"]["record_ms"]))
    for r in rows
    if r["raw_words"] > 0 and r["metrics"].get("record_ms", 0) > 0
]
dictation_wpm_overall = int(round((sum(raw_words) * 60000) / record_ms_total)) if record_ms_total > 0 and sum(raw_words) > 0 else 0

payload = {
    "entries": len(rows),
    "history_files": len(files),
    "raw_chars": metric_summary(raw_chars),
    "raw_words": metric_summary(raw_words),
    "processed_chars": metric_summary(proc_chars),
    "processed_words": metric_summary(proc_words),
    "approx_max_tokens_raw": int(max(raw_words) * 1.33) if raw_words else 0,
    "recent": {
        "last_24h": summarize_rows(recent_24h_rows),
        "last_7d": summarize_rows(recent_7d_rows),
    },
    "breakdowns": {
        "modes": ordered_breakdown(rows, "mode"),
        "apps": ordered_breakdown(rows, "app"),
    },
    "metrics": metrics_payload,
    "estimates": {
        "typing_wpm_assumed": typing_wpm,
        "typing_time_ms": typing_time_ms,
        "delta_vs_capture_ms": (typing_time_ms - record_ms_total) if record_ms_total > 0 else 0,
        "delta_vs_end_to_end_ms": (typing_time_ms - total_ms_total) if total_ms_total > 0 else 0,
        "dictation_wpm_overall": dictation_wpm_overall,
        "dictation_wpm": metric_summary(dictation_wpm_samples),
    },
    "postprocess_budget": {
        "entries": len(budget_rows),
        "profile_counts": profile_counts,
        "numeric_sizing": numeric_modes,
        "threshold_words": thresholds,
        "word_count": metric_summary([r["word_count"] for r in budget_rows if int(r["word_count"]) > 0]),
        "max_tokens": metric_summary([r["max_tokens"] for r in budget_rows if int(r["max_tokens"]) > 0]),
        "chunk_words": metric_summary([r["chunk_words"] for r in budget_rows if int(r["chunk_words"]) > 0]),
        "chunk_count": metric_summary([r["chunk_count"] for r in budget_rows if int(r["chunk_count"]) > 0]),
        "postprocess_ms": metric_summary([r["postprocess_ms"] for r in budget_rows if int(r["postprocess_ms"]) > 0]),
    },
}

if json_output:
    print(json.dumps(payload, indent=2, sort_keys=True))
    raise SystemExit(0)

print(f"History entries: {payload['entries']}")
print(f"raw_chars: max={payload['raw_chars']['max']}, p95={payload['raw_chars']['p95']}, median={payload['raw_chars']['median']}")
print(f"raw_words: max={payload['raw_words']['max']}, p95={payload['raw_words']['p95']}, median={payload['raw_words']['median']}")
print(f"processed_chars: max={payload['processed_chars']['max']}, p95={payload['processed_chars']['p95']}, median={payload['processed_chars']['median']}")
print(f"processed_words: max={payload['processed_words']['max']}, p95={payload['processed_words']['p95']}, median={payload['processed_words']['median']}")
print(f"approx_max_tokens (raw words * 1.33): {payload['approx_max_tokens_raw']}")

print("")
print("Recent activity:")
print(
    f"last_24h: entries={payload['recent']['last_24h']['entries']} "
    f"raw_words={payload['recent']['last_24h']['raw_words']} "
    f"processed_words={payload['recent']['last_24h']['processed_words']}"
)
print(
    f"last_7d: entries={payload['recent']['last_7d']['entries']} "
    f"raw_words={payload['recent']['last_7d']['raw_words']} "
    f"processed_words={payload['recent']['last_7d']['processed_words']}"
)

print("")
print("Usage totals:")
print(f"raw_words.total: {payload['raw_words']['sum']}")
print(f"processed_words.total: {payload['processed_words']['sum']}")
if record_ms_total > 0:
    print(f"record_time.total: {format_duration_ms(record_ms_total)}")
if total_ms_total > 0:
    print(f"end_to_end.total: {format_duration_ms(total_ms_total)}")
if typing_time_ms > 0:
    print(f"typing_equivalent.total: {format_duration_ms(typing_time_ms)} @ {typing_wpm} wpm")
if total_ms_total > 0 and typing_time_ms > 0:
    print(f"typing_delta.total: {format_signed_duration_ms(payload['estimates']['delta_vs_end_to_end_ms'])} vs end-to-end")

print("")
print("Pace:")
if payload["estimates"]["dictation_wpm_overall"] > 0:
    print(f"dictation_wpm.overall: {payload['estimates']['dictation_wpm_overall']}")
dictation_wpm_metric = payload["estimates"]["dictation_wpm"]
if dictation_wpm_metric["n"] > 0:
    print(
        f"dictation_wpm: n={dictation_wpm_metric['n']} median={dictation_wpm_metric['median']} "
        f"p95={dictation_wpm_metric['p95']} max={dictation_wpm_metric['max']}"
    )

if payload["breakdowns"]["modes"]:
    print("")
    print("Mode breakdown:")
    for mode, stats in payload["breakdowns"]["modes"].items():
        print(
            f"{mode}: entries={stats['entries']} "
            f"processed_words={stats['processed_words']} raw_words={stats['raw_words']}"
        )

if payload["breakdowns"]["apps"]:
    print("")
    print("App breakdown:")
    for app, stats in list(payload["breakdowns"]["apps"].items())[:5]:
        print(
            f"{app}: entries={stats['entries']} "
            f"processed_words={stats['processed_words']} raw_words={stats['raw_words']}"
        )

metric_labels = {
    "record_ms": "metrics.record_ms",
    "transcribe_ms": "metrics.transcribe_ms",
    "clean_ms": "metrics.clean_ms",
    "postprocess_ms": "metrics.postprocess_ms",
    "paste_ms": "metrics.paste_ms",
    "total_ms": "metrics.total_ms",
}
available_metrics = [name for name in METRIC_NAMES if payload["metrics"][name]["n"] > 0]
if available_metrics:
    print("")
    print("Stage timings:")
    for metric_name in available_metrics:
        metric = payload["metrics"][metric_name]
        print(
            f"{metric_labels[metric_name]}: n={metric['n']} "
            f"median={metric['median']} p95={metric['p95']} max={metric['max']}"
        )

if budget_rows:
    print("")
    print(f"Postprocess budget observability entries: {payload['postprocess_budget']['entries']}")
    if profile_counts:
        print("budget_profile_counts: " + ", ".join(f"{k}={v}" for k, v in sorted(profile_counts.items())))
    if numeric_modes:
        print("budget_numeric_sizing: " + ", ".join(numeric_modes))
    if thresholds:
        print("budget_threshold_words: " + ", ".join(str(x) for x in thresholds))
    for label, key in (
        ("budget.word_count", "word_count"),
        ("budget.max_tokens", "max_tokens"),
        ("budget.chunk_words", "chunk_words"),
        ("budget.chunk_count", "chunk_count"),
        ("metrics.postprocess_ms", "postprocess_ms"),
    ):
        metric = payload["postprocess_budget"][key]
        print(f"{label}: n={metric['n']} median={metric['median']} p95={metric['p95']} max={metric['max']}")
PYEOF
      ;;
    sessions)
      history_sessions "${1:-10}" "$json_output"
      ;;
    clear)
      if [[ -d "$HISTORY_DIR" ]]; then
        rm -rf "$HISTORY_DIR"
        echo "History cleared."
      else
        echo "No history to clear."
      fi
      ;;
    reprocess)
      reprocess_history "${1:-1}" "${2:-}"
      ;;
    [0-9]*)
      if [[ "$json_output" == "1" ]]; then
        history_entry_json "$subcmd"
      else
        show_history "$subcmd"
      fi
      ;;
    *)
      die "unknown history command: $subcmd (use: list, search, export, sessions, N, reprocess, clear, stats)"
      ;;
  esac
}
