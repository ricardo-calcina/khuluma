# Roadmap

This roadmap reflects the current product direction: reliable local dictation through the CLI, with **inline dictation** as the primary daily path and tmux as a distinctive terminal workflow.

## Principles

- Keep core behavior stable across inline and tmux workflows.
- Improve UX without introducing fragile complexity.
- Ship stable releases via Homebrew; use local/bootstrap installs for active testing.

## v0.4.0 - Public Hardening

Focus: make the public project robust for wider use.

- Harden parity between CLI, Raycast, and SwiftBar behaviors.
- Improve diagnostics (`tmux-whisper debug`, `tmux-whisper doctor`) for install/path/config issues.
- Add contributor-facing repo hygiene:
  - `CONTRIBUTING.md`
  - issue templates
  - release checklist
- Reduce logic duplication where practical, especially integration surfaces.

Success criteria:

- No known drift bugs between tmux/inline/integrations over a full release cycle.
- Clean upgrade path for both Homebrew and bootstrap users.

## v0.5.x - UX + Config Maturity (instead of backend expansion)

Focus: make day-to-day usage cleaner and safer.

- Improve mode/config UX and validation.
- Keep public command/help/docs language aligned on `tmux-whisper` while deferring internal `dictate` path/env churn.
- Improve vocab workflows (import/export/normalize safety).
- Refine docs for real-world setup and troubleshooting.

Recent progress (2026-02-19):

- `tmux-whisper doctor` now includes mode/config fallback diagnostics plus actionable suggested fixes.
- `tmux-whisper config defaults` and `config repair [--dry-run]` now provide a forward-safe config migration path, including reset/backup handling for malformed TOML.
- Vocab safety flow now includes invalid-line previews, guarded dedupe backups, and export snapshots.
- Added dedicated troubleshooting guide: `docs/TROUBLESHOOTING.md`.
- Active docs now better reflect real-world use: install channel choice, inline and tmux setup, integration environment expectations, and upgrade/repair flow.
- Added runtime SwiftBar integration toggle (`tmux-whisper swiftbar on|off|toggle`) so integration can be managed without reinstalling.
- Public-facing command language is now standardized on `tmux-whisper` across the active docs/operator surface, while config/sound paths remain intentionally under `dictate` for now.
- Stale cached AVFoundation audio-index invalidations now leave lightweight breadcrumbs in `debug`, `debug --json`, and active record logs when device-order changes force a re-resolve.
- Bootstrap installs now accept explicit source selectors (`--repo`, `--ref`, `--archive-url`) and write `~/.config/dictate/install-receipt.env`, making multi-machine setup/update provenance easier to verify.

Success criteria:

- Fewer setup/support issues caused by config mismatches.
- Predictable behavior after upgrades.

## v0.6.x - CLI-First Operator Platform

Focus: turn the existing operator summary layer into a first-class terminal product before adding any dashboard/TUI.

- Expand read-only/operator commands so shell users can inspect history, logs, bench data, devices, and config state without scraping human-only output.
- Keep pushing from parity into workflow depth: export/search/follow/watch commands should build on the read-only contracts rather than bypass them.
- Add export-friendly and watch/tail-style workflows that keep tmux/terminal users inside the CLI.
- Use filtered bench inspection and history session summaries as the main reliability investigation surface for FFmpeg drift soak, morning-delay warm-cache behavior, and SwiftBar/sound-start timing.
- Keep durable usage accounting transcript-free and retention-independent, so a future menu-bar surface can show verified new-delivery totals without pretending that old/pruned history is lifetime coverage.
- Treat inline dictation as the primary daily operating model while keeping tmux workflows first-class for terminal users.
- Treat any future TUI as a later convenience layer built on stable CLI contracts, not as the next milestone.

Success criteria:

- Common support and inspection tasks are answerable from the CLI alone.
- Read-only operator surfaces have clear text plus machine-readable contracts.
- Future integrations/TUI work can consume stable CLI data instead of re-implementing logic.
- Legacy whisper.cpp decode-default tuning is no longer an active roadmap item; runtime tuning now targets Parakeet warmup/cache/latency behavior.

## v0.7.x - Integration Platform

Focus: integrations as first-class, versioned surfaces.

- Released in `v0.7.0`: lifecycle diagnostics, version reporting, dry-run repair, and adapter-only repair across local, bootstrap, and Homebrew installs.
- Raycast and SwiftBar now report adapter versions plus `current`, `missing`, `non-executable`, or `different` provenance states.
- SwiftBar lifecycle refresh and stale-marker recovery are complete; validate recording, processing, cancel, and error transitions in daily use before widening the adapter scope.
- Keep the integration compatibility matrix and support boundaries documented in `docs/INTEGRATIONS.md`.

Success criteria:

- Adapter lifecycle/version checks and refresh plans can be inspected before mutation.
- Daily inline dictation remains the primary workflow, while tmux stays the differentiated asynchronous terminal workflow.

## Next Milestones: Usage Visibility and Native Companion

Focus: turn trusted local usage data into small, useful surfaces without changing the working capture and transcription flow.

- **Durable CLI usage metrics** ([#29](https://github.com/ricardo-nth/tmux-whisper/issues/29)): complete. The CLI persists privacy-preserving aggregates for successful deliveries and exposes coverage plus estimated typing-time assumptions in text and JSON.
- **SwiftBar usage metrics** ([#31](https://github.com/ricardo-nth/tmux-whisper/issues/31)): complete. The ready menu consumes the CLI usage summary while recording and processing remain clear. The SwiftBar plugin was retired in v0.11; Lowkey's menu and Stats window replace it.
- **Native macOS app** ([#30](https://github.com/ricardo-nth/tmux-whisper/issues/30)): phase 1 (v0.9) extracted `TmuxWhisperKit` from `tmux-whisperd`, made the daemon concurrent and self-updating. Next: phase 2, a minimal signed menu-bar app (hotkey → AVAudioEngine capture → in-process Parakeet → paste, with sounds) run side by side with the current setup. The shell-out companion prototype (#33) was closed. The revised plan extracts a shared Swift kit from `tmux-whisperd`, then builds a signed menu bar app that owns hotkey, capture, Parakeet, paste, and sounds, and serves the existing daemon socket so the CLI and tmux flow become clients. Phases 2 and 3 shipped this as Lowkey, which replaced the SwiftBar plugin and the Raycast scripts in v0.11.
- **Audio-file transcription** (released in v0.8.0): `tmux-whisper transcribe <file>` for voice memos with raw Parakeet output, excluded from dictation usage and history, plus a Finder Quick Action (`tmux-whisper finder install`). Next steps: daemon-side progress events and timestamped `srt`/`vtt`/segment output from Parakeet token timings; letting a long file job run without blocking dictation; drag-and-drop in the native app.

Success criteria:

- Usage figures remain accurate after transcript history is pruned and never imply recovery of older untracked dictations.
- Menu surfaces consume documented CLI contracts instead of calculating their own totals or duplicating capture logic.
- The native prototype is exercised with real local dictation before any decision to expand its scope.

## v1.0.0 - Stable Platform Release

Focus: stable command surface and release guarantees.

- Lock core CLI semantics.
- Define support policy (platform, dependencies, upgrade behavior).
- Publish clear stable vs experimental feature boundaries.

Success criteria:

- Users can adopt on stable channels with minimal breaking surprises.

## Post-v1 / Experimental Track

`faster-whisper` is intentionally **not** in the near-term roadmap.

Reasoning:

- Prior attempts were slower or required disproportionate complexity for this project's goals.
- Near-term effort is better spent on reliability and UX of the local inline and tmux workflows.

Future options (post-stability):

- Dedicated experimental branch/track for alternate backends.
- Separate sister tool focused on `faster-whisper`/other backend architecture from day one.
