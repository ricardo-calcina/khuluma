# CLI Contracts

Khuluma is CLI-first for operator work. Text output should stay useful for humans, but the `--json` surfaces below are the preferred contract for scripts, agents, Khuluma, and later UI layers.

## Stable Read Contracts

These commands are safe to build integrations on:

- `khuluma version --json`
  - Object with `schema_version`, `cli_version`, `config_schema_version`, and
    the separately resolved `running_binary.path`.
  - `receipt` contains non-executed install provenance: `present`, `readable`,
    `installed_at`, `source`, `ref`, and `commit`. Missing provenance is
    represented by `present: false` and null field values; it does not make the
    command fail.
  - Receipt provenance records how an installation was created. It is not
    evidence that a receipt's source checkout is the running binary.
- `khuluma status --json`
  - Object with `command`, `summary`, `runtime`, `effective_settings`, `diagnostics`, and `more_detail`.
  - `summary.next_action` is the primary human next step.
  - `more_detail` is an ordered command list for deeper inspection.
  - `effective_settings.integrations` (the SwiftBar toggle) was removed in v0.11, along with the tmux and CLI-capture keys: `runtime.tmux`, `runtime.inline`, `runtime.tmux_queue`, `effective_settings.tmux`, `effective_settings.audio`, `effective_settings.mode.tmux`, `postprocess.tmux` and `mode_prompt.tmux`. With LLM post-processing and silence trim (also v0.11), `effective_settings` lost `postprocess`, `llm`, `budget`, `silence_trim` and `cerebras_api_key`, and `clean.vocab_only_when_postprocess_off` became `clean.vocab`. With modes (also v0.11), `effective_settings.mode` was removed. `summary.active_flow` is `inline` while a take is processing, otherwise null.
- `khuluma doctor --json`
  - Object with install, config, vocab, and runtime health sections plus suggested fixes.
  - `vocab` (0.11+): `path`, `present`, `rules` (the number of correction rules) and `legacy_modes_present` (an old `modes/` or `current-mode` is still in the config dir; `khuluma migrate-modes` folds it in).
  - `install_sanity.swiftbar` was removed in v0.11 when the SwiftBar plugin was retired, and `install_sanity.raycast_inline` with the Raycast scripts. `integrations` and `swiftbar` are no longer commands.
  - Also removed in v0.11: `dependencies.tmux`, `mode_config.tmux`, `mode_config.available.tmux_count`, `modes[].flows.tmux_enabled`, `state_files`, `tmux_queue` and `mode_config.modes[].prompt` (mode prompt files are no longer read). `mode_config` itself went with modes, replaced by `vocab`.
- `khuluma history list [N] --json`
  - Newest-first array of compact history entries.
- `khuluma history search <query> [N] --json`
  - Newest-first array of matching entries with `match_fields`.
- `khuluma history export [N|all] --json`
  - Newest-first array of full history entries.
  - v0.11 dropped `postprocess_budget` from the history readers and from `history stats`, and `metrics.postprocess_ms` from the metric summaries. Old history files keep the fields on disk; they are no longer read. Modes went the same way: `mode` is gone from the history readers and `breakdowns.modes` from `history stats`.
- `khuluma history sessions [N] --json`
  - Object with `sessions` and `next_commands`.
  - Each session includes app, words, timing metrics, audio artifact metadata, debug notes, and a preview.
- `khuluma last --json`
  - Object with the latest history entry.
- `khuluma usage --json`
  - Object with `coverage`, `delivered_dictations`, word and duration totals,
    the current typing-WPM assumption, and `estimated_time_difference_ms`.
  - The summary is a transcript-free local aggregate stored outside retained
    history. It starts with the first successful delivery after this feature is
    installed; it does not backfill or recover pruned history.
  - `full_elapsed_duration_ms` measures recording start through successful
    delivery. `estimated_time_difference_ms` is
    `typing_equivalent_duration_ms - full_elapsed_duration_ms`, so its sign is
    explicit rather than an unqualified time-saved claim.
  - The WPM assumption is evaluated when the command is read. Changing
    `KHULUMA_HISTORY_TYPING_WPM` recalculates the estimate, not the stored
    delivery, word, or duration totals.
  - Only successful delivered dictations are counted. Failed, cancelled,
    no-speech and replay runs are excluded. `by_flow` can still show `tmux`
    for deliveries recorded before v0.11.
  - `coverage.daily_tracking_started_at` (string or null, 0.11+): when per-day
    counting began.
