# Integrations

Khuluma, the native menu-bar app in `native/`, is the product. Everything else wraps it: the Finder Quick Actions and the agent skill both use the app's own file transcription.

## Supported surfaces

| Surface | Install | Notes |
| --- | --- | --- |
| Khuluma (menu-bar app) | `tools/build-khuluma-app.sh` (see the README) | Owns the hotkey, capture, sounds, cleanup, delivery, History, Vocabulary and Stats. Keeps its data in `~/Library/Application Support/Khuluma` and runs its own `khulumad` from the bundle. |
| `khuluma transcribe` helper | `ln -s ~/Applications/Khuluma.app/Contents/Helpers/khuluma ~/.local/bin/khuluma` | `khuluma transcribe <file>… [-q] [--format txt\|json] [-o FILE \| --beside] [--force]`. Uses the app's daemon when the app is running, or loads the model itself. Run `khuluma transcribe --help` for the details. |
| Finder Quick Actions | Built into the app (Services) | **Transcribe with Local** and **Transcribe with Cloud**: `<name>.txt` beside each file, the text copied, a notification. |
| Agent skill (`integrations/agents/transcribe-audio/`) | Copy into `~/.claude/skills/` or `~/.codex/skills/` | Tells Claude Code and Codex to use `khuluma transcribe` for audio files. |

`--format json` prints one object per input and line: `file`, `text`, `audio_duration_ms`, `processing_ms`, `model`, `engine`. `text` is the raw transcript with no dictation cleanup; file transcripts never reach history or usage.

Retired: the bash CLI and its Homebrew formula (2026-11), and before them the tmux flow, CLI recording, Raycast scripts and the SwiftBar plugin (v0.10.0). See `CHANGELOG.md`.

## Isolated app validation

A staged instance requires `KHULUMA_SUPPORT_DIR`, `KHULUMA_LOG_DIR` and `KHULUMA_DEFAULTS_SUITE` together, with explicit private fixture roots (0700, distinct children of one root) and a distinct `com.ricardo-nth.khuluma.*` defaults suite. Isolated mode disables frame autosave, prevents login-item changes and refuses model or sound overrides that point into real data. The synthetic `-KhulumaStatsSnapshot <directory>` path runs before ordinary app startup and uses fixed data rather than a personal ledger.
