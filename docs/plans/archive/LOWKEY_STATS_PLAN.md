# Lowkey stats window: make the habit visible

Status: approved (2026-10-14) after two oracle reviews (strategy + risks), with the user's v1 changes: no auto-send metric; an activity heatmap with 30/60/90-day ranges; words per minute up front.

A window opened from the Lowkey menu that makes dictating feel rewarding: totals, words per minute, a streak, records and an activity heatmap. Every number is either **measured** or **labelled as an estimate with its assumption shown**. Stats store counts and durations only, never what was said.

## Where we start (measured, 2026-10-14)
- `usage.json` (the durable ledger, since 2026-09-19): 80 delivered dictations, 24,306 words, 135 min of recording, 141 min from record start to delivery. At the default 40 wpm, typing that text would take ~608 min, so the estimated difference is ~466 min (7.8 h).
- 24,306 words / 135 recording minutes ≈ **180 wpm**.
- The ledger holds **totals only**. No dates beyond `tracking_started_at`, so streaks, the heatmap and records are impossible today.
- `bench.tsv` is capped at 800 rows and mixes failed runs. History keeps transcripts for 7 days. Neither is a sound base, so there is **no backfill**: daily stats start when stage 1 ships. Lifetime totals still go back to 2026-09-19 and are useful on day one.
- Monologue (the reference the user mentioned) publicly shows lifetime words, "hours saved", words in the last 30 days, and a lifetime leaderboard. A leaderboard doesn't fit a local, private tool.

## Review findings that changed the plan
1. **Lowkey's CLI fallback counts takes it may not deliver.** With `INLINE_DELIVERY_MODE=external`, `inline process` records usage (`bin/tmux-whisper:6387`) *before* Lowkey pastes (`processWithCLI`, `AppController.swift`). A paste failure still earns a dictation, words and a streak day. Fixed in stage 1 (deferred usage).
2. **Replay dedup isn't atomic with accounting.** `inline record` checks `recorded-takes` (`app.sh:404`), increments usage (`:431`), and appends the id later (`:477`). A crash in between double counts on replay. A failed usage write is still marked recorded, so it is never retried. Fixed in stage 1 (take ids inside the ledger).
3. **Write time is the wrong day for replayed takes.** Spooled takes replay at the next launch, possibly days later. The day must be the **local date at delivery**, carried through persistence.
4. **Dictating with the stats window in front.** Inline `paste_target` defaults to `current` (`config.sh:269`), so a take delivered while Stats is frontmost would paste and send into Lowkey and still count. This can also happen when Stats is opened *during* a take. The guard belongs at delivery, not only at start.
5. **Missing data is not zero.** If an older CLI writes totals but not days, an empty day might be unobserved, not idle. Presentation must say so instead of claiming a broken streak.
6. **A bounded `--days` query would silently lose records.** Derive from all days; bound only what's drawn.
7. **v1 was a dashboard, not the smallest reward loop.** It's cut to the core (below).
8. Wording: "Recording time", not "Time speaking" (pauses count). Words per minute is explained as words per minute of recording. "Stats store counts and durations only", not an app-wide "never stores what you said" (history and the spool do hold transcripts).

**Dropped: auto-send counting.** How often Enter was posted for you is trivia, not productivity, and doesn't fit the window's purpose (user, 2026-10-14). Dropping it also removes the delivery-receipt and tmux send-status work. Revisit only if it ever earns a place.

## Which metrics are honest

| Metric | Kind | Source | Label |
|---|---|---|---|
| Words | measured | `\b\w+\b` count of the delivered (cleaned) text | "Words" (the ⓘ popover gives the definition) |
| Dictations | measured | ledger count of confirmed deliveries | "Dictations" |
| **Words per minute** | measured | words / recording minutes, lifetime and per range | "180 wpm", with the ⓘ text "words per minute of recording, pauses included" |
| Saved vs typing | **estimate** | the existing `typing_equivalent − full_elapsed` (record start → delivered) | "≈ 7.8 h vs typing (estimate at 40 wpm)". The ⓘ popover gives the formula. Negative values are shown, never clamped. |
| Recording time | measured | `recording_duration_ms` | "Recording time" |
| Streak | measured, coverage-aware | local-date buckets | "5-day streak" (since daily tracking began) |
| Records | measured, "recorded bests" | per-day maxima | best day (words), longest take, longest streak |
| Activity | measured | day buckets | heatmap intensity = dictations that day, relative to your own active days |