- `khuluma usage --json --days N|all`
  - The same object plus `daily`: `status` (`active`, `not_started`,
    `unreadable`), `started_at`, `as_of_local_date`, `range` (`from`/`to`, the
    last N local calendar dates including today; N is 1–3660), and
    `untracked_deliveries` (deliveries recorded without a day, e.g. by an older
    CLI, counted over all stored days).
  - `days` lists only active days, ascending: `date` (YYYY-MM-DD, the local
    date at delivery), `count`, `by_flow`, `words`, `recording_ms`,
    `full_elapsed_ms`, `longest_recording_ms`, `most_words`. Only these
    validated numbers are emitted.
- `khuluma app-config --json` (app integration)
  - Khuluma's settings: hotkey, global `sounds_enabled`, event sounds, inline delivery, cleanup,
    transcription, `pipeline.supervise`, `config` (source and error) and
    `usage.summary_path`. `app_contract` is an integer that changes whenever
    Khuluma and the CLI must change together; Khuluma takes no dictation from a
    CLI whose contract differs from the one it was built with. Contract 2
    (v0.11) removed `cleanup.postprocess`, `transcription.chunking` and
    `transcription.silence_trim`. Contract 3 (v0.11) removed modes:
    `cleanup.force_mode`, `cleanup.code_paragraph_min_words` and
    `cleanup.long_paragraph_min_words` from here, and `mode` from
    `inline process --json` and `inline cleanup --json` (which no longer takes
    `--app`).
    Contract 4 adds app settings writes and explicit provider selection. It
    prevents an older app from ignoring the selected cloud provider and
    continuing to invoke the local daemon.
    Contract 5 keeps the native and CLI hesitation, sentence-repetition,
    portable vocabulary and punctuation rules in step. Install the app and CLI together;
    an older app would otherwise apply different cleanup to the same take.
  - `cleanup.clean` resolves `KHULUMA_CLEAN` first, then `[clean] enabled`
    (false by default). `cleanup.repeats_level` keeps its string shape; level
    3 removes only exact adjacent sentences of five or more words, preserving
    grammatical doubles and short emphasis. Levels 0–2 retain their meaning.
  - `sounds_enabled` is the master sound switch. It is independent of each
    event's effective `sounds.<event>.enabled` value.
  - `transcription.provider` is `parakeet` (the default, local) or
    `elevenlabs` (an explicit cloud selection using Scribe v2).
    `transcription.language` is `KHULUMA_LANGUAGE`, else `[transcription]
    language`, else `en`; `auto` lets Scribe detect the language.
    `transcription.key_available` reports credential presence without exposing
    its value. Cloud selection sets `pipeline.supervise` to false because it
    does not use the local Parakeet daemon.
- `khuluma app-settings set <key> <value> --json` (app integration)
  - Saves one allowlisted setting, then returns the full, freshly resolved
    `app-config` object. Environment overrides still take precedence, so the
    returned effective value can differ from the saved value.
  - Editable strings: `app.hotkey`, `transcription.provider`,
    `transcription.language` (`auto` or a lowercase ISO 639 code such as `en`),
    `swift_parakeet.model_path` (an existing directory, or empty to use model
    discovery), and `swift_parakeet.model_version` (`v2`, `v3`, or empty for
    inference). Hotkeys accept a modifier and key, or F1–F20.
  - Editable switches: `debug.keep_logs`, `inline.autosend`,
    `audio.sounds.enabled` and `clean.enabled`; values must be `true`,
    `false`, `1`, or `0`. `clean.repeats_level` accepts integers 0–3.
  - Unknown keys, invalid values, and malformed TOML fail without replacing
    the config. Successful writes preserve config symlinks and unrelated
    settings through the existing atomic TOML writer.
