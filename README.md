# Tmux Whisper

Local-first dictation for macOS using a warm Swift/CoreML Parakeet backend by default, with optional LLM cleanup and tmux/desktop integrations.

## Core USP

Tmux Whisper is **inline-first for daily dictation, with tmux as a first-class differentiator**.

- Primary daily workflow: record and deliver into the frontmost app with inline dictation.
- Tmux workflow: record in a pane, let transcription/process run, and keep working in other panes/windows.
- Design priority is reliable local dictation, while retaining the asynchronous terminal/tmux flow that desktop-only tools do not offer.

## What You Get

- `bin/tmux-whisper`: main CLI / orchestration layer
- `bin/dictate-lib.sh`: shared helper library used by Tmux Whisper and its integrations
- `tmux-whisperd/`: local Swift daemon package used by the default backend
- `config/`: default config, modes, and vocab
- `integrations/raycast/`: Raycast scripts (`inline`, `toggle`, `cancel`)
- `integrations/tmux-whisper-status.0.2s.sh`: SwiftBar plugin
- `assets/sounds/dictate/`: tiny sample WAV sound pack
- `install.sh`: local installer
- `docs/plans/`: planning/history notes kept separate from active operator docs
- `tests/`: deterministic bash tests and install smoke tests
- `.github/workflows/ci.yml`: CI for syntax + tests

## Requirements

- macOS
- `ffmpeg`
- `python3` (with `tomllib`, Python 3.11+ recommended)
- `swift` + Xcode toolchain (for building the local `tmux-whisperd` backend)
- a local Parakeet model directory, either at `~/.local/share/tmux-whisper/models/...` or via `swift_parakeet.model_path`
- Optional: `tmux`, Raycast, SwiftBar
- Optional for LLM postprocess: `CEREBRAS_API_KEY`

## Install Channels

Choose the channel that matches how you want to use the tool:

### Homebrew stable

Best for daily use when you want tagged releases and the simplest update path.

```bash
brew tap ricardo-nth/tap
brew install ricardo-nth/tap/tmux-whisper
```

Update later with:

```bash
brew upgrade tmux-whisper
```

### Bootstrap from GitHub

Best for testing `main` or pinning a specific release without keeping a local clone.

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/main/bootstrap.sh | bash
```

Pinned to a release tag:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/v0.9.0/bootstrap.sh | bash
```

