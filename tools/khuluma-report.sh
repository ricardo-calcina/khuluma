#!/usr/bin/env bash
# Summarise Khuluma's app.log: take outcomes, where the time goes, daemon
# warmups and timed-out retries. Transcript-free:
# it prints counts and timings only, never dictated text.
#
#   tools/khuluma-report.sh                  # the whole log
#   tools/khuluma-report.sh --days 2         # today and yesterday
#   tools/khuluma-report.sh --since 2026-10-12 --system
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/bin/khuluma-lib/identity.sh"
khuluma_normalize_environment

LOG="${KHULUMA_LOG:-$HOME/Library/Logs/Khuluma/app.log}"
# Before the rename the app logged under Lowkey; its first launch as Khuluma
# moves the log, so the old path only matters until then.
if [[ -z "${KHULUMA_LOG:-}" && ! -e "$LOG" && -e "$HOME/Library/Logs/Lowkey/app.log" ]]; then
  LOG="$HOME/Library/Logs/Lowkey/app.log"
fi
SINCE=""
DAYS=""
SYSTEM=0

usage() {
  echo "usage: $0 [--log PATH] [--since YYYY-MM-DD | --days N] [--system]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) [[ $# -ge 2 ]] || usage; LOG="$2"; shift ;;
    --since) [[ $# -ge 2 ]] || usage; SINCE="$2"; shift ;;
    --days) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; DAYS="$2"; shift ;;
    --system) SYSTEM=1 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
  shift
done

