# App independence: Khuluma.app without the CLI

Status: draft plan, 2026-11-05 (tab "Khuluma app without the CLI", branch `wip/app-independence`). Replaces LOG Next items "Phase 1 step 1", "Phase 1 after the native writers" and "Phase 1 delivery".

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

**Roots.** Unchanged so existing data keeps working: config, vocabulary, history, bench and usage under `~/.config/khuluma` (`KHULUMA_CONFIG_DIR`); logs under `~/Library/Logs/Khuluma`. Moving data to Application Support stays Phase 3.

**Writer tag.** Every record carries `writer`: `{"name": "app"|"cli", "version": "<semver>", "build": "<n or null>"}`, compact form `app/0.12.0+416`, `cli/0.12.0`.

| File | Format today | Lock today | Change |
|---|---|---|---|
| `history/<local-ts>[_N].json` | one JSON object per take | exclusive create (noclobber) | add `take_id`, `writer`; new writers publish atomically (write temp, `link()` to the claimed name, so readers never see a half file) |
| `history/bench.tsv` | 19 tab columns | `bench.tsv.lock.d` mkdir lock, stale after 60 s, 800-row trim under lock | append column 20 `writer` (compact form); readers treat a missing column as unknown |
| `usage.json` | `schema_version: 1` aggregate + `daily.days` + `recent_take_ids` | `flock(usage.json.lock)`, 2 s bounded wait, temp + fsync + rename | stays schema 1 (the installed CLI refuses anything else); add top-level `by_writer` counts and `last_write {writer, at, take_id}`; day buckets stay closed (the installed CLI rewrites them with known keys only) |
| `vocabulary.json` | schema 1 | `flock(.vocabulary.lock)`, revision token, backups | unchanged; app writes natively under the same lock |
| `config.toml` (+ last-good copy) | TOML | atomic replace, symlink kept; `flock` on the last-good lock | unchanged; app writes natively with the same atomic rules |
| `.cache/recorded-takes{,-history,-bench}` | take-id ledgers for `inline record` replays | none (append) | the native writer reads and appends them while takes spooled by older builds may still replay; retire after one release |
| `~/Library/Logs/Khuluma/khuluma.log` | new | `O_APPEND` single writes, one line each | shared human log: `[ISO time] [app/0.12.0+416] message`; CLI writes it too. `app.log` stops growing (kept, not deleted) |

**One recording at a time.** The CLI is getting its own dictation back (split tab). Before opening the mic, either side takes a non-blocking `flock` on `~/.config/khuluma/recording.lock` and writes into it one JSON line `{writer, pid, started_at, take_id}`. The lock is held for the whole capture and released on stop or process death (flock dies with its holder, so no stale lock). The CLI, whose `start` exits while ffmpeg records, passes the locked fd to the ffmpeg child so the lock lives exactly as long as the capture; the app opens it `O_CLOEXEC` so its own children never inherit it. If the lock is held, the other side refuses to start and says who holds it ("Khuluma app is recording" / "khuluma CLI is recording").

**Contract version.** `~/.config/khuluma/data-contract.json`: `{"data_contract": 1, "set_by": <writer>}`. Each side knows the highest contract it supports. Before any shared write, a side whose supported contract is lower than the file's refuses that write and logs/says which product to update. Within contract 1 nothing raises it; only a future incompatible change raises it, through an explicit migration in the newer product. Missing file = contract 1. `khuluma version --json` and the app's log line at launch report `data_contract`.

**Rules.** Writers preserve unknown keys. Additive fields only within contract 1. Usage dedup stays by take id across both writers. Transcript text appears only in history and pending recovery, never in usage, bench or logs (existing rule).

**Daemon.** No sharing at first: the app runs its bundled `khulumad` as a child on its own socket in Application Support; the CLI keeps its own. Sharing one warm daemon is a later optimisation once the daemon protocol carries a version.

## Slices

