# The usage ledger writer as shipped before per-day buckets (v0.10, origin/main
# 4726eca), verbatim apart from its name. tests/test_flow_parity.sh runs it
# against a newer ledger to check an older CLI on the same machine keeps the
# new sections intact (it just doesn't update them).
usage_record_delivery_v1() {
  local flow="${1:-}"
  local processed="${2:-}"
  local record_ms="${3:-0}"
  local full_elapsed_ms="${4:-0}"
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

path, flow, record_ms, full_elapsed_ms = sys.argv[1:]
processed = sys.stdin.read()

def now_iso():
    override = os.environ.get("DICTATE_USAGE_NOW", "").strip()
    if override:
        return override
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

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

    deliveries["count"] = as_nonnegative_int(deliveries.get("count", 0), "delivered_dictations.count") + 1
    by_flow["inline"] = as_nonnegative_int(by_flow.get("inline", 0), "delivered_dictations.by_flow.inline")
    by_flow["tmux"] = as_nonnegative_int(by_flow.get("tmux", 0), "delivered_dictations.by_flow.tmux")
    by_flow[flow] += 1
    words = len(re.findall(r"\b\w+\b", processed, flags=re.UNICODE))
    payload["processed_words"] = as_nonnegative_int(payload.get("processed_words", 0), "processed_words") + words
    payload["recording_duration_ms"] = as_nonnegative_int(payload.get("recording_duration_ms", 0), "recording_duration_ms") + int(record_ms)
    payload["full_elapsed_duration_ms"] = as_nonnegative_int(payload.get("full_elapsed_duration_ms", 0), "full_elapsed_duration_ms") + int(full_elapsed_ms)

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
            pass  # Retain a failed fixture write for inspection.
' "$(usage_summary_file)" "$flow" "$record_ms" "$full_elapsed_ms" <<<"$processed"
}