[[ -r "$LOG" ]] || { echo "no log at $LOG" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

python3 -I - "$LOG" "$SINCE" "$DAYS" <<'PY'
import datetime as dt
import re
import statistics
import sys
from collections import Counter

log_path, since_arg, days_arg = sys.argv[1], sys.argv[2], sys.argv[3]

today = dt.date.today()
since = None
if since_arg:
    try:
        since = dt.date.fromisoformat(since_arg)
    except ValueError:
        sys.exit(f"--since wants YYYY-MM-DD, got {since_arg!r}")
elif days_arg:
    since = today - dt.timedelta(days=max(int(days_arg), 1) - 1)

LINE = re.compile(r"^\[([^\]]+)\] (.*)$")
CODE = re.compile(r"^[a-z0-9_]{1,40}$")
PAIR = re.compile(r'([A-Za-z_]+)=("((?:[^"\\]|\\.)*)"|\S*)')


def parse_pairs(text):
    fields = {}
    for match in PAIR.finditer(text):
        key, raw, quoted = match.group(1), match.group(2), match.group(3)
        if raw.startswith('"'):
            fields[key] = re.sub(r"\\(.)", r"\1", quoted)
        else:
            fields[key] = raw
    return fields


def num(fields, key):
    try:
        return float(fields[key])
    except (KeyError, ValueError):
        return None


def local_day(stamp):
    try:
        moment = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment.astimezone().date()


takes = []          # `take:` lines
first_audio = []
capturing = []
start_failures = 0
warmups = []        # (ms, trigger)
unavailable = Counter()
retries = Counter()
first_day = last_day = None

with open(log_path, encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        match = LINE.match(raw.rstrip("\n"))
        if not match:
            continue
        day = local_day(match.group(1))
        if day is None or (since and day < since):
            continue
        message = match.group(2)
        first_day = first_day or day
        last_day = day

        if message.startswith("take: "):
            fields = parse_pairs(message[6:])
            fields["_day"] = day
            takes.append(fields)
        elif message.startswith("stop: "):
            found = re.search(r"hotkey→first audio ([\d.]+)ms", message)
            if found:
                first_audio.append(float(found.group(1)))
        elif message.startswith("start: engine.start"):
            found = re.search(r"hotkey→capturing ([\d.]+)ms", message)
            if found:
                capturing.append(float(found.group(1)))
        elif message.startswith("error: could not start recording"):
            start_failures += 1
        elif message.startswith("supervisor: daemon warmed"):
            found = re.search(r"warmed in (\d+)ms \(([^)]*)\)", message)
            if found:
                warmups.append((float(found.group(1)), found.group(2)))
        elif message.startswith("supervisor: daemon unavailable"):
            found = re.search(r"unavailable: (.*?) \(", message)
            unavailable[found.group(1) if found else "?"] += 1
        elif message.startswith("retry: "):
            if "transcribed a timed-out" in message:
                retries["transcribed"] += 1
            elif "pasted a retried" in message:
                retries["pasted"] += 1
            elif "discarded" in message:
                retries["discarded"] += 1


def median(values):
    return statistics.median(values) if values else None


def p90(values):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, -(-len(ordered) * 9 // 10) - 1)]


def ms(value):
    return "-" if value is None else f"{value:.0f}ms"


def spread(values):
    return f"median {ms(median(values))}, p90 {ms(p90(values))} (n={len(values)})"


def pct(part, whole):
    return f"{100 * part / whole:.1f}%" if whole else "-"


window = f"{first_day} to {last_day}" if first_day else "no entries"
if since:
    window += f" (since {since})"
print(f"Khuluma report: {log_path}")
print(f"Window: {window}, local time")

# --- Takes ------------------------------------------------------------------
print()
paths = Counter(t.get("path", "?") for t in takes)
outcomes = Counter(t.get("outcome", "?") for t in takes)
print(f"Takes: {len(takes)}"
      + (" (" + ", ".join(f"{k} {v}" for k, v in paths.most_common()) + ")" if takes else ""))
if takes:
    print("  outcomes: " + ", ".join(f"{k} {v}" for k, v in outcomes.most_common()))
    tried_native = paths["native"] + paths["fallback"]
    fallback_reasons = Counter(t.get("reason", "?") for t in takes if t.get("path") == "fallback")
    print(f"  fallback rate: {pct(paths['fallback'], tried_native)} ({paths['fallback']} of {tried_native} tried natively)"
          + ("; " + ", ".join(f"{r} x{n}" for r, n in fallback_reasons.most_common()) if fallback_reasons else ""))
    cli_reasons = Counter(t.get("reason", "?") for t in takes if t.get("path") == "cli")
    if cli_reasons:
        print("  CLI by settings: " + ", ".join(f"{r} x{n}" for r, n in cli_reasons.most_common()))
    failed = [t for t in takes if t.get("outcome") in ("failed", "timed_out", "paste_failed", "no_audio")]
    print(f"  failure rate: {pct(len(failed), len(takes))} ({len(failed)} of {len(takes)})")
    # Error fields are codes; print nothing that isn't one.
    errors = Counter(t.get("outcome") + (f": {t['error'] if CODE.match(t['error']) else 'other'}" if "error" in t else "")
                     for t in failed)
    for error, count in errors.most_common(5):
        print(f"    {error} x{count}")
states = Counter(t.get("state", "?") for t in takes if t.get("path") == "native")
if states:
    print("  daemon at stop (native): " + ", ".join(f"{k} {v}" for k, v in states.most_common()))
if start_failures:
    print(f"  recordings that failed to start: {start_failures}")
if retries:
    print("  timed-out retries: " + ", ".join(f"{k} {v}" for k, v in retries.most_common()))

# --- Native timing ------------------------------------------------------------
BUCKETS = [("under 5s", 0, 5_000), ("5-15s", 5_000, 15_000), ("15-60s", 15_000, 60_000),
           ("60s and over", 60_000, float("inf"))]


def overhead(take):
    """Stop to delivered, minus the model's own time and the deliberate
    delivery waits: what Khuluma, the socket and the OS add."""
    total, waits = num(take, "total"), num(take, "waits")
    if total is None or waits is None:
        return None
    daemon = []
    # Every pass that was sent needs the daemon's time (a failed tail pass
    # has none, and its model time would otherwise count as overhead).
    for elapsed, key in (("full", "full_daemon"), ("tail", "tail_daemon")):
        if elapsed in take or key in take:
            daemon.append(num(take, key))
    if not daemon or None in daemon:
        return None
    return total - sum(daemon) - waits


def transport(take):
    parts = []
    for elapsed, daemon in (("full", "full_daemon"), ("tail", "tail_daemon")):
        if elapsed in take:
            if daemon not in take:
                return None
            parts.append(num(take, elapsed) - num(take, daemon))
    return sum(parts) if parts else None


delivered = [t for t in takes if t.get("path") == "native" and t.get("outcome") == "delivered"]
timed = [t for t in delivered if overhead(t) is not None]
incomplete = len(delivered) - len(timed)
# Cold takes include the model load, which the daemon's time leaves out, and
# contended ones a wait behind another request: judge overhead on warm takes.
warm = [t for t in timed if t.get("state") == "warm"]
print()
print(f"Native takes delivered: {len(delivered)} ({len(timed)} with daemon timings, {len(warm)} warm)")
if incomplete:
    print(f"  {incomplete} without daemon timings for every pass (older daemon or a failed tail pass): left out")
if warm:
    print(f"  overhead, warm (stop to delivered, minus Parakeet and delivery waits): {spread([overhead(t) for t in warm])}")
    for label, low, high in BUCKETS:
        bucket = [overhead(t) for t in warm if low <= (num(t, "record") or 0) < high]
        if bucket:
            print(f"    {label:>13}: {spread(bucket)}")
not_warm = [t for t in timed if t.get("state") != "warm"]
if not_warm:
    states_seen = ", ".join(sorted({t.get("state", "?") for t in not_warm}))
    print(f"  overhead, not warm ({states_seen}): {spread([overhead(t) for t in not_warm])}")
if timed:
    print(f"  stop to delivered: {spread([num(t, 'total') for t in timed])}")
    print(f"  Parakeet (daemon): {spread([num(t, 'full_daemon') + (num(t, 'tail_daemon') or 0) for t in timed])}")
    # The plan's in-process trigger: WAV plus socket cost on warm takes. The
    # residual is request time minus model time, so it also holds any wait
    # behind a request that arrived after the stop-time ping.
    in_process = [num(t, "prep") + transport(t) for t in warm if "prep" in t and transport(t) is not None]
    for label, values in (
        ("queue", [num(t, "queue") for t in timed]),
        ("WAV prep", [num(t, "prep") for t in timed if "prep" in t]),
        ("probe wait", [num(t, "probe") for t in timed if "probe" in t]),
        ("request minus model time (warm)", [transport(t) for t in warm if transport(t) is not None]),
        ("WAV prep + request residual (warm)", in_process),
        ("cleanup", [num(t, "clean") for t in timed if "clean" in t]),
        ("delivery minus waits", [num(t, "deliver") - num(t, "waits") for t in timed if "deliver" in t]),
    ):
        if values:
            print(f"    {label}: {spread(values)}")
    rescued = [t for t in timed if "tail_window" in t]
    if rescued:
        failed_tails = sum(1 for t in rescued if t.get("tail_failed") == "1")
        print(f"  tail rescue: {len(rescued)} takes, {failed_tails} tail passes failed")
cold = [t for t in delivered if t.get("state") == "cold"]
if cold:
    print(f"  cold takes, stop to delivered: {spread([num(t, 'total') for t in cold])}")

# --- Capture start ------------------------------------------------------------
if first_audio or capturing:
    print()
    print("Recording start")
    if capturing:
        print(f"  hotkey to capturing: {spread(capturing)}")
    if first_audio:
        print(f"  hotkey to first audio: {spread(first_audio)}")

# --- Daemon -------------------------------------------------------------------
print()
print("Daemon")
if warmups:
    triggers = Counter(trigger for _, trigger in warmups)
    print(f"  model warmups started by Khuluma (daemon model warmup time): {spread([w for w, _ in warmups])}, max {ms(max(w for w, _ in warmups))}"
          + "; " + ", ".join(f"{k} {v}" for k, v in triggers.most_common()))
else:
    print("  model warmups started by Khuluma: none")
if unavailable:
    print("  unavailable: " + ", ".join(f"{k} x{v}" for k, v in unavailable.most_common(5)))
PY

if [[ "$SYSTEM" == "1" ]]; then
  echo
  echo "System (memory spot check)"
  level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "?")"
  case "$level" in
    1) level="normal" ;; 2) level="warn" ;; 4) level="critical" ;;
  esac
  echo "  memory pressure: $level"
  echo "  swap: $(sysctl -n vm.swapusage 2>/dev/null || echo "?")"
  # Counts since boot (pages).
  vm_stat 2>/dev/null | awk -F: '/Swapins|Swapouts|Pages stored in compressor|Pages occupied by compressor/ {
    gsub(/[ .]/, "", $2); printf "  %s: %s\n", $1, $2
  }'
  ps -axo rss=,comm= 2>/dev/null | awk '
    $2 ~ /khulumad$/ || $2 ~ /tmux-whisperd$/ || $2 ~ /Khuluma$/ || $2 ~ /Lowkey$/ {
      n = split($2, part, "/"); printf "  %s RSS: %.0f MB\n", part[n], $1 / 1024
    }'
fi
