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


## Identity migration and diagnostic schema

The executable is `khuluma`. v0.11.0 removes the `tmux-whisper` command and legacy doctor JSON adapter; doctor schema 2 is the supported diagnostic object. Normal execution rejects obsolete `DICTATE_*` and Lowkey signing overrides before writes; use `KHULUMA_*` names. Help/version/default probes remain nonmutating. An app contract number alone is not canonical identity proof: the app also checks the nonmutating version identity probe and effective config root.

`khuluma doctor --json` has `schema_version: 2` and neutral `install_sanity` keys `cli_binary`, `daemon_source`, `daemon_binary` and `daemon_socket`. Other command JSON/wire/data formats stay unchanged. Historical receipts are parsed as data and retain their actual original source URLs/commits.

Explicit migration is never triggered by help/version/config-defaults probes. A mutable command encountering only the legacy default profile directs the operator to the tested migration tool instead of making a second profile.
