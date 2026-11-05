# App independence: Khuluma.app without the CLI

Status: revised 2026-11-05 after Ricardo's decision to sunset the CLI (LOG Decisions, ee14c0f). Khuluma is the app only. Tab "Khuluma app without the CLI", branch `wip/app-independence`. The earlier two-product version (shared data contract 1, writer tags, dual-writer locks) is in Git history at 671670f and b5d29fc; it is dropped.

## Goal

The app dictates, saves history, tracks usage and shows Stats on a Mac with no `khuluma` CLI, keeps its data in its own folder, and brings over the CLI features Ricardo keeps (file transcription as a small command inside the app, ElevenLabs Scribe, and whatever else the sunset tab's keep list names). His existing history, usage, settings and vocabulary come across once. Then the sunset tab retires the CLI, formula and tap.

## Where the app depends on the CLI today

`native/Sources/Khuluma/CLIBridge.swift` runs `khuluma` for:

| Call | Used for | Replacement |
|---|---|---|
| `version --json`, `app-config --json` | locate CLI, contract check, all settings | app settings file (slice C) |
| `app-settings set` | Settings writes | same (slice C) |
| `vocab-sheet show/validate/save` | Vocabulary editor | native, app folder (slice C) |
| `history export` | recent dictations (editor examples) | native history reader (slice C) |
| `inline record` | history, bench, usage after each take | native writers (slice A) |
| `usage --json --days all` | Stats and menu figures | native usage reader (slice C) |
| `warmup --json` | starts/builds khulumad from source, loads the model | bundled daemon the app runs (slice D) |
| `inline process` | fallback route and ElevenLabs Scribe | drop the route; native Scribe (slice E) |

Sounds come from `~/.local/share/sounds/khuluma`, installed by the CLI; the model is in FluidAudio's shared cache.

## App data

Everything under `~/Library/Application Support/Khuluma` (`KHULUMA_SUPPORT_DIR` in isolated runs), next to the existing `pending/` and `recovered/`:

- `history/<local-ts>[_N].json`: today's per-take shape plus `take_id`; retention pruning to the Trash as today; the keep_logs debug archive under `history/inline-debug/` with the 48-hour WAV expiry.
- `usage.json`: today's schema-1 shape (totals, daily buckets, `recent_take_ids`), so Stats code and the import stay simple.
- `settings.json`: the app's settings (hotkey, sounds, delivery, cleanup, transcription, model path, history retention), versioned, written atomically. Replaces `config.toml`; readable and editable by agents.
- `vocabulary.json` with `vocabulary-backups/`: today's format, revision and backups.
- `import.json`: the one-time import receipt.
- `bench.tsv` is dropped: `app.log` already has per-take timings.

The app is the only writer: writes run on one queue, under one `flock` on `.data.lock` so a second copy of the app can't interleave, with temp + fsync + rename and idempotency by take id. Logs stay in `~/Library/Logs/Khuluma/app.log`.

## One-time import

On first launch of the new build, if `import.json` is missing and `~/.config/khuluma` (or `KHULUMA_CONFIG_DIR`/XDG) exists:

- copy `history/*.json` (and the debug archive), `usage.json`, `vocabulary.json` and its backups into the app folder;
- convert `config.toml` (and `.config.toml.last-good` if the main file is invalid) to `settings.json` with a small reader for the keys the app uses; anything not carried over is listed in the receipt and the log, nothing is guessed;
- treat take ids in the legacy `.cache/recorded-takes*` ledgers as already saved, so a build-415 pending take replayed after the import isn't saved twice;
- write `import.json` (source paths, counts, totals before and after, what was skipped) last.

The source is never changed or deleted. Usage totals and history counts after the import must equal the source. A Settings button can redo the import into an empty app folder; it never merges over newer app data.

## Slices

Each slice: a worker builds it, a Codex reviewer reviews it, fixes go back to the same worker, I commit and push `wip/app-independence`.

A. **Native writers and a durable spool** (in progress): history and usage writers in the app folder, `TakePersister` off `inline record`. Pending records keep per-destination done flags, are fsynced, never expire while unresolved, and unreadable ones are quarantined instead of deleted (today they're deleted, and anything older than 7 days is dropped).
B. **Import** as above, with fixtures shaped like his real files (names and shapes only, no transcript text in Git).
C. **Native settings, vocabulary and Stats**: `settings.json` replaces `app-config`/`app-settings`, vocabulary show/validate/save natively, Stats and menu figures from the app's `usage.json`, recent dictations from its history. Remove the CLI-era gates that would strand a take without the CLI: ffmpeg/ffprobe required, non-C locales refused, numeric overrides forcing the CLI route.
D. **Bundled daemon, model, sounds, permissions**: `khulumad` in `Khuluma.app/Contents/Helpers`, run and supervised by the app on its own socket in the app folder (stopped on quit, restarted after a crash); first-run model download through FluidAudio with progress in the menu, reusing the shared cache when it's there; sounds bundled in Resources; microphone and PostEvent permission prompts. Denied or revoked PostEvent fails the delivery (take kept, nothing counted), instead of only logging it as today.
E. **ElevenLabs Scribe** in the app: native upload, key from the Keychain first, then the read-only zshrc lookup the CLI uses today, so his current setup keeps working. Never in logs, arguments or settings.
F. **`khuluma transcribe` and the Finder Quick Action** inside the app (keep list below): a small helper executable in the bundle, decoding audio with AVFoundation (m4a, mp3, wav, aac, flac, mp4, mov) and using the app's daemon, or loading the model itself when the app isn't running. The app does not touch `~/.local/bin/khuluma` while the CLI is installed (today's app still calls it); the sunset tab swaps the link at its phase 4. The app provides the "Transcribe with Khuluma" Quick Action calling the helper; the sunset tab removes the CLI's workflow from `~/Library/Services` once the app's exists.
G. **Cut the cord**: delete `CLIBridge`, the CLI route and the app-contract checks. A take that can't be processed goes to recovered and retries; it is never lost. Tell the sunset tab (t4k) the app no longer needs the CLI.
H. **Acceptance, install, merge** (below).

## Keep list (sunset tab t4k, confirmed by Ricardo 2026-11-05; inventory in docs/plans/CLI_SUNSET.md)

1. `khuluma transcribe <file>...`: `-q`; `--format json` (one object per line: `file`, `text`, `audio_duration_ms`, `processing_ms`, `model`, `engine`); `-o <file>`; several files; `--beside` (`<name>.txt` next to each file); `--force` (otherwise never overwrite, and no partial output on failure). Errors as `khuluma: ...` on stderr with a non-zero exit. Raw transcript, no cleanup, not counted in usage or history. Dropped: `-c`, `--out-dir`, stdin `-`, `--no-tail-rescue`.
2. ElevenLabs Scribe (slice E).
3. Finder Quick Action "Transcribe with Khuluma": `<name>.txt` beside each file, text copied, a notification.
4. Settings imported from `config.toml`, no UI needed now: `inline.send_mode` (his: enter), `inline.paste_target` (his: current), per-event sound toggles and paths including the process sound, `history.retention_days`, `history.audio_retention_days`, `history.typing_wpm`, British spelling on by default.
5. No `vocabulary.json`: read the legacy `vocab` text file once at import.

Dropped with the CLI: the history/last/usage/doctor/status/bench/config/changelog readers (a History window stays a phase 2 item), legacy text-vocab commands, migrate-modes and the env tunables.

## Acceptance

- **Isolated, this Mac**: worktree build with the isolation overrides, a private fixture root and no CLI reachable (`KHULUMA_CLI` and the default CLI paths unreachable; no ffmpeg or Python on its path). Import from a copy of his real `~/.config/khuluma` into the fixture: counts and totals match. Then real takes into TextEdit; cancel, quit mid-take, daemon kill and restart, sleep/wake, recovery retry; each take saved once; Stats shows it; relaunch keeps it. `khuluma transcribe` on a voice memo.
- **Clean account** (decisive gate): Ricardo creates a standard macOS user once (about 15 minutes). No CLI, Homebrew tools, Python or developer tools there. Copy the build to `/Users/Shared` and open it: permission prompts (and denial: take kept, nothing counted), model download, one take into TextEdit, Stats shows 1, history entry saved, `khuluma transcribe` works through the bundled helper and the Quick Action.
- **Daily**: install over build 415 with his OK; the rollback is the previous app plus the untouched `~/.config/khuluma`. Then merge to main. The 14-day watch (no `khuluma` process started by the app, usage matching delivered takes in history) runs after the merge.

## Not in scope

Retiring the CLI, formula and tap (sunset tab), signing/notarisation, Apple Developer Program, trademark, website, the cleanup round.

## Decisions (Ricardo, 2026-11-05)

1. The CLI is sunset; Khuluma is the app only. One-time import into the app's own storage.
2. ElevenLabs Scribe and file transcription move into the app.
3. The app runs its own bundled daemon.

## Approved by Ricardo (2026-11-05)

4. Settings live in `settings.json` in the app folder (not `config.toml`, not UserDefaults): plain JSON that agents can read and edit.
5. `bench.tsv` is dropped; `app.log` keeps per-take timings.
6. The import copies, never moves: `~/.config/khuluma` stays as the rollback until he decides to clear it.
