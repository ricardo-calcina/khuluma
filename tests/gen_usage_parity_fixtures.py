#!/usr/bin/env python3
"""Record what the repo CLI's `usage --json --days all` prints for a set of
usage.json files, with a fixed clock and time zone, so the app's native port
(UsageReportBuilder) can be checked against it.

    python3 tests/gen_usage_parity_fixtures.py   # rewrites the fixture

Output: tests/fixtures/usage-parity/cases.json. Numbers and dates only. Run it
only when the CLI's usage rules change on purpose; the Swift test
(UsageParityTests) reads the file.
"""
import copy
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests/fixtures/usage-parity/cases.json"
NOW = "2026-10-20T20:30:00Z"


def bucket(count=2, words=40, rec=9000, full=11000, longest=6000, most=30, inline=None, tmux=0):
    return {"count": count, "inline": count if inline is None else inline, "tmux": tmux, "words": words,
            "recording_ms": rec, "full_elapsed_ms": full, "longest_recording_ms": longest, "most_words": most}


def usage(count=10, words=1000, rec=60000, full=70000, daily=None, started="2026-09-19T06:30:53Z", **extra):
    doc = {"schema_version": 1, "tracking_started_at": started,
           "delivered_dictations": {"count": count, "by_flow": {"inline": count, "tmux": 0}},
           "processed_words": words, "recording_duration_ms": rec, "full_elapsed_duration_ms": full}
    if daily is not None:
        doc["daily"] = daily
    doc.update(extra)
    return doc


def daily(days, baseline=0, started="2026-10-14T21:30:00Z"):
    return {"started_at": started, "baseline_count": baseline, "days": days}


def many_days(n=120):
    start = datetime.date(2026, 6, 1)
    days = {}
    for i in range(n):
        d = start + datetime.timedelta(days=i * 1 if i % 7 else 2)
        days[d.isoformat()] = bucket(count=1 + i % 5, words=10 * (i % 13), rec=1000 * i, full=1200 * i,
                                     longest=500 * (i % 9), most=7 * (i % 11))
    # JSON object order is arbitrary on disk: write them unsorted.
    return dict(reversed(list(days.items())))