- `khuluma vocab-sheet show --json` (app/agent integration)
  - Returns `{ "document": <vocabulary>, "revision": "<sha256>" }` without
    writing config or vocabulary. The document has `schema_version: 1`,
    `fillers` (literal strings), `brands` and `words` (arrays of
    `{ "heard": "...", "write": "..." }`). No unknown fields, duplicate
    heard phrases, control characters, empty strings or unsupported versions
    are accepted. The limits are 1 MB, 5,000 total entries and 200 Unicode
    scalars per phrase. Case-insensitive heard phrases must be unique across
    all sections.
  - Optional `examples`: up to 200 `{ "said": "...", "expect": "..." }`
    checks (each at most 2,000 characters on one line; `said` non-empty).
    Cleanup never reads them; the app's editor reruns them against a draft
    before saving. The field is omitted when there are none, so older readers
    of an example-free file are unaffected.
  - Reads `vocabulary.json` when present. Otherwise it exposes the retained
    text `vocab` as Other words alongside the initial hesitation list, without
    converting or replacing any files. Conflicting/invalid text rules must be
    corrected explicitly before first save.
- `khuluma vocab-sheet validate --json` (app/agent integration)
  - Reads an exported document on stdin, validates the entire file and returns
    the normalized document. Does not write files. Duplicate JSON keys are
    rejected, including keys that would otherwise silently replace earlier data.
- `khuluma vocab-sheet save --json` (app/agent integration)
  - Reads the `document`/`revision` envelope on stdin. Under the vocabulary
    lock, checks the revision from `show`, validates the document and atomically
    publishes `vocabulary.json`, returning a fresh envelope. Stale revisions,
    invalid documents and symlink destinations fail without replacing the file.
    A first save leaves the old text `vocab` intact and inactive. Subsequent
    changes back up the exact previous JSON bytes under `vocabulary-backups/`.
    New files and backups use mode 0600. Re-saving an identical document is a
    no-op. Revision tokens are opaque; do not derive them from exported JSON.
  - Export/import files contain only the document, not the envelope. The app
    stages imported content for review, then supplies the current revision
    when Save Changes is chosen. On conflict it retains the draft for export
    and reload, with no force-overwrite fallback.
- `khuluma inline process <wav> --json [--defer-usage] [--expected-provider parakeet|elevenlabs]` (app integration)
  - `--expected-provider` rejects a changed provider before transcription with
    exit status 2. The app passes the provider captured for the take, so a
    queued local take cannot silently switch to a cloud upload after a
    settings change. An invalid or missing flag value also exits 2.
  - `--defer-usage` leaves the take out of the
    usage ledger (`usage_deferred: true`); the caller records it after
    delivering with `inline record` and `usage_only: true`. Take ids are
    deduplicated in the ledger, so a replayed record never counts twice.
  - `history_saved` (0.11+) is true only once the take's history entry is on
    disk: the history write finishes before the JSON is printed. A take whose
    history write failed still returns its text (`ok: true`). Khuluma treats a
    missing field as false.
- `khuluma config --json`
- `khuluma config path --json`
- `khuluma config get <path> --json`
  - Read-only config inspection contracts. `effective.postprocess` was removed in v0.11; an old `[postprocess]` table is ignored.
- `khuluma bench [N|all] --json [filters]`
  - Object with record counts, filters, stage summaries, startup summaries, latest row, and `next_commands`. The `--slow-startup-audio-ms`, `--slow-startup-ffmpeg-ms` and `--slow-startup-target-ms` filters were removed in v0.11 with CLI capture, and so were `postprocess_enabled` and `postprocess_ms` (the TSV keeps their columns, written as 0). With modes went the `--mode` filter and the `mode` field (the TSV column is written as `none`).
- `khuluma bench export [N|all] --json [filters]`
  - Newest-first array of raw bench rows.

## Experimental Output

These are useful but not yet promised as stable contracts:

- `khuluma transcribe <file>... --format json`
  - One JSON object per input, newline-delimited: `file`, `text`, `audio_duration_ms`, `processing_ms`, `model`, `engine`. `text` is the raw provider transcript with no dictation cleanup. `audio_duration_ms` is `null` when the duration cannot be probed. Stdin input reports `file: "stdin"`. Exit status is non-zero if any input fails; successful inputs are still emitted.
  - The explicit `transcription.provider` setting selects the same provider
    for files and inline processing. ElevenLabs records use
    `model: "scribe_v2"` and `engine: "elevenlabs"`.
  - File transcripts are not deliveries: they never appear in `history` or `usage`.
