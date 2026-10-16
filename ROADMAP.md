# Roadmap

Lowkey, the menu-bar app, is the product. The bash CLI that started the project becomes its back end, and is then retired. The detailed plan, with exit criteria for each phase, is [`docs/plans/LOWKEY_RENAME_ROADMAP.md`](docs/plans/LOWKEY_RENAME_ROADMAP.md) (approved 2026-10-15). This page is the short version.

## Principles

- **Dictation stays local and fast.** Every change is measured against the take log (`tools/lowkey-report.sh`): warm overhead, fallback rate, failure rate.
- **Never lose a take.** Quit, daemon timeouts and CLI mismatches keep the audio or the record until it's safely handled. Closing the remaining gaps (a crash mid-take, a timeout on the CLI fallback) is part of phase 1.
- **Counts, not text.** Usage, stats and logs hold numbers and durations only.
- **One way to do each thing.** When Lowkey takes over a job, the CLI's version goes (as the tmux flow, CLI recording, Raycast and SwiftBar already have).

## Where things stand

Released (tagged, and on Homebrew up to v0.9.0):
- **v0.7:** the CLI's operator commands (`doctor`, `status`, history, bench, usage) and their JSON contracts.
- **v0.8:** audio-file transcription with the Finder Quick Action.
- **v0.9:** `TmuxWhisperKit` extracted from the daemon.

On `main`, not yet tagged:
- **v0.10:** Lowkey and its native pipeline: the daemon socket, Swift cleanup proven against the CLI with shared fixtures, Quit recovery, and a warning for a broken `config.toml`.
- **v0.11:**
  - Lowkey's daily-use features: daemon supervision, Retry for timed-out takes, the honest start chime, Ctrl+Esc, Start at Login, the Stats window and per-day usage.
  - Phase 0's tidy-up: Lowkey requires the CLI it was built with (the app contract); the tmux flow, CLI recording, LLM post-processing, silence trim, chunking, Raycast and SwiftBar are gone; Lowkey's controller is split by responsibility.

## Phases

0. **Check the name, then tidy.** The name check (Lowkey vs other spellings or a longer store name) is still open. The tidy-up (P0b) is done apart from a week of daily use with the report's gates still met.
1. **Lowkey stops needing the CLI.** Native writers for usage and history, then config, then the daemon in the bundle, model download, and native or dropped fallbacks. Each piece is proven against the CLI on shared files.
2. **Ship Lowkey on its own.** Developer ID signing and notarization, a `lowkey` cask, a Settings and History window, Transcribe File, a bundled `lowkey` CLI for the agent skill, and the new `ricardo-nth/lowkey` repo.
3. **Data moves to Lowkey.** A one-time, repeatable import of `~/.config/dictate` into Lowkey's Application Support folder.
4. **Deprecate the CLI.** A notice on interactive commands, and the formula marked deprecated with the cask as its replacement.
5. **Sunset and archive** this repo and the formula.

The Mac App Store (phase 6) is parked. Phase 1 is designed so it isn't ruled out.

## Not planned

- **Other speech backends** (`faster-whisper`, whisper.cpp): earlier attempts were slower than Parakeet on CoreML, and the daemon protocol keeps the option open.
- **LLM rewriting of dictations:** dropped in v0.11.
- **Cloud or API-first dictation:** belongs in a separate project (see the TODO in `CHANGELOG.md`).