Rules:
- The WPM *typing* assumption appears only beside the estimate, with how to change it (`DICTATE_HISTORY_TYPING_WPM`). Changing it recalculates history, as it does today. The measured wpm stands alone, with no typed-vs-spoken comparison.
- **"Used it for all your dictation" can't be measured.** Lowkey doesn't (and won't) watch keyboard typing, so the heatmap's strongest colour means "a big day for you", not "only dictated". The legend says "fewer → more dictations".
- **Coverage is part of the presentation.** "Totals since 19 Sep 2026 · daily since 15 Oct 2026". With untracked deliveries, a banner reads "Daily stats incomplete: N deliveries have no date". Daily values then read as lower bounds, and the window never says "streak broken".
- One approximate equivalence at most ("≈ 49 pages at 500 words a page").

## Stage 1: trustworthy daily accounting (CLI + small Lowkey changes)

### Stored ledger (`~/.config/dictate/usage.json`): additive, `schema_version` stays 1
Today's writer *refuses* a file whose `schema_version != 1`. Bumping it would make every older CLI on the machine stop counting. So the new data goes under new keys:

```json
{
  "schema_version": 1,
  "tracking_started_at": "2026-09-19T06:30:53Z",
  "delivered_dictations": {"count": 92, "by_flow": {"inline": 92, "tmux": 0}},
  "processed_words": 27716, "recording_duration_ms": 9292000, "full_elapsed_duration_ms": 9698000,
  "daily": {
    "started_at": "2026-10-15T08:00:00Z",
    "baseline_count": 80,
    "days": {
      "2026-10-15": {"count": 12, "inline": 12, "tmux": 0, "words": 3410, "recording_ms": 1180000,
                     "full_elapsed_ms": 1214000, "longest_recording_ms": 125608, "most_words": 402}
    }
  },
  "recent_take_ids": {"<uuid>": "2026-10-15"}
}
```

- **Day key = the Gregorian local date at delivery.** Lowkey sends `delivered_local_date` (computed at the moment of delivery, Gregorian calendar, system time zone) in `TakeRecord`, so a replay days later lands on the right day. The tmux and CLI-inline flows write at delivery, so they use `now()` in local time. `DICTATE_USAGE_NOW` plus `TZ` drive tests. Travel can move a take to a neighbouring day; that's documented. `started_at` and the day key come from the same instant.
- **`baseline_count`** is the total count *before* the delivery that created `daily`. So `untracked_deliveries = count − baseline_count − Σ days.count`, computed over **all** stored days, never over a `--days` slice.
- **Older writers are safe.** The current writer loads, mutates and dumps the whole document (`history.sh:335–367`), so it preserves the new keys verbatim but doesn't update them. Those deliveries show up as `untracked_deliveries`. The test uses the **real previous writer** (`git show origin/main:bin/tmux-whisper-lib/history.sh`), not a simulation.
- **A malformed `daily` never costs a delivery.** The totals update, `daily` is left untouched, stderr gets a warning, and the reader reports `status: "unreadable"`. Totals keep the existing refuse-to-overwrite rule.
- **Exactly-once inside the ledger.** `recent_take_ids` (transcript-free UUID → day, kept 14 days, longer than the spool's lifetime) is checked and updated under the ledger's existing lock and atomic replace, in the same write as the increment. A replay of a counted take is a no-op. Bounded: about 50 bytes per take.
- Size: days run about 180 bytes each, about 65 KB a year, with no pruning. Revisit after about 5 years.

### Delivery attribution
- `usage_record_delivery` gains named options `--local-date YYYY-MM-DD` and `--take-id ID`. The four positional arguments are unchanged, so every existing caller keeps working.
- **Lowkey native:** `TakeRecord` gains `delivered_local_date`.
- **Lowkey CLI fallback (deferred usage):** new capability `deferred_usage`. `inline process … --defer-usage` skips the ledger (history and bench as today). After delivery, Lowkey sends `inline record` with `"usage_only": true` and the real outcome and delivery time, with the delivered text so the CLI keeps owning the word count. That records usage once (by take id) and writes no second history or bench row. Without the capability (an older CLI), behaviour is today's, documented as legacy.
- **Retry eligibility:** `inline record` dedups history/bench (`recorded-takes`) and usage (`recent_take_ids`) separately. A replay retries whichever part failed. Lowkey keeps a take spooled while `usage_recorded` is false for a delivered take, within the spool's existing lifetime.

### Self-target guard (ships in stage 1: it protects counting, independent of the window)
- **At delivery:** before the first key is posted, if the frontmost app is Lowkey itself, nothing is pasted or sent. The text stays on the clipboard, the take ends as `paste_failed` (`error=target_is_lowkey`), the menu says "Lowkey was in front: text is on the clipboard", and nothing is counted.
- **At start:** Lowkey tracks the last active *other* app (`NSWorkspace.didActivateApplicationNotification`). If Lowkey is frontmost at the hotkey, the take's original app is that last external app. Delivery then re-checks as above. A terminated target app falls into the same guard.

### Output
- **Default `usage --json`:** unchanged, plus one additive field: `coverage.daily_tracking_started_at` (string|null). Existing `coverage.status` values and types are unchanged. SwiftBar reads named keys and checks only `command` and `schema_version` (`tmux-whisper-status.0.2s.sh:220–243`), and a regression test pins that.
- **New `usage --json --days N|all`** (N = the last N calendar dates including today, 1–3660; works in either flag order). It adds `daily: {status, started_at, as_of_local_date, range: {from, to}, untracked_deliveries, days: [...]}`, built from **validated, allow-listed numeric fields only**. The stored object is never passed through verbatim.
- `app-config --json` gains capabilities **`usage_days`** and **`deferred_usage`**, plus `usage.summary_path` (the resolved ledger path, since `DICTATE_USAGE_SUMMARY_FILE` can move it). Lowkey watches that path.
- Docs: README "Durable usage summary", `docs/CLI_CONTRACTS.md`, CHANGELOG.

### Stage 1 tests
All tests use scratch `DICTATE_CONFIG_DIR`/`DICTATE_USAGE_SUMMARY_FILE` and never touch the real config.
- **Bash:**
  - a fresh ledger creates `daily` with `baseline_count`;
  - a v1 ledger is upgraded on the next delivery, with totals unchanged;
  - the real previous writer preserves `daily` and shows up as untracked;
  - a malformed `daily` still records totals;
  - local date across UTC midnight (`TZ=Asia/Dubai`, `DICTATE_USAGE_NOW=2026-10-14T21:30:00Z` gives `2026-10-15`);
  - an explicit `delivered_local_date` beats write time (a replay the next day);
  - a replay of a counted take id is a no-op;
  - an interrupted record (usage written, `recorded-takes` not) doesn't double count;
  - a failed usage write is retried on replay;
  - `--defer-usage` + `usage_only` counts once, a paste failure counts zero, and there are no duplicate history/bench rows;
  - `--days` bounds, range and order, with untracked computed over all days;
  - the default output has no `days` and `schema_version` stays 1;
  - privacy: a sentinel word (`zqxsentinel`) and an injected transcript-like key in the stored file never appear in any output.
- **Swift:** `TakeRecord` encoding (`delivered_local_date`), and the self-target guard decision (a pure function in LowkeyCore: frontmost id vs own bundle id).
- Then `./tests/ci.sh`, `./install.sh --force`, and a Lowkey rebuild (checking `app.log` for a take in progress first). Real-use check: a few takes, then `usage --json --days 7`.

## Stage 2: the window (SwiftUI hosted in AppKit)

**SwiftUI in an `NSWindow` via `NSHostingController`.** Both reviews agree. Swift Charts and grid layout (macOS 14 target), semantic colours and animated numbers come almost free. AppKit would mean hand-drawing the heatmap.
- One reusable `StatsWindowController` owned by `AppController` (`isReleasedWhenClosed = false`, `setFrameAutosaveName`). Opening it activates the app and brings the window to the front. It's a normal key window: Escape/⌘W closes it and it's keyboard accessible. A "Stats…" menu item sits between "Cancel Recording" and "Reload Settings".
- **Code split:** `LowkeyCore/Stats/` holds `UsageReport` (Decodable for both CLI shapes, numeric fields only) and `UsageStats`. `UsageStats` derives streaks, records, range totals, the heatmap grid with intensity levels, and milestones from a Gregorian `Calendar` in the current time zone (the user's locale only decides week start and formatting) and a given "today". It's Swift 6 mode with Swift Testing. `Lowkey/Stats/` holds `StatsModel` (`@MainActor ObservableObject`) and the views. Views do no maths.

### v1 content (about 560 × 620, resizable)
1. **Hero:**
   - lifetime **words**;
   - "≈ 7.8 h vs typing (estimate at 40 wpm)" with ⓘ;
   - **180 wpm**, big, with ⓘ ("words per minute of recording, pauses included").
2. **Range picker: 30 · 60 · 90 days.** It drives the heatmap and the range line below it ("Last 30 days: 9,812 words · 41 dictations · 176 wpm"). Days before tracking began are excluded from range totals and the line says so ("Last 90 days (tracked since 15 Oct)").
3. **Activity heatmap:**
   - **Layout:** a GitHub-style grid (columns = weeks, rows = weekdays, week start from the locale), 30/60/90 days wide.
   - **Colour:** empty days are a neutral cell (`.quaternary`). Active days use the accent colour in **four intensity steps**, from faint to solid (opacity about 0.3 / 0.55 / 0.8 / 1.0).
   - **Intensity:** the day's dictation count against **your own** active days in the last 90 days, by quartile (as GitHub does), so "solid" means a big day *for you* and the scale grows with the habit. Until there are 14 active days, it uses fixed steps: 1–2 / 3–5 / 6–9 / 10+.
   - **Untracked days and today:** days before tracking began are an outlined, unfilled cell ("not tracked"), never empty grey. Today has a ring.
   - **Hover:** date, dictations, words and wpm.
   - **Legend:** "fewer → more dictations", plus the four swatches.
4. **Streak:** flame, "5-day streak · best 12". Nothing yet today reads "Dictate today to make it 6". If yesterday had no recorded dictation and coverage is complete, the streak shows 0, no guilt copy. If coverage is incomplete, the copy reads "Recorded streak", never "broken".
5. **Recorded bests:**
   - best day (words, date);
   - longest take (recording length, date);
   - longest streak (days, ending date).

   Each gets a "New" badge if set in the last 7 days.
6. **Small tiles:** Dictations · Recording time, lifetime with a today subline.
7. **Next milestone:** one slim progress bar to the next word milestone (1k, 5k, 10k, 25k, 50k, 100k, 250k, 500k, 1M; past 1M, every further 1M). On first open with existing totals it shows progress only, with no celebration for milestones passed before. Several crossed between openings show only the highest. The last milestone seen is kept in `UserDefaults` (a number, not content).
8. **Footer:** coverage dates, "Stats store counts and durations only", the typing-WPM assumption, "Updated 14:02" and a Refresh button.

Game feel: numbers count up on change (`.contentTransition(.numericText())`, off with Reduce Motion), heatmap cells deepen as the day fills, "New" badges and the milestone bar. No notifications, sounds or nagging.

### Light and dark
- **Colours:** semantic only: `.primary`/`.secondary`, the window background, `.quaternary` for empty cells and tile fills, the accent colour for the heatmap and `.orange` for the flame.
- **Heatmap in dark mode:** the opacity steps are checked against the dark background, since the faintest step must stay visible but distinct from empty. If opacity alone isn't enough, each step gets its own colour per appearance from the asset-free `NSColor(name:dynamicProvider:)`.
- **Type and symbols:** SF Symbols throughout, `.monospacedDigit()` on large numbers.
- **Verification:** a launch argument `-LowkeyStatsAppearance light|dark` forces `window.appearance` (no system setting is changed). The PR attaches screenshots of light, dark, empty, lifetime-only (old CLI) and incomplete-coverage states, with contrast checked on the rendered images.

### Refresh: event-driven, bounded, no polling
- The source is `CLIBridge.usage()`, which runs `usage --json --days all` (10 s timeout) on a **dedicated serial stats queue**, never the take, persist or settings queues. Scheduling lives on the main thread, apart from the blocking CLI call. At most one request runs, with at most one pending, coalesced *before* enqueueing.
- **Triggers while the window is open:**
  - window opens or becomes key;
  - a `DispatchSource` on the resolved ledger's directory, filtered by the ledger's inode/mtime/size signature, with a 300 ms debounce capped at 2 s so a stream of events can't postpone the refresh forever;
  - after installing the watcher, a recheck (so a change that lands while it's being set up isn't missed);
  - `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange` and wake from sleep;
  - the Refresh button.
- A generation token drops completions from a previous open. Nothing runs while the window is closed. A failed refresh keeps the last good data with fixed copy ("Couldn't refresh · Updated 14:02"), never CLI stderr.
- An older CLI without `usage_days` shows a lifetime-only window: "Update tmux-whisper for daily stats".

### Stage 2 tests
- **Swift:**
  - decoding of old and new output, with unknown keys and malformed values rejected;
  - streaks: today empty but yesterday active, gaps, month and year ends, the DST change in a fixed `Europe/London` calendar, incomplete coverage;
  - civil date keys parsed in Gregorian whatever the user's calendar setting;
  - range totals and wpm with untracked days excluded;
  - heatmap: grid layout for Monday and Sunday week starts and 30/60/90 ranges; intensity quartiles, the fixed-step fallback below 14 active days, and ties;
  - not-tracked vs empty days;
  - records and ties;
  - milestone progress (first open, several crossed, past 1M);
  - negative estimates;
  - refresh coalescing and stale-generation drop (a pure scheduler in LowkeyCore).
- **Manual:** open and close and reopen, Escape and ⌘W, the range picker, heatmap hover, light and dark, a dictation with Stats in front (both paste targets), Stats opened mid-take, a tmux take refreshing an open window, midnight rollover (with `DICTATE_USAGE_NOW`/fake data).

## Stage 3 (later, not committed)
- a weeks view and same-weekdays this/last week deltas;
- a wpm trend over time;
- a most-words-in-one-take record;
- `[usage] typing_wpm` in config.toml;
- a streak line in SwiftBar and `tmux-whisper usage` text;
- time-of-day patterns;
- an opt-in per-app breakdown.

## Smallest version worth shipping
Stage 1 then stage 2 as above, each its own branch and PR:
- `feat/usage-daily` from `main`;
- `feat/lowkey-stats-window`, once 3c-2 (`feat/lowkey-honest-chime-login`, unpushed) has merged, since both edit `AppController`'s menu.

Ship stage 1 promptly, because days only accumulate from then on. But it ships *with* the accounting fixes: collecting misleading history early isn't worth it.

## Build rules for this work
- Conventional commits ending with the session's `Co-Authored-By` line.
- `trash`, never `rm`.
- FluidAudio stays pinned.
- One build at a time in `tmux-whisperd/.build`.
- For Swift Testing, loop `swift build --build-tests` until "Build complete", then `swift test --skip-build`.
- `tools/build-lowkey-app.sh` only after checking `app.log` for a take in progress.

## Resolved review questions
1. **CLI surface:** `usage --json --days N|all`, defined as calendar dates including today, gated by capability.
2. **Auto-send time:** dropped entirely (user decision).
3. **Window focus:** a normal key window. Self-targeting is prevented at delivery, plus a start-time fallback to the last external app.
4. **Day key:** the Gregorian local date captured at delivery and carried through replay. UTC daily aggregates can't be re-bucketed later, and per-take timestamps aren't needed for this feature.