- `khuluma finder install|remove|status`
  - Human-readable management of the Finder Quick Action (`~/Library/Services/Transcribe with Khuluma.workflow`).

`logs`, `devices` and `watch` were removed in v0.11 with the tmux flow and CLI capture, `bench-matrix` with LLM post-processing, and `mode` with modes (it now exits 2 and points to `migrate-modes`).

## Contract Rules

- Additive JSON fields are allowed.
- Existing field names and broad value types should not change without a changelog note.
- Text output may be refined more freely, but it should keep command cross-links visible where useful.
- Prefer `next_commands` or `more_detail` when a caller needs a recommended follow-up path.

ElevenLabs credentials resolve from `ELEVENLABS_API_KEY` (or the existing
`ELEVEN_LABS_API_KEY` alias), then a literal exported assignment in the
configured zshrc locations. The canonical name wins when both are present
in the environment or the same rc/private pair.
An explicitly sourced `.zshrc.private` sibling is also supported through
`zsh_private_env="${ZDOTDIR:-$HOME}/.zshrc.private"` and
`source "$zsh_private_env"` (including literal HOME/ZDOTDIR equivalents).
Lookup follows only that conventional sibling, one level deep. The
credential reader parses text and never executes either file. API keys are not
included in settings JSON, command arguments, diagnostics, or logs. Failed
cloud requests do not return remote response bodies as transcript text.


## Shared data contract 1

Status: contract 1, implementation in progress on `wip/app-independence`. Plan: `docs/plans/APP_INDEPENDENCE.md`.

The native app and the CLI each work alone and share the files below when both are installed. Both sides implement this section; anything not listed is private to one product.

### On-disk formats and locks

What the app reads and writes, kept compatible with the installed v0.11 CLI during a changeover.

#### Roots and overrides

| File | Default path | Moved by |
|---|---|---|
| config | `~/.config/khuluma/config.toml` | `KHULUMA_CONFIG_FILE`; otherwise the config dir |
| config dir (`<cfg>`) | `~/.config/khuluma` | `KHULUMA_CONFIG_DIR`, else `$XDG_CONFIG_HOME/khuluma` |
| vocabulary | `<cfg>/vocabulary.json` | config dir |
| history | `<cfg>/history/*.json` | config dir |
| bench | `<cfg>/history/bench.tsv` | config dir |
| usage | `<cfg>/usage.json` | `KHULUMA_USAGE_SUMMARY_FILE` |
| shared log | `~/Library/Logs/Khuluma/khuluma.log` | `KHULUMA_LOG_DIR` |

Both sides resolve every override the same way. `KHULUMA_LOG_DIR` is today an app-only isolation variable (set together with `KHULUMA_SUPPORT_DIR` and `KHULUMA_DEFAULTS_SUITE`); contract-1 CLIs honour it for `khuluma.log` too. Locks and temp files live beside the file they guard (`usage.json.lock` beside a moved usage file). Moving data to Application Support is not part of contract 1.

#### Writer tag

Every record written under contract 1 carries a writer:

```json
"writer": {"name": "app", "version": "0.12.0", "build": "416"}
"writer": {"name": "cli", "version": "0.12.0", "build": null}
```

Compact form (bench, log): `app/0.12.0+416`, `cli/0.12.0`. `name` is `app` or `cli`. A record without a tag (written before contract 1, or by the v0.11 CLI) reads as `unknown`. Records the CLI writes on the app's behalf (`inline record` or `inline process`, called by older apps) are tagged `app`, with the app's version when it passes one, else `version: null`.

#### Take identity and idempotency

Every take has a `take_id` (`[A-Za-z0-9._-]{1,128}`, as `usage.json` accepts today). Each destination records it, and a write is idempotent per destination: under that destination's lock the writer checks whether the take id is already there and, if so, does nothing and reports success. This replaces the separate replay ledgers. The `.cache/recorded-takes`, `recorded-takes-history` and `recorded-takes-bench` ledgers are still read for takes written before contract 1 and are not written by contract-1 writers; they are retired once no pending record predates contract 1.

#### Per file

**History** (`history/<local-ts>[_N].json`, local time `YYYY-MM-DDTHH-MM-SS`)