CASES = [
    {"name": "missing-file", "file": None},
    {"name": "fresh-totals-only", "file": usage(count=3, words=100, rec=5000, full=6000)},
    {"name": "fresh-nothing-counted", "file": usage(count=0, words=0, rec=0, full=0, started="2026-10-20T08:00:00Z")},
    {"name": "no-tracking-started-at", "file": {**usage(), "tracking_started_at": None}},
    {"name": "empty-tracking-started-at", "file": {**usage(), "tracking_started_at": ""}},
    {"name": "fractional-tracking-started-at", "file": usage(started="2026-09-19T06:30:53.250Z")},
    {"name": "offset-tracking-started-at", "file": usage(started="2026-09-19T10:30:53+04:00")},
    {"name": "daily-one-day-today", "file": usage(count=2, daily=daily({"2026-10-20": bucket()}, baseline=0))},
    {"name": "daily-legacy-no-daily-section", "file": usage(count=82, words=24311)},
    {"name": "daily-untracked-deliveries", "file": usage(count=50, daily=daily({"2026-10-18": bucket(count=3), "2026-10-20": bucket(count=4)}, baseline=20))},
    {"name": "daily-untracked-never-negative", "file": usage(count=5, daily=daily({"2026-10-20": bucket(count=9)}, baseline=3))},
    {"name": "daily-empty-days", "file": usage(count=7, daily=daily({}, baseline=7))},
    {"name": "daily-future-day-extends-range", "file": usage(daily=daily({"2026-10-25": bucket(), "2026-10-19": bucket()}, baseline=1))},
    {"name": "daily-all-days-in-past", "file": usage(daily=daily({"2026-01-01": bucket(), "2026-02-03": bucket()}, baseline=0))},
    {"name": "daily-many-days-unsorted", "file": usage(count=700, words=50000, daily=daily(many_days(), baseline=10))},
    {"name": "daily-year-boundary", "file": usage(daily=daily({"2025-12-31": bucket(), "2026-01-01": bucket(), "2024-02-29": bucket()}))},
    {"name": "daily-started-at-fractional", "file": usage(daily=daily({"2026-10-20": bucket()}, started="2026-10-14T21:30:00.5+04:00"))},
    {"name": "daily-null", "file": {**usage(), "daily": None}},
    {"name": "daily-string", "file": usage(daily="nope")},
    {"name": "daily-list", "file": usage(daily=[])},
    {"name": "daily-days-not-object", "file": usage(daily={"started_at": "2026-10-14T21:30:00Z", "baseline_count": 0, "days": []})},
    {"name": "daily-missing-days", "file": usage(daily={"started_at": "2026-10-14T21:30:00Z", "baseline_count": 0})},
    {"name": "daily-missing-started-at", "file": usage(daily={"baseline_count": 0, "days": {}})},
    {"name": "daily-bad-started-at", "file": usage(daily=daily({}, started="yesterday"))},
    {"name": "daily-started-at-no-zone", "file": usage(daily=daily({}, started="2026-10-14T21:30:00"))},
    {"name": "daily-started-at-number", "file": usage(daily={"started_at": 5, "baseline_count": 0, "days": {}})},
    {"name": "daily-missing-baseline", "file": usage(daily={"started_at": "2026-10-14T21:30:00Z", "days": {}})},
    {"name": "daily-negative-baseline", "file": usage(daily=daily({}, baseline=-1))},
    {"name": "daily-float-baseline", "file": usage(daily={"started_at": "2026-10-14T21:30:00Z", "baseline_count": 2.0, "days": {}})},
    {"name": "daily-bool-baseline", "file": usage(daily={"started_at": "2026-10-14T21:30:00Z", "baseline_count": True, "days": {}})},
    {"name": "daily-bad-date-key", "file": usage(daily=daily({"2026-13-01": bucket()}))},
    {"name": "daily-bad-date-shape", "file": usage(daily=daily({"2026-1-05": bucket()}))},
    {"name": "daily-feb-30", "file": usage(daily=daily({"2026-02-30": bucket()}))},
    {"name": "daily-bucket-not-object", "file": usage(daily=daily({"2026-10-20": 5}))},
    {"name": "daily-negative-field", "file": usage(daily=daily({"2026-10-20": {**bucket(), "words": -1}}))},
    {"name": "daily-float-field", "file": usage(daily=daily({"2026-10-20": {**bucket(), "words": 3.0}}))},
    {"name": "daily-bool-field", "file": usage(daily=daily({"2026-10-20": {**bucket(), "count": True}}))},
    {"name": "daily-string-field", "file": usage(daily=daily({"2026-10-20": {**bucket(), "words": "3"}}))},
    {"name": "daily-null-field", "file": usage(daily=daily({"2026-10-20": {**bucket(), "most_words": None}}))},
    {"name": "daily-missing-field", "file": usage(daily=daily({"2026-10-20": {k: v for k, v in bucket().items() if k != "tmux"}}))},
    {"name": "daily-one-bad-day-spoils-all", "file": usage(daily=daily({"2026-10-19": bucket(), "2026-10-20": {**bucket(), "inline": -5}}))},
    {"name": "daily-extra-bucket-keys-ignored", "file": usage(daily=daily({"2026-10-20": {**bucket(), "note": "x", "by_flow": {}}}))},
    {"name": "daily-extra-section-keys-ignored", "file": usage(daily={**daily({"2026-10-20": bucket()}), "future": 1})},
    {"name": "totals-negative-become-zero", "file": {**usage(), "processed_words": -5, "recording_duration_ms": -1, "full_elapsed_duration_ms": -9}},
    {"name": "totals-strings", "file": {**usage(), "processed_words": "120", "recording_duration_ms": " 5000 ", "full_elapsed_duration_ms": "6e3"}},
    {"name": "totals-floats-truncate", "file": {**usage(), "processed_words": 120.9, "recording_duration_ms": 5000.5, "full_elapsed_duration_ms": 6000.0}},
    {"name": "totals-bools", "file": {**usage(), "processed_words": True, "recording_duration_ms": False}},
    {"name": "totals-null-and-list", "file": {**usage(), "processed_words": None, "recording_duration_ms": [1], "full_elapsed_duration_ms": {}}},
    {"name": "count-string", "file": {**usage(), "delivered_dictations": {"count": "12", "by_flow": {"inline": 12}}}},
    {"name": "by-flow-missing", "file": {**usage(), "delivered_dictations": {"count": 4}}},
    {"name": "estimate-negative", "file": usage(count=1, words=10, rec=1000, full=900000)},
    {"name": "estimate-zero-words-elapsed", "file": usage(count=1, words=0, rec=1000, full=5000)},
    {"name": "typing-wpm-60", "file": usage(words=1234), "wpm": "60"},
    {"name": "typing-wpm-garbage", "file": usage(words=1234), "wpm": "abc"},
    {"name": "typing-wpm-zero", "file": usage(words=1234), "wpm": "0"},
    {"name": "typing-wpm-negative", "file": usage(words=1234), "wpm": "-5"},
    {"name": "typing-wpm-1", "file": usage(words=1234), "wpm": "1"},
    {"name": "typing-rounds-half-to-even-up", "file": usage(words=1, full=0), "wpm": "40000"},
    {"name": "typing-rounds-half-to-even-down", "file": usage(words=3, full=0), "wpm": "40000"},
    {"name": "typing-rounds-thirds", "file": usage(words=7, full=0), "wpm": "3"},
    {"name": "tz-auckland-next-day", "file": usage(daily=daily({"2026-10-20": bucket(), "2026-10-21": bucket()})), "tz": "Pacific/Auckland"},
    {"name": "tz-los-angeles-same-day", "file": usage(daily=daily({"2026-10-20": bucket()})), "tz": "America/Los_Angeles"},
    {"name": "tz-london-dst-change", "file": usage(daily=daily({"2026-10-25": bucket(), "2026-10-26": bucket()})), "tz": "Europe/London", "now": "2026-10-25T23:30:00Z"},
    {"name": "tz-dubai-midnight", "file": usage(daily=daily({"2026-10-21": bucket()})), "tz": "Asia/Dubai", "now": "2026-10-20T20:00:00Z"},
    {"name": "tz-dubai-before-midnight", "file": usage(daily=daily({"2026-10-20": bucket()})), "tz": "Asia/Dubai", "now": "2026-10-20T19:59:59Z"},
    {"name": "error-unreadable-json", "raw": "{not json"},
    {"name": "error-empty-file", "raw": ""},
    {"name": "error-schema-2", "file": {**usage(), "schema_version": 2}},
    {"name": "error-no-schema", "file": {k: v for k, v in usage().items() if k != "schema_version"}},
    {"name": "error-no-deliveries", "file": {k: v for k, v in usage().items() if k != "delivered_dictations"}},
    {"name": "error-deliveries-not-object", "file": {**usage(), "delivered_dictations": 5}},
]