Pass bootstrap and install flags explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/main/bootstrap.sh | bash -s -- --force --with-sounds
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/main/bootstrap.sh | bash -s -- --ref v0.9.0 --force
```

### Local clone / development

Best when this repo is your source of truth and you want fast local iteration.

```bash
git clone https://github.com/ricardo-nth/tmux-whisper.git
cd tmux-whisper
./install.sh
```

Refresh a local clone after pulling new changes:

```bash
git pull
./install.sh --force
```

## Install Notes

The default backend is local `swift_parakeet`.

Preferred Parakeet model home:

- `~/.local/share/tmux-whisper/models/parakeet-tdt-0.6b-v3-coreml`
- `~/.local/share/tmux-whisper/models/parakeet-tdt-0.6b-v2-coreml`

Tmux Whisper expects a Parakeet model to already exist locally in that owned path, or to be pointed at an existing model directory via `swift_parakeet.model_path`. Install does not download model assets for you.

Install behavior:

- Preserves existing config, modes, and vocab by default, including when `--force` is used.
- `--force` refreshes binaries/integrations and seeds missing defaults; it does not replace your live config file.
- Installs Raycast scripts to `~/.config/dictate/integrations/raycast`.
- Installs SwiftBar plugin to `~/.config/swiftbar/plugins/tmux-whisper-status.0.2s.sh`.
- Installs sample sounds to `~/.local/share/sounds/dictate`.
- Runs a best-effort backend warm-up after install/update, including a tiny synthetic prime transcription so the next real dictation is closer to warm.
- Writes an install receipt to `~/.config/dictate/install-receipt.env` with the install source, archive URL when bootstrapped, repo ref/commit when available, and resolved runtime paths.
- Note: config and sounds paths intentionally remain under `dictate` in this phase (`~/.config/dictate`, `~/.local/share/sounds/dictate`).

Useful install flags:

```bash
./install.sh --force            # reinstall scripts and seed missing defaults (preserves local config)
./install.sh --no-sounds        # skip sample sound install
./install.sh --with-sounds      # explicit sound install
./install.sh --replace-sounds   # overwrite existing sound files with bundled samples
```

`bootstrap.sh` downloads a repository archive from GitHub and runs `install.sh` from that archive. Use `--ref <tag-or-commit>` when you want reproducible setup across machines.

## First Run Checklist

Run these once after install or upgrade:

```bash
tmux-whisper debug
tmux-whisper doctor
tmux-whisper status
tmux-whisper warmup
```

Use `tmux-whisper debug` if you are ever unsure which binary/channel you are running. It shows the resolved binary path and install channel.

## Quick Start

```bash
tmux-whisper debug
tmux-whisper inline
tmux-whisper            # tmux toggle mode
tmux-whisper devices
tmux-whisper mode auto
tmux-whisper postprocess on
```

### Tmux workflow

- Start from the tmux pane you want to send back into.
- Run `tmux-whisper`, speak, then stop.
- Let processing finish while you keep working in tmux.

If you are not inside tmux, use `tmux-whisper inline` or the Raycast inline integration instead.

### Transcribe audio files

Voice memos from a phone or dictaphone go through the same local Parakeet model:

```bash
tmux-whisper transcribe memo.m4a               # raw transcript to stdout
tmux-whisper transcribe memo.m4a --beside      # writes memo.txt next to it
tmux-whisper transcribe memo.m4a -c            # also copy to the clipboard
tmux-whisper transcribe *.m4a --out-dir notes/ # one .txt per file
tmux-whisper transcribe memo.m4a --format json # text + durations + model
tmux-whisper transcribe - < memo.m4a           # read from stdin
```

- Anything ffmpeg can decode works (m4a, mp3, wav, aac, flac, ogg/opus, video audio tracks). The original file is never modified; it is decoded into a private 16 kHz copy.
- Output is the **raw** transcript: dictation cleanup (vocab, British spelling, filler/repeat removal, modes, LLM post-processing) is not applied, and file transcripts are not counted in `usage` or written to history.
- Long recordings are chunked by the Parakeet runtime itself; a 10-minute memo took about 15 seconds end to end on an M1 Air with the model warm. Dictation waits while a long file is transcribing.
- Existing output files are never overwritten without `--force`; failures exit non-zero and leave no partial output.

For AI agents (Claude Code, Codex), `integrations/agents/transcribe-audio/SKILL.md` is a skill that tells them to use `tmux-whisper transcribe` for audio files instead of downloading a speech model. Install it by copying the folder into `~/.claude/skills/` and/or `~/.codex/skills/`.

For right-click transcription in Finder:

```bash
tmux-whisper finder install   # adds Quick Actions > "Transcribe with Tmux Whisper"
```

It writes `<name>.txt` next to each selected audio file, copies the transcript to the clipboard, and posts a notification. It is enabled for the Finder context menu automatically (no System Settings step). The first run may ask for permission to access the folder the memo is in. Remove it with `tmux-whisper finder remove`.

### Durable usage summary

`tmux-whisper usage` reports a small local, transcript-free aggregate for
successful deliveries; `tmux-whisper usage --json` is the stable surface for a
SwiftBar menu and for the experimental native companion. SwiftBar already
consumes this contract; the native companion remains outside the stable release
scope. The aggregate survives normal transcript-history pruning, but begins
only after the feature is installed and never backfills old or pruned history.

The estimate shows the typing pace assumption (`DICTATE_HISTORY_TYPING_WPM`,
default `40`) and a signed difference between typing-equivalent time and full
recording-to-delivery elapsed time. It is an estimate, not a claim of lifetime
hours saved. Changing that WPM setting recalculates the estimate while leaving
the recorded delivery and duration totals unchanged.

## Upgrade and Repair

Daily-use upgrade flow depends on channel:

- Homebrew:
  - `brew upgrade tmux-whisper`
- Bootstrap:
  - rerun the bootstrap command you used before, typically with `--force`
  - for reproducible upgrades, include the same `--ref <tag-or-commit>` on every machine
- Local clone:
  - `git pull`
  - `./install.sh --force`

After any upgrade:

```bash
tmux-whisper doctor
tmux-whisper status
```

If config drift is reported:

```bash
tmux-whisper config repair --dry-run
tmux-whisper config repair
```

### Bench matrix

`tmux-whisper bench-matrix [N] [phrase_file]` runs the cleanup/postprocess pipeline across the in-repo phrase list (or a small file you supply) with the requested number of rounds. Each line in `phrase_file` is trimmed and blank/commented lines (those beginning with `#`) are ignored, so you can customize the set while keeping the defaults for quick comparison. Set `DICTATE_BENCH_MATRIX_MODE` to force which fixed mode (typically `code`) drives the cleanup, postprocess, and vocab helpers. The output table is sorted by postprocess, model, and vocab settings to keep diffs stable, and you still see the warning `postprocess=on combos skipped` if `CEREBRAS_API_KEY` is unset.