```json
{
  "timestamp": "2026-11-05T09:14:02Z",
  "app": "TextEdit",
  "raw": "…",
  "processed": "…",
  "take_id": "a1b2c3",
  "writer": {"name": "app", "version": "0.12.0", "build": "416"},
  "metrics": {"record_ms": 4100, "transcribe_ms": 210, "clean_ms": 3, "paste_ms": 40, "total_ms": 4400},
  "audio": {}
}
```

- Lock: `flock(history/.history.lock)`, exclusive, held across the take-id check, the name claim and the publish.
- Take-id check: scan entries newer than the retention window for `take_id`; found = done.
- Claim and publish in one step: write the full document to a temp file in `history/` and fsync it, then `link()` it to `<ts>.json` (fails if the name exists, so it is an exclusive create); on collision try `_2` … `_50`, then fail. Unlink the temp and fsync the directory. Readers never see an empty or partial entry.
- Readers ignore files that don't parse and unknown keys. `metrics` and `audio` keep today's keys.

**Bench** (`history/bench.tsv`, tab-separated, no header, one row per take). Columns:

1 `ts` (UTC, `%Y-%m-%dT%H:%M:%SZ`) · 2 `flow` · 3 `status` · 4 `model` · 5 `mode` (always `none`) · 6 `postprocess` · 7 `raw_chars` · 8 `out_chars` · 9 `record_ms` · 10 `transcribe_ms` · 11 `clean_ms` · 12 `postprocess_ms` · 13 `paste_ms` · 14 `total_ms` · 15 `startup_total_ms` · 16 `startup_audio_ms` · 17 `startup_ffmpeg_live_ms` · 18 `startup_target_ms` · 19 `startup_audio_source` · 20 `writer` (compact) · 21 `take_id`

```
2026-11-05T09:14:06Z	inline	ok	parakeet-v3	none	0	52	51	4100	210	3	0	40	4400	0	0	0	0		app/0.12.0+416	a1b2c3
```

- Lock: `mkdir history/bench.tsv.lock.d`, retried for up to 3 s; a lock directory older than 60 s is stale and removed once.
- Contract-1 writers never append without the lock: no lock in 3 s = skip the row and log it to `khuluma.log` (bench is diagnostics).
- Under the lock: take-id check (column 21), append, then trim to the newest `KHULUMA_BENCH_MAX_ROWS` (default 800) rows via temp file and rename.
- Fields contain no tabs or newlines. Readers treat missing columns 20-21 as `unknown` and empty, and ignore extra columns.

**Usage** (`usage.json`)

```json
{
  "schema_version": 1,
  "tracking_started_at": "2026-10-01T08:00:00Z",
  "delivered_dictations": {"count": 120, "by_flow": {"inline": 120, "tmux": 0}},
  "processed_words": 5400,
  "recording_duration_ms": 900000,
  "full_elapsed_duration_ms": 960000,
  "daily": {"started_at": "…", "baseline_count": 0, "days": {"2026-11-05": {"count": 3, "inline": 3, "tmux": 0, "words": 140, "recording_ms": 12000, "full_elapsed_ms": 13000, "longest_recording_ms": 6000, "most_words": 70}}},
  "recent_take_ids": {"a1b2c3": "2026-11-05"},
  "by_writer": {"app": 40, "cli": 2},
  "attribution_started_at": "2026-11-06T10:00:00Z"
}
```

- `schema_version` stays 1: the v0.11 CLI refuses to write any other value, which would stop it counting during the transition.
- New, additive: `by_writer` counts tagged deliveries only; `attribution_started_at` is when the first contract-1 writer added it. Unattributed = `count` minus the sum of `by_writer`.
- Day buckets stay closed: exactly the eight keys above (v0.11 rewrites them with known keys only, so a new key would be dropped). No `last_write` field (v0.11 would leave it stale).
- Idempotency: `recent_take_ids` (take id → local date, pruned by age and count as today); a take id already present = no change.
- Lock: `flock(usage.json.lock)`, non-blocking retries for at most 2 s; timeout = skip and log, the take stays pending.
- Write: temp file in the same directory, fsync, rename over `usage.json`, fsync the directory.
- An unreadable file, or a `schema_version` other than 1, is never overwritten: the write fails and is logged.

**Config** (`config.toml`)