def record(case):
    root = Path(tempfile.mkdtemp(prefix="khuluma-usage-parity-"))
    config = root / "config"
    config.mkdir()
    (root / "home").mkdir()
    (config / "config.toml").write_text("[meta]\nconfig_version = 1\n[clean]\nenabled = true\nrepeats_level = 3\n")
    # The exact bytes, as text: 3.0 and 3 must stay different for the port.
    file_text = case["raw"] if "raw" in case else (None if case["file"] is None else json.dumps(case["file"]))
    if file_text is not None:
        (config / "usage.json").write_text(file_text)
    now = case.get("now", NOW)
    tz = case.get("tz", "Asia/Dubai")
    env = {"HOME": str(root / "home"), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C",
           "KHULUMA_CONFIG_DIR": str(config), "KHULUMA_LIB_PATH": str(ROOT / "bin/khuluma-lib.sh"),
           "KHULUMA_INTERNAL_LIB_DIR": str(ROOT / "bin/khuluma-lib"), "XDG_DATA_HOME": str(root / "data"),
           "TZ": tz, "KHULUMA_USAGE_NOW": now}
    if "wpm" in case:
        env["KHULUMA_HISTORY_TYPING_WPM"] = case["wpm"]
    result = subprocess.run([str(ROOT / "bin/khuluma"), "usage", "--json", "--days", "all"],
                            env=env, capture_output=True, text=True)
    out = {"name": case["name"], "now": now, "tz": tz, "wpm": case.get("wpm"),
           "file_text": file_text, "ok": result.returncode == 0}
    if result.returncode == 0:
        out["expected"] = json.loads(result.stdout)
    else:
        out["error"] = result.stderr.strip()
    return out


def main():
    cases = [record(case) for case in CASES]
    OUT.write_text(json.dumps(cases, indent=1) + "\n")
    print(f"wrote {len(cases)} cases to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