## UX Helpers

- `tmux-whisper doctor` now includes a **Suggested fixes** block with copy/paste commands when it finds dependency, install, config, or stale-state issues.
- `tmux-whisper doctor` now validates fixed/tmux mode values and core mode prompt files (`code`/`long`) and reports explicit fallback behavior when invalid.
- `tmux-whisper config defaults` now prints the canonical default config template, and `tmux-whisper config repair [--dry-run]` can safely fill missing defaults, refresh schema version in place, or reset malformed TOML with a backup.
- `tmux-whisper vocab import <file>` now shows line-numbered previews for invalid entries (first 5).
- `tmux-whisper vocab import --dry-run <file>` lets you preview additions before mutating your live vocab.
- `tmux-whisper vocab dedupe` now creates a timestamped backup before rewriting your vocab file.
- `tmux-whisper vocab rm "pattern"` now uses safer literal matching by default, with `--regex` available when you truly want regex behavior.
- `tmux-whisper vocab export <file>` writes a normalized/deduped vocab snapshot you can share or version.
- `tmux-whisper history list [N] --json` now exposes recent dictation summaries as a machine-readable array for shell scripts and future operator tooling.
- `tmux-whisper history search <query> [N] [--json]` turns saved dictations into a searchable operator surface without leaving the CLI.
- `tmux-whisper history export [N|all] [--json]` now exports full history entries for shell pipelines, sharing, and agent/operator replay flows.
- History JSON keeps transcript, word-count, timing, and audio-artifact metadata for stats/roundups; inline debug WAVs are pruned separately with `history.audio_retention_days` / `DICTATE_HISTORY_AUDIO_RETENTION_DAYS` so audio cannot grow forever.
- `tmux-whisper logs path|tail|follow|--json` now gives log inspection both snapshot and live-follow workflows instead of one fixed text dump.
- `tmux-whisper devices --json` now exposes AVFoundation audio devices as structured CLI output for support/debug flows.
- `tmux-whisper config [--json]`, `config path [--json]`, and `config get <path> [--json]` now give config inspection a real read-only operator surface instead of only repair-oriented guidance.
- `tmux-whisper bench [N] --json` now exposes timing summaries as structured data, and `tmux-whisper bench export [N|all] [--json]` exports the raw recent rows behind those summaries.
- `tmux-whisper watch [--interval SECONDS] [--iterations N]` now turns `status` + `last` + `bench` into a text-first live operator overview without committing the project to a TUI.
- `tmux-whisper status --preset compact` and `watch --preset compact` now provide narrower operator snapshots for tighter terminals, quick checks, and future shell/plugin surfaces.
- `tmux-whisper bench-matrix [N] [phrase_file]` runs a quick matrix over postprocess/vocab toggles (and LLM models when API key is set) on fixed phrases.
  - Phrase file format: one phrase per line (blank lines and `#` comments ignored). Optional `label<TAB>phrase` is supported.
  - Set `DICTATE_BENCH_MATRIX_PROGRESS=0` for summary-only output (no per-combo progress lines).