Each slice: a worker builds it, a Codex reviewer reviews it, fixes go back to the same worker, I commit and push `wip/app-independence`.

0. **Contract doc** (docs only) → rebase, land on main, tell the split tab.
1. **CLI writer tag**: `save_history`, `append_bench_entry`, `usage_record_delivery` and a `khuluma_log` helper in `bin/khuluma-lib` write the tag and the shared log; `version --json` reports `data_contract`. Shell tests, plus old-reader checks (current history/bench/usage readers still parse).
2. **Native writers** in `KhulumaCore`: `HistoryWriter`, `BenchWriter`, `UsageLedger`, `SharedLog`, same locks. Shared fixtures in `tests/fixtures/shared-data/` drive both the Swift and shell writers; a cross-writer stress test (Swift and CLI writing `usage.json`/`bench.tsv` concurrently, N takes each, exact totals, no duplicate ids). `TakePersister` switches from `inline record` to the native writers, honouring the old ledgers and build-415 pending spool.
3. **Native readers**: Stats/menu figures from `usage.json`, recent dictations from `history/`. Parity with `khuluma usage --json --days all` on fixtures.
4. **Native config and vocabulary**: TOML subset reader matching `app-config` resolution (env overrides, last-good fallback, defaults), Settings writer with the CLI's atomic rules, vocabulary show/validate/save under `.vocabulary.lock`. Parity fixtures against `app-config --json`.
5. **Bundled daemon, model, sounds**: `khulumad` in `Khuluma.app/Contents/Helpers`, started and supervised by the app; first-run model download through FluidAudio with progress in the menu; sounds bundled in Resources, `~/.local/share/sounds/khuluma` still overrides when present.
6. **Cloud provider**: port ElevenLabs Scribe to URLSession with the key in the Keychain, or drop Scribe from the app for now (decision for Ricardo).
7. **Cut the cord**: delete `CLIBridge`, the CLI route and `app_contract` checks; a take that can't be processed natively goes to recovered and retries (never lost). Permission gates: microphone and PostEvent (`CGPreflightPostEventAccess`/`CGRequestPostEventAccess`) with plain prompts in the menu.
8. **Acceptance** (below), then install on the daily Mac with Ricardo's OK and a rollback, then merge to main.

## Acceptance

- **No-CLI run on this Mac**: worktree build launched with the isolation overrides plus `KHULUMA_CONFIG_DIR` and `HOME`-relative paths pointed at a private fixture root and `PATH` without `khuluma`. Checks: launches, downloads or finds the model, a real take delivers into TextEdit, history file + bench row + usage count written with `writer: app`, Stats shows it, quit/relaunch keeps it, and the binary contains no CLI invocation.
- **Both installed, same fixture root**: CLI `history list`, `usage --json` and `bench` show the app's take; a CLI-written record shows in the app's Stats; a concurrent stress run leaves exact totals.
- **Clean account**: Ricardo creates a standard macOS user once (about 15 minutes of his time). Copy the build to `/Users/Shared`, open it there: permission prompts, model download, one take into TextEdit, Stats shows 1, history entry tagged `app`. Then install the CLI in that account and confirm it reads the same take.
- **Daily**: installed build used for 14 days with no `khuluma` process started by the app (shared log shows only `cli/` lines for things Ricardo ran) and no usage mismatch between `usage.json` and history counts for the retained window.

## Not in scope

Signing/notarisation, Apple Developer Program, trademark, website, Homebrew releases, the cleanup round, ROADMAP.md, `integrations/` and the rest of the CLI's behaviour (split tab).

## Open decisions for Ricardo

1. ElevenLabs Scribe in the app: port now with a Keychain key, or app is Parakeet-only until later.
2. One shared `khuluma.log` replacing `app.log` (proposed), or keep `app.log` and add `cli.log` beside it.
3. Separate daemons for app and CLI at first (proposed), accepting double model memory only while both are warm.
