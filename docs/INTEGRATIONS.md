# Integration Compatibility

Tmux Whisper is CLI-first. Raycast scripts are adapter surfaces around the installed `tmux-whisper` command and the runtime state files it owns.

Use this document to decide whether an integration issue belongs in the supported path, the local-development path, or a future experimental track.

## Support Boundaries

- Supported platform: macOS with the requirements listed in the README.
- Supported install channels: Homebrew stable, bootstrap from GitHub, and local clone installs via `./install.sh`.
- Supported integration adapters: the installer-managed Raycast scripts shipped in this repo. The SwiftBar plugin was retired in v0.11; Lowkey's menu-bar item replaces it.
- Supported runtime source of truth: the CLI, config under `~/.config/dictate`, install receipt, state files, processing markers, and CLI status/diagnostic commands.
- Unsupported as production surfaces today: a native macOS companion app, alternate backend experiments, dashboard/TUI wrappers, and direct edits to installed adapter files without repair/install follow-up.

## Compatibility Matrix

| Surface | Status | Install/update path | Notes |
| --- | --- | --- | --- |
| `tmux-whisper` CLI | Stable daily surface | Homebrew, bootstrap, or local `./install.sh --force` | Source of truth for tmux, inline, config, history, logs, status, doctor, and integration checks. |
| CLI inline dictation | Stable daily workflow | Installed CLI | Uses macOS paste/send automation. It is the primary dictation path for frontmost-app capture and optional auto-send. |
| tmux dictation | Stable terminal workflow | Requires `tmux` plus the installed CLI | Provides the differentiated tmux capture and queue workflow. Use `tmux-whisper status`, `history sessions`, `bench`, and `logs` for support. |
| Raycast inline script | Supported adapter | `./install.sh --force` or `tmux-whisper integrations repair` | Should stay thin and delegate to the installed CLI/runtime rather than carrying independent state logic. |
| Raycast tmux-toggle script | Supported adapter | `./install.sh --force` or `tmux-whisper integrations repair` | Requires `tmux`; uses the same runtime state as the CLI tmux flow. |
| Raycast cancel script | Supported adapter | `./install.sh --force` or `tmux-whisper integrations repair` | Cancels active tmux or inline state through the shared runtime markers. |
| SwiftBar plugin | Retired (v0.11) | None | Lowkey's menu-bar item replaces it. `tmux-whisper swiftbar` remains as a no-op notice; integration checks ignore a leftover plugin file, receipt key or config table. |
| Finder Quick Action (transcribe files) | Experimental adapter | `tmux-whisper finder install` | Runs `integrations/finder/tmux-whisper-transcribe.sh`, which calls `tmux-whisper transcribe --beside --clipboard`. Not yet covered by `integrations doctor`. |
| Native macOS app | Planned | None yet | See issue #30: a native app that owns capture, Parakeet, and paste, serving the existing daemon socket so the CLI and tmux flow stay clients. |
| Alternate backend experiments | Experimental/future | None supported | Parakeet/CoreML is the active runtime path; alternate engines belong outside the near-term support boundary. |

## Environment Expectations

Raycast often runs with a smaller environment than an interactive terminal. If an integration behaves differently from the CLI, check environment first.

- Put durable variables such as `CEREBRAS_API_KEY` in `~/.zshenv` when integrations need them.
- Do not rely on interactive-only shell setup from `.zshrc` for Raycast.
- Keep custom PATH dependencies visible to non-interactive shells.
- Use `tmux-whisper debug` and `tmux-whisper status` to compare the installed runtime view against the integration behavior.

## Channel Differences

Homebrew is the stable channel. It is best when you want tagged releases and normal `brew upgrade` behavior.

Bootstrap is for pinned installs or testing a GitHub ref without keeping a clone. Prefer explicit `--ref` for reproducible setup.

Local clone installs are for active development. Run `./install.sh --force` after local code changes before judging installed CLI or Raycast behavior.

## Lifecycle Commands

Start integration support with non-mutating checks:

```bash
tmux-whisper integrations doctor
tmux-whisper integrations repair --dry-run
```

Use adapter-only repair when the installed Raycast scripts are missing, non-executable, or drifted from the recorded source tree:

```bash
tmux-whisper integrations repair
```

Adapter sources resolve from the installed copy beside the binary: Homebrew's `share/tmux-whisper`, or the `~/.local/share/tmux-whisper/integrations` snapshot written by `install.sh` and bootstrap. Replaced adapters are backed up to `~/.config/dictate/backups/integrations/`. Missing Raycast scripts are reported as warnings because the adapter is optional.

Use the full local installer when the binary, libraries, config defaults, sounds, native backend source, or install receipt also need to be refreshed:

```bash
./install.sh --force
```

## Stable Vs Experimental Surfaces

Supported surfaces are documented CLI commands, installer-managed adapter paths, and the integration doctor/repair lifecycle. Their human-readable output is for operators and is not a stable parsing contract; integrations should consume the stable JSON read contracts in `docs/CLI_CONTRACTS.md`.

Experimental surfaces are menu layout details, native companion ideas, alternate backend experiments, and any direct parsing of private state files when a CLI read contract exists.

When adding integration behavior, prefer one of these shapes:

- extend the CLI/runtime source of truth
- expose a small documented command
- keep adapter scripts thin
- add deterministic tests that do not require live Raycast, a real microphone, or real transcription