- Lock: `flock(config.toml.lock)`, exclusive, around every read-modify-replace, on both sides. Plain reads take no lock.
- Format unchanged; readers parse full TOML (the CLI uses `tomllib`), not a subset. Unknown keys and tables are preserved on write.
- Invalid file: readers fall back to `.config.toml.last-good`; no writer rewrites an invalid file.
- A symlinked `config.toml` stays a symlink: replace the target, not the link.

**Vocabulary** (`vocabulary.json`): unchanged. `flock(.vocabulary.lock)`, revision check and backups as today. Closed schema: no `writer` field inside.

**Shared log** (`~/Library/Logs/Khuluma/khuluma.log`)

```
[2026-11-05T09:14:06.512Z] [app/0.12.0+416] take a1b2c3 delivered in 4400 ms
```

- UTC ISO 8601 with milliseconds, then the compact writer, then the message.
- Open `O_APPEND`; one `write()` per line, newline included.
- No transcript text, API keys or remote response bodies.
- `app.log` is kept and no longer written; `tools/khuluma-report.sh` reads both.

#### Rules

- Writers preserve unknown keys in every JSON and TOML file.
- Within contract 1, changes are additive only. Removing or retyping a field needs contract 2.
- Transcript text appears only in history and pending recovery, never in usage, bench or the log.
- The app reports `data_contract` in its launch log line.

#### Transition with the v0.11 CLI

The installed v0.11 CLI keeps writing until a contract-1 CLI ships. It writes untagged records (`unknown`) with no `take_id` in history or bench, uses the old replay ledgers, ignores `.history.lock` and `config.toml.lock`, and appends to bench without the lock after a 3 s timeout. It does honour `usage.json.lock`, `recent_take_ids`, `.vocabulary.lock` and the bench lock when free. The guarantees here hold fully only between contract-1 writers; with v0.11 they degrade to today's behaviour, not worse.

#### Daemons

Not shared in contract 1. The app runs its bundled `khulumad` as its own child on its own socket in Application Support; the CLI keeps its own daemon. Sharing one waits until the daemon protocol carries a version.

### Only while a contract-1 CLI is still developed

Dropped in one cut if the CLI is retired.

- **CLI writer obligations**: tag records `cli/<version>` (or `app` on the app's behalf, above), record `take_id`, take every lock above, never append to bench unlocked, write `khuluma.log` lines, and honour `KHULUMA_LOG_DIR`.
- **`khuluma version --json`** gains `data_contract` (0.12+, number; absent = pre-contract CLI). Add it to "Stable Read Contracts" when it ships.
- **`recording.lock`** (`<cfg>/recording.lock`): one recording at a time across app and CLI. Take `flock(LOCK_EX|LOCK_NB)` before capture, hold it for the whole capture, never unlink the file. Then truncate and write one JSON line, informational only: `{"writer": "cli/0.12.0", "pid": 4242, "started_at": "2026-11-05T09:14:02.120Z", "take_id": "a1b2c3"}`. Held = refuse and name the holder. The CLI passes the locked fd to its ffmpeg child; the app opens it `O_CLOEXEC`.
- **`data-contract.json`** (`<cfg>/data-contract.json`): `{"data_contract": 1, "set_by": {"name": "app", "version": "0.12.0", "build": "416"}}`. Missing = 1. Written atomically, only raised. A side supporting less than the file says refuses shared writes (reads stay allowed) and names the product to update. v0.11 ignores both files.

## Identity migration and diagnostic schema

The executable is `khuluma`. v0.11.0 removes the `tmux-whisper` command and legacy doctor JSON adapter; doctor schema 2 is the supported diagnostic object. Normal execution rejects obsolete `DICTATE_*` and Lowkey signing overrides before writes; use `KHULUMA_*` names. Help/version/default probes remain nonmutating. An app contract number alone is not canonical identity proof: the app also checks the nonmutating version identity probe and effective config root.

`khuluma doctor --json` has `schema_version: 2` and neutral `install_sanity` keys `cli_binary`, `daemon_source`, `daemon_binary` and `daemon_socket`. Other command JSON/wire/data formats stay unchanged. Historical receipts are parsed as data and retain their actual original source URLs/commits.

Explicit migration is never triggered by help/version/config-defaults probes. A mutable command encountering only the legacy default profile directs the operator to the tested migration tool instead of making a second profile.
