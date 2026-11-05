# App independence: Khuluma.app without the CLI

Status: plan revised after two Codex Sol reviews (strategy, risks), 2026-11-05 (tab "Khuluma app without the CLI", branch `wip/app-independence`). Replaces LOG Next items "Phase 1 step 1", "Phase 1 after the native writers" and "Phase 1 delivery".

## Goal

The native app dictates, saves history, tracks usage and shows Stats on a Mac with no `khuluma` CLI. The app and the CLI each work alone. When both are installed they share one history, one usage ledger, one bench table and one log, every record names its writer (app or CLI, plus version), and concurrent writes never lose or double-count anything.

## Where the app depends on the CLI today

`native/Sources/Khuluma/CLIBridge.swift` runs `khuluma` for:

| Call | Used for | Replacement |
|---|---|---|
| `version --json`, `app-config --json` | locate CLI, contract check, all settings | native config reader (slice 4) |
| `app-settings set` | Settings writes | native config writer (slice 4) |
| `vocab-sheet show/validate/save` | Vocabulary editor | native, same lock/backups (slice 4) |
| `history export` | recent dictations (editor examples) | native history reader (slice 3) |
| `inline record` | history, bench, usage after each native take | native writers (slice 2) |
| `usage --json --days all` | Stats and menu figures | native usage reader (slice 3) |
| `warmup --json` | starts/builds khulumad from source, loads model | bundled daemon the app supervises (slice 5) |
| `inline process` | fallback route + ElevenLabs Scribe | drop fallback; port Scribe or drop it (slice 6) |

