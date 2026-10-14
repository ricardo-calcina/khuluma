# CLI Contracts

Tmux Whisper is CLI-first for operator work. Text output should stay useful for humans, but the `--json` surfaces below are the preferred contract for scripts, agents, Lowkey, and later UI layers.

## Stable Read Contracts

These commands are safe to build integrations on:

- `tmux-whisper version --json`
  - Object with `schema_version`, `cli_version`, `config_schema_version`, and
    the separately resolved `running_binary.path`.
  - `receipt` contains non-executed install provenance: `present`, `readable`,
    `installed_at`, `source`, `ref`, and `commit`. Missing provenance is
    represented by `present: false` and null field values; it does not make the
    command fail.
  - Receipt provenance records how an installation was created. It is not
    evidence that a receipt's source checkout is the running binary.
- `tmux-whisper status --json`
  - Object with `command`, `summary`, `runtime`, `effective_settings`, `diagnostics`, and `more_detail`.
  - `summary.next_action` is the primary human next step.
  - `more_detail` is an ordered command list for deeper inspection.
  - `effective_settings.integrations` (the SwiftBar toggle) was removed in v0.11.
- `tmux-whisper doctor --json`
  - Object with install, config, mode, and runtime health sections plus suggested fixes.
  - `install_sanity.swiftbar` was removed in v0.11 when the SwiftBar plugin was retired.
- `tmux-whisper history list [N] --json`
  - Newest-first array of compact history entries.
- `tmux-whisper history search <query> [N] --json`
  - Newest-first array of matching entries with `match_fields`.
- `tmux-whisper history export [N|all] --json`
  - Newest-first array of full history entries.
- `tmux-whisper history sessions [N] --json`
  - Object with `sessions` and `next_commands`.
  - Each session includes app, mode, words, timing metrics, audio artifact metadata, debug notes, and a preview.
- `tmux-whisper last --json`
  - Object with the latest history entry.
- `tmux-whisper usage --json`
  - Object with `coverage`, `delivered_dictations`, word and duration totals,
    the current typing-WPM assumption, and `estimated_time_difference_ms`.
  - The summary is a transcript-free local aggregate stored outside retained
    history. It starts with the first successful delivery after this feature is
    installed; it does not backfill or recover pruned history.
  - `full_elapsed_duration_ms` measures recording start through successful
    delivery for both inline and tmux flows. `estimated_time_difference_ms` is
    `typing_equivalent_duration_ms - full_elapsed_duration_ms`, so its sign is
    explicit rather than an unqualified time-saved claim.
  - The WPM assumption is evaluated when the command is read. Changing
    `DICTATE_HISTORY_TYPING_WPM` recalculates the estimate, not the stored
    delivery, word, or duration totals.
  - Only successful delivered inline and tmux dictations are counted. Failed,
    cancelled, no-speech, superseded, and replay runs are excluded.
  - `coverage.daily_tracking_started_at` (string or null, 0.11+): when per-day
    counting began.
- `tmux-whisper usage --json --days N|all`
  - The same object plus `daily`: `status` (`active`, `not_started`,
    `unreadable`), `started_at`, `as_of_local_date`, `range` (`from`/`to`, the
    last N local calendar dates including today; N is 1–3660), and
    `untracked_deliveries` (deliveries recorded without a day, e.g. by an older
    CLI, counted over all stored days).
  - `days` lists only active days, ascending: `date` (YYYY-MM-DD, the local
    date at delivery), `count`, `by_flow`, `words`, `recording_ms`,
    `full_elapsed_ms`, `longest_recording_ms`, `most_words`. Only these
    validated numbers are emitted.
- `tmux-whisper inline process <wav> --json [--defer-usage]` (app integration)
  - `--defer-usage` (capability `deferred_usage`) leaves the take out of the
    usage ledger (`usage_deferred: true`); the caller records it after
    delivering with `inline record` and `usage_only: true`. Take ids are
    deduplicated in the ledger, so a replayed record never counts twice.
- `tmux-whisper logs --json`
- `tmux-whisper logs path|tail [stream] [--lines N] --json`
  - Object with `streams` and `next_commands`.
- `tmux-whisper devices --json`
  - Object with platform, device list, and permission hints.
- `tmux-whisper config --json`
- `tmux-whisper config path --json`
- `tmux-whisper config get <path> --json`
  - Read-only config inspection contracts.
- `tmux-whisper integrations --json`
  - Object with installed binary, install receipt, and Raycast script state.
  - The `swiftbar` section was removed in v0.11 when the plugin was retired.
  - Adapter entries include source path and provenance state: `current`, `missing`, `non-executable`, `different`, or source-unavailable/source-missing fallbacks.
  - Adapter entries include installed `version` and `source_version` values when shipped adapter metadata is present.
- `tmux-whisper bench [N|all] --json [filters]`
  - Object with record counts, filters, stage summaries, startup summaries, latest row, and `next_commands`.
- `tmux-whisper bench export [N|all] --json [filters]`
  - Newest-first array of raw bench rows.

## Experimental Output

These are useful but not yet promised as stable contracts:

- `tmux-whisper integrations doctor`
  - Human-readable integration lifecycle diagnostics for installed binary, receipt, Raycast scripts, executable bits, and adapter provenance/drift from the recorded source tree.
- `tmux-whisper integrations repair --dry-run`
  - Human-readable adapter-only repair preview. This intentionally does not mutate files.
- `tmux-whisper integrations repair`
  - Human-readable adapter-only repair action for Raycast scripts. It creates missing adapter directories, refreshes adapter files from the recorded source tree, ensures executable bits, and backs up replaced adapter files.
- `tmux-whisper swiftbar [...]`
  - Retired in v0.11: prints a notice and exits 0 for any arguments, so older scripts keep working.
- `tmux-whisper transcribe <file>... --format json`
  - One JSON object per input, newline-delimited: `file`, `text`, `audio_duration_ms`, `processing_ms`, `model`, `engine`. `text` is the raw Parakeet transcript with no dictation cleanup. `audio_duration_ms` is `null` when the duration cannot be probed. Stdin input reports `file: "stdin"`. Exit status is non-zero if any input fails; successful inputs are still emitted.
  - File transcripts are not deliveries: they never appear in `history` or `usage`.
- `tmux-whisper finder install|remove|status`
  - Human-readable management of the Finder Quick Action (`~/Library/Services/Transcribe with Tmux Whisper.workflow`).
- `tmux-whisper logs follow ... --json`
  - Streaming newline-delimited JSON events. Treat event names as provisional.
- `tmux-whisper watch ...`
  - Human/operator text view composed from stable JSON commands.
- `tmux-whisper bench-matrix ...`
  - Benchmark-oriented text table for local tuning, not an integration API.

## Contract Rules

- Additive JSON fields are allowed.
- Existing field names and broad value types should not change without a changelog note.
- Text output may be refined more freely, but it should keep command cross-links visible where useful.
- Prefer `next_commands` or `more_detail` when a caller needs a recommended follow-up path.
