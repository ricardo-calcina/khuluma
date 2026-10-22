# Integration Compatibility

Khuluma, the native menu-bar app in `native/`, is the main way to dictate. The installed `khuluma` CLI still owns config, history, usage and the daemon lifecycle that Khuluma reads through it. The Finder Quick Action and the agent skill wrap `khuluma transcribe`.

## Support Boundaries

- Supported platform: macOS with the requirements listed in the README.
- Supported install channels: Homebrew stable, bootstrap from GitHub, and local clone installs via `./install.sh`.
- Supported runtime source of truth: the CLI, config under `~/.config/khuluma`, install receipt, processing markers, and CLI status/diagnostic commands.
- Unsupported as production surfaces: alternate backend experiments and direct parsing of private files when a CLI read contract exists.

## Compatibility Matrix

| Surface | Status | Install/update path | Notes |
| --- | --- | --- | --- |
| Khuluma (native menu-bar app) | Daily driver | `tools/build-khuluma-app.sh` (see the README) | Owns the hotkey, capture, sounds, paste and the Stats window. Transcribes over the daemon socket and cleans text natively; uses the installed CLI for settings, history, usage and the daemon lifecycle (`docs/CLI_CONTRACTS.md`). |
| `khuluma` CLI | Supported (Khuluma's back end) | Local `./install.sh --force` for Khuluma; Homebrew or bootstrap for the CLI alone | Source of truth for config, vocab, history, usage, status and doctor. Khuluma needs the CLI from its own checkout (app contract). |
| CLI inline and tmux dictation | Retired (v0.11) | None | Khuluma replaces both. `inline process`, `inline record` and `inline cleanup` stay as Khuluma's back end. |
| Finder Quick Action (transcribe files) | Supported | `khuluma finder install` | Runs `integrations/finder/khuluma-transcribe.sh`, which calls `khuluma transcribe --beside --clipboard`. The handler is installed beside the binary (Homebrew's `share/khuluma`, or `~/.local/share/khuluma/integrations`). |
| Agent skill (`integrations/agents/transcribe-audio/`) | Supported | Copy into your agent's skills folder | Tells Claude Code and Codex to use `khuluma transcribe` for audio files. |
| Raycast scripts, SwiftBar plugin | Retired (v0.11) | None | Khuluma owns the dictation key and the menu-bar item. Old copies under `~/.config/khuluma/integrations/raycast` or SwiftBar's plugin folder can go to the Trash. |

## Environment Expectations

GUI launchers (Khuluma, Finder) run the CLI with a smaller environment than an interactive terminal. If behaviour differs from the terminal, check the environment first.

- Keep custom PATH dependencies and env-based overrides in `~/.zshenv`, which the CLI loads; don't rely on `.zshrc`.
- Use `khuluma status` and `khuluma doctor` to compare the installed runtime against what you see.

## Channel Differences

Homebrew is the stable channel. It is best when you want tagged releases and normal `brew upgrade` behavior.

Bootstrap is for pinned installs or testing a GitHub ref without keeping a clone. Prefer explicit `--ref` for reproducible setup.

Local clone installs are for active development. Run `./install.sh --force` after local code changes before judging installed CLI or Khuluma behaviour.

## Stable Vs Experimental Surfaces

Integrations should consume the stable JSON read contracts in `docs/CLI_CONTRACTS.md`; human-readable output is for operators and is not a parsing contract.

When adding integration behavior, prefer one of these shapes:

- extend the CLI/runtime source of truth
- expose a small documented command
- keep adapter scripts thin
- add deterministic tests that do not require a real microphone or real transcription


## Isolated app validation

A staged native instance requires `KHULUMA_SUPPORT_DIR`, `KHULUMA_LOG_DIR` and `KHULUMA_DEFAULTS_SUITE` together, with explicit private fixture roots and a distinct defaults suite. Give it a fixture-routed canonical CLI/config/socket/model reference too. Isolated mode skips real-home legacy import, disables frame autosave and prevents login-item changes. The synthetic `-KhulumaStatsSnapshot <directory>` path runs before ordinary app startup and uses fixed data rather than a personal ledger.

Installed agent skills, shell shortcuts, KwikCut and Finder are switched only after the matching new CLI and migration are verified. The temporary `tmux-whisper` command forwards to that same runtime; it is not a second writer.