- Stable CLI JSON surfaces are tracked in [`docs/CLI_CONTRACTS.md`](docs/CLI_CONTRACTS.md); prefer those contracts for scripts, agents, SwiftBar/native wrappers, and future UI layers.

## Troubleshooting

Start here:

```bash
tmux-whisper debug
tmux-whisper doctor
tmux-whisper status
```

Common real-world fixes are documented in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md), including:

- install-channel refresh and upgrade drift
- invalid config repair
- tmux vs inline usage errors
- Raycast/SwiftBar environment issues
- vocab and mode recovery flows

## Integrations

Raycast and SwiftBar are optional adapters around the CLI. Tmux Whisper remains usable without either one. For the supported integration matrix, install-channel expectations, environment boundaries, and stable-vs-experimental surface definitions, see [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

### Raycast

Installer-managed Raycast scripts live at:

- `~/.config/dictate/integrations/raycast/tmux-whisper-inline.sh`
- `~/.config/dictate/integrations/raycast/tmux-whisper-toggle.sh`
- `~/.config/dictate/integrations/raycast/tmux-whisper-cancel.sh`

Recommended setup:

- create three Raycast Script Commands that point at those installed files
- use `tmux-whisper-inline.sh` for frontmost-app paste/send
- use `tmux-whisper-toggle.sh` for pane-targeted tmux recording from a hotkey
- use `tmux-whisper-cancel.sh` for discard/cancel behavior

### SwiftBar

Installer-managed plugin path:

- `~/.config/swiftbar/plugins/tmux-whisper-status.0.2s.sh`

Runtime toggle (without uninstalling plugin file):

```bash
tmux-whisper swiftbar        # show ON/OFF
tmux-whisper swiftbar off    # keep plugin loaded but show OFF state
tmux-whisper swiftbar on
```

If needed, set `DICTATE_INSTALL_SWIFTBAR=0` to skip plugin install.

When usage tracking has started, the ready-state menu shows delivered words,
the tracking start time, and a signed **estimated typing-time difference**
(`typing equivalent - dictation elapsed`). SwiftBar reads the stable
`tmux-whisper usage --json` contract and caches it between redraws; recording
and processing states stay focused on their controls.

### Integration environment note

Raycast and SwiftBar often run with a minimal shell environment. If you rely on `CEREBRAS_API_KEY`, custom PATH entries, or env-based overrides, put them in `~/.zshenv` so the integrations can see them consistently.

### Integration lifecycle checks

`tmux-whisper integrations` inspects the installed adapter surface. For v0.7 integration-platform work, lifecycle checks start with an observable doctor and a dry-run repair preview:

```bash
tmux-whisper integrations doctor
tmux-whisper integrations repair --dry-run
tmux-whisper integrations repair
```

`doctor` checks the installed binary, install receipt, Raycast scripts, SwiftBar plugin, executable bits, and adapter drift from the recorded source tree. `integrations` and `doctor` report each adapter as `current`, `missing`, `non-executable`, or `different` from source so update provenance is visible before repair. `repair --dry-run` shows the adapter-only refresh plan without changing files. `repair` refreshes only the installed Raycast scripts and SwiftBar plugin, creates missing adapter directories, fixes executable bits, and backs up replaced adapter files to `~/.config/dictate/backups/integrations/`. It works on Homebrew, bootstrap, and local installs; use `./install.sh --force` only when you need a full local runtime refresh.

## Sounds

Bundled sample sounds live in `assets/sounds/dictate/` and install by default to:

```bash
~/.local/share/sounds/dictate
```

Existing files in that folder are preserved by default (including when using `--force`).
Use `--replace-sounds` only when you explicitly want to overwrite local sound files.

## Development Workflow

Use this repo as the source of truth and install to your local runtime path:

```bash
# from repo root
./install.sh --force
```

Then test your local command:

```bash
tmux-whisper debug
tmux-whisper bench 10
tmux-whisper bench --json
tmux-whisper bench-matrix 1
```

## Lowkey (experimental native app)

Lowkey is the native macOS menu-bar front-end for inline dictation. It runs beside the CLI/Raycast setup, so you can compare the two. It handles the hotkey, microphone, sounds and paste natively. It sends each take straight to the Parakeet daemon (`tmux-whisperd`) and cleans the text up in Swift with the same rules as the CLI (vocab, modes, British spelling, tail rescue), so the text matches inline dictation exactly without starting the CLI. History, bench and usage are still written by the installed `tmux-whisper` (`inline record`), in the background after the text is pasted. Takes fall back to `tmux-whisper inline process` when LLM post-processing or silence trim is on, the CLI runs in a non-C locale, or the daemon can't be reached.

```bash
tools/make-signing-identity.sh   # once: local code-signing identity (keeps permissions across rebuilds)
tools/build-lowkey-app.sh        # build, sign, install ~/Applications/Lowkey.app
open ~/Applications/Lowkey.app
```

On first launch, allow Microphone, and Accessibility (for pasting) in System Settings → Privacy & Security. The default hotkey is `ctrl+option+space`. Change it in `~/.config/dictate/config.toml`:

```toml
[app]
hotkey = "ctrl+option+space"   # e.g. "cmd+shift+d", "f13"
native_pipeline = true         # false: always use `tmux-whisper inline process`
verify_pipeline = true         # also run the CLI cleanup in the background and log any difference
supervise_daemon = true        # keep the Parakeet daemon warm (launch, wake, recording start)
```

Then choose **Reload Settings** from the menu. Timings, errors and `verify:` results are in `~/Library/Logs/Lowkey/app.log`.

## Repo Layout

- `bin/tmux-whisper` is the main product orchestration layer.
- `tmux-whisperd/` is the Swift package for the Parakeet backend: the `TmuxWhisperKit` library (daemon protocol, `ASREngine`, socket server; shared with the planned native app), the thin `tmux-whisperd` executable, and Swift Testing tests (`cd tmux-whisperd && swift test`). The CLI builds it on demand into `~/.local/share/tmux-whisper/native/tmux-whisperd` and rebuilds when the sources change.
- `install.sh`, `config/`, `integrations/`, and `tests/` are active first-class parts of the app, not support-only extras.
- `docs/` keeps active operator docs at the top level, while longer-term planning notes live under `docs/plans/`.

## Testing and CI

Run local checks:

```bash
./tests/ci.sh
```

This runs:

- `bash -n` syntax checks across shipped shell scripts
- `tests/test_lib.sh` (helper behavior)
- `tests/test_cli.sh` (relocation behavior for brew installs)
- `tests/test_regression.sh` (diagnostic/integration hardening guards)
- `tests/test_flow_parity.sh` (stubbed tmux/inline lifecycle + send-path parity)
- `tests/test_install.sh` (installer smoke tests)
- `tests/test_bootstrap.sh` (bootstrap flow smoke test)

GitHub Actions runs the same checks on push and pull requests.

`tmux-whisper doctor` now includes config schema status (`meta.config_version`) and expects an exact schema match for this binary.

`tmux-whisper version` reports the CLI version, expected config schema, and
resolved running binary. `tmux-whisper version --json` also includes the
install receipt's provenance when available. The receipt records how an install
was created; it does not identify a source checkout as the running binary.

## Changelog

`CHANGELOG.md` in this repo mirrors the detailed project history from local development, including the active TODO/next queue.

## Roadmap

See `ROADMAP.md` for the current direction: inline daily dictation, a differentiated tmux workflow, and versioned integration adapters.

## Contributing

See `CONTRIBUTING.md` for branch, validation, and release expectations.

Release operators should also follow `docs/RELEASE_CHECKLIST.md`.

## Safety Notes

- Runtime directories (`history`, caches, archives, temp logs) are not tracked.
- API keys are not stored in this repository.
- Existing local config is preserved by default, including when `--force` is used.

## License

MIT