Sounds come from `~/.local/share/sounds/khuluma` (installed by the CLI installer); the model path comes from config (today FluidAudio's shared cache).

## Shared data contract (slice 0, lands on main first)

A new section in `docs/CLI_CONTRACTS.md`, "Shared data contract 1". Summary:

**Roots.** Unchanged so existing data keeps working: config, vocabulary, history, bench and usage under `~/.config/khuluma`, with every existing override honoured (`KHULUMA_CONFIG_DIR`, XDG, config-file and `KHULUMA_USAGE_SUMMARY_FILE`); logs under `~/Library/Logs/Khuluma`. Moving data to Application Support stays Phase 3.

**Writer tag.** Every new record carries `writer`: `{"name": "app"|"cli", "version": "<semver>", "build": "<n or null>"}`, compact form `app/0.12.0+416`, `cli/0.12.0`. Records written before contract 1, or by the installed v0.11 CLI during the transition, have no tag and read as `unknown`.

**Take identity.** Every destination records `take_id`, and each write is idempotent per destination by take id, checked under that destination's lock. That replaces the separate replay ledgers (which commit after the write, so a crash between them duplicates). The old `.cache/recorded-takes*` ledgers are still read for takes written before contract 1, and retired only once no pending record predates it.

| File | Lock (contract 1) | Change |
|---|---|---|
| `history/<local-ts>[_N].json` | new `flock(history/.history.lock)` around the take-id check and publish; exclusive create kept | add `take_id`, `writer`; publish atomically (write temp, `link()` to the claimed name, fsync) |
| `history/bench.tsv` | `bench.tsv.lock.d` mkdir lock as today; new writers never append without it (no lock in 3 s = skip the row and log it, bench is diagnostics) | column 20 `writer`, column 21 `take_id`; readers treat missing columns as unknown |
| `usage.json` | `flock(usage.json.lock)` as today | stays `schema_version: 1` (v0.11 refuses anything else); add top-level `by_writer {app, cli}`, counting tagged deliveries only, plus `attribution_started_at`; unattributed = count minus the sum. Day buckets stay closed (v0.11 rewrites them with known keys only). No `last_write` (v0.11 would leave it stale) |
| `config.toml` | new `flock(config.toml.lock)` around every read-modify-replace, both sides (today only the last-good copy is locked, so concurrent setting changes can overwrite each other) | format unchanged; full TOML, not a subset (the CLI parses with `tomllib`); invalid file falls back to last-good, never rewritten |
| `vocabulary.json` | `flock(.vocabulary.lock)`, revision, backups, as today | unchanged; stays closed-schema (no writer field inside) |
| `recording.lock` | non-blocking `flock`, held for the whole capture, never unlinked; one JSON line inside `{writer, pid, started_at, take_id}`; the CLI passes the locked fd to its ffmpeg child, the app opens it `O_CLOEXEC` | new: one recording at a time across app and CLI; held = refuse and name the holder |
| `data-contract.json` | written atomically | new: `{"data_contract": 1, "set_by": <writer>}`; missing = 1; a side that supports less than the file says refuses shared writes and names the product to update. Only participating versions honour it; v0.11 can't |
| `~/Library/Logs/Khuluma/khuluma.log` | `O_APPEND`, one `write()` per line | new shared human log, `[ISO time] [app/0.12.0+416] message`; `app.log` stops growing and is kept; `tools/khuluma-report.sh` reads both |

**Rules.** Writers preserve unknown keys. Additive fields only within contract 1. Transcript text only in history and pending recovery, never in usage, bench or logs. `khuluma version --json` and the app's launch log line report `data_contract`.

**Transition with the installed v0.11 CLI.** It keeps writing until the split tab ships a contract-1 CLI. Its rows are untagged (`unknown`), it ignores the new locks on config and history, and it can append to bench unlocked after a 3 s timeout. The guarantees above hold fully only between contract-1 writers; with v0.11 they degrade to today's behaviour, not worse. Acceptance tests run new app against the real frozen v0.11 executable as well as against the new CLI.

**Daemon.** Separate at first: the app runs its bundled `khulumad` as an owned child on its own socket in Application Support (stopped on quit, restarted after a crash); the CLI keeps its own. Sharing one warm daemon comes later, once the daemon protocol carries a version. Measure memory with both warm.

## Slices

Each slice: a worker builds it, a Codex reviewer reviews it, fixes go back to the same worker, I commit and push `wip/app-independence`.

0. **Contract doc** (docs only) → rebase, land on main, tell the split tab.
1. **CLI writers to contract 1**: tag, take id and idempotency in `save_history`, `append_bench_entry`, `usage_record_delivery`; config write lock; no unlocked bench append; `khuluma_log` helper; recording-lock and data-contract helpers for the split tab to call; `version --json` reports `data_contract`. Shell tests, including old readers still parsing.
2. **Native writers and a durable spool**: `HistoryWriter`, `BenchWriter`, `UsageLedger`, `SharedLog`, `RecordingLock` in `KhulumaCore`, same locks and idempotency. Pending records keep per-destination done flags, are fsynced, never expire while unresolved, and unreadable ones are quarantined, not deleted (today: deleted, and anything older than 7 days dropped). Shared fixtures in `tests/fixtures/shared-data/` drive Swift and shell writers. Kill-between-every-step, duplicate-submission, disk-full, lock-timeout and paused-trim tests, plus Swift vs CLI (new and frozen v0.11) concurrent writers with exact totals. `TakePersister` switches off `inline record`; build-415 spooled records still replay.
3. **Minimal standalone path** (proves the big risk early): native config reader (full TOML, overrides, last-good fallback; parity fixtures against `app-config --json`), bundled `khulumad` started by the app, native Stats/menu figures from `usage.json` and recent dictations from `history/`. Remove CLI-era eligibility gates that would strand a take without the CLI: ffmpeg/ffprobe required, non-C locales refused, numeric overrides forcing the CLI route. Gate: one real take with no CLI, ffmpeg or Python reachable.
4. **Settings and vocabulary writes**: native Settings writer under the config lock (same atomic, symlink-keeping rules), vocabulary show/validate/save under `.vocabulary.lock`.
5. **First run**: model download through FluidAudio with progress in the menu; bundled sounds (`~/.local/share/sounds/khuluma` still overrides); microphone and PostEvent permission gates with plain prompts. Denied or revoked PostEvent makes delivery fail (take kept, no usage), not log-and-continue as today.
6. **Cut the cord**: delete `CLIBridge`, the CLI route and `app_contract`. A take that can't be processed natively goes to recovered and retries; never lost. A config set to ElevenLabs is handled explicitly (decision 1), never silently switched.
7. **Acceptance and merge** (below): merge to main after isolated acceptance and Ricardo's OK on an installed build; the 14-day observation runs after the merge as its own LOG item.

## Acceptance

- **Isolated, this Mac**: worktree build with the isolation overrides and a private config root, `KHULUMA_CLI` and the default CLI paths unreachable (PATH alone doesn't hide it; discovery checks fixed paths), no ffmpeg or Python on its path. Real takes into TextEdit; cancel, quit mid-take, daemon kill and restart, sleep/wake, recovery retry; history + bench + usage written once each with `writer: app` and the take id; Stats shows them; relaunch keeps them.
- **With a CLI on the same fixture root**: the new CLI and the frozen v0.11 executable each read the app's takes; their writes show in the app's Stats; concurrent stress leaves exact totals; delivered take ids in usage match history minus recovered (history-only) takes.
- **Clean account** (decisive gate): Ricardo creates a standard macOS user once (about 15 minutes). No CLI, Homebrew tools, Python or developer tools there. Copy the build to `/Users/Shared`, open it: permission prompts (and denial: take kept, nothing counted), model download, one take into TextEdit, Stats shows 1, history entry tagged `app`. Then install the CLI there and confirm it reads the same take and its own take shows in the app.
- **Daily, after merge**: 14 days with no `khuluma` process started by the app and delivered take ids reconciled between usage and history.

## Not in scope

Signing/notarisation, Apple Developer Program, trademark, website, Homebrew releases, the cleanup round, ROADMAP.md, `integrations/` and the rest of the CLI's behaviour (split tab).

## Open decisions for Ricardo

1. ElevenLabs Scribe: proposed app is Parakeet-only for now; if config selects ElevenLabs the app says so in the menu and records locally only after Ricardo switches back (no silent switch). Port with a Keychain key later.
2. Logs: one shared `khuluma.log` replacing `app.log` (proposed; both reviewers agree).
3. Daemons: separate for app and CLI at first (proposed; both reviewers agree).
