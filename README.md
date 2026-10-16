# Tmux Whisper

Local dictation for macOS. Press a key, speak, and the text is pasted into the app in front of you, transcribed on your Mac by a warm Parakeet model (Swift/CoreML). Nothing leaves the machine.

The project is being renamed after its menu-bar app, **Khuluma** (isiNdebele and isiZulu for "speak"; it was called Lowkey until v0.11). The plan is [`docs/plans/KHULUMA_RENAME_ROADMAP.md`](docs/plans/KHULUMA_RENAME_ROADMAP.md). Until the rename is done, the project has three parts:

- **Khuluma** (`tmux-whisperd/Sources/Khuluma`): the menu-bar app you dictate with. It owns the hotkey, the microphone, the sounds, delivery (paste, optionally send) and the Stats window. It transcribes over the daemon's socket and cleans the text up in Swift.
- **`tmux-whisperd`**: the local Parakeet daemon that keeps the model loaded.
- **The `tmux-whisper` CLI** (`bin/`): Khuluma's back end for now. It holds config, vocab, history and usage, starts and warms the daemon, and transcribes audio files. Khuluma calls it through a small set of JSON commands ([`docs/CLI_CONTRACTS.md`](docs/CLI_CONTRACTS.md)).

The tmux pane flow, CLI recording, LLM post-processing, the Raycast scripts and the SwiftBar plugin were removed in v0.11 (see `CHANGELOG.md`).

## Requirements

- macOS 14 or later
- `python3` 3.11+ (for `tomllib`) and `ffmpeg`
- Xcode or the Command Line Tools (`swift`), to build the daemon and Khuluma
- A Parakeet CoreML model on disk, at `~/.local/share/tmux-whisper/models/parakeet-tdt-0.6b-v3-coreml` (or `-v2-coreml`), or anywhere `swift_parakeet.model_path` in the config points. Install doesn't download it; FluidInference publishes these CoreML conversions on Hugging Face.

## Install

Khuluma is built from a clone, and it needs the CLI from the same checkout: the two share an app contract number, and Khuluma refuses takes from a CLI with a different one.

```bash
git clone https://github.com/ricardo-nth/tmux-whisper.git
cd tmux-whisper
./install.sh                     # the CLI, default config, vocab and sounds
tools/make-signing-identity.sh   # once: a local code-signing identity, so permissions survive rebuilds
tools/build-khuluma-app.sh        # build, sign and install ~/Applications/Khuluma.app
open ~/Applications/Khuluma.app
```

On first launch, allow Microphone and Accessibility (for pasting) in System Settings → Privacy & Security.

After pulling changes, refresh both:

```bash
git pull
./install.sh --force
tools/build-khuluma-app.sh
```

`build-khuluma-app.sh` quits and relaunches Khuluma. It waits (up to 5 minutes) for a take in progress to finish first.

**Upgrading from Lowkey.app:** the first `build-khuluma-app.sh` quits `~/Applications/Lowkey.app`, moves it to the Trash and installs `Khuluma.app`. Microphone and Accessibility carry over: the bundle id (`com.ricardo-nth.lowkey`) and the signing identity keep their old names until Developer ID signing. On its first launch Khuluma moves the log and any saved takes to `~/Library/Logs/Khuluma` and `~/Library/Application Support/Khuluma`. If you used Start at Login, turn it on again in the menu.

`install.sh` keeps your config, vocab and sounds, including with `--force`, which only refreshes the scripts and adds missing defaults. Other flags: `--no-sounds`, `--with-sounds`, `--replace-sounds` (overwrite your sound files with the bundled ones). It ends with a daemon warm-up, and writes an install receipt to `~/.config/dictate/install-receipt.env`.

**CLI only:** Homebrew (`brew install ricardo-nth/tap/tmux-whisper`, at v0.9.0) and `bootstrap.sh` install the CLI without Khuluma. They are for file transcription, or a pinned CLI on another machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/main/bootstrap.sh | bash -s -- --ref v0.9.0 --force
```

Config and sounds still live under the old name: `~/.config/dictate` and `~/.local/share/sounds/dictate`.

## Using Khuluma

Press the hotkey to start, speak after the chime, press it again to stop. Ctrl+Esc cancels a recording. The default hotkey is `ctrl+option+space`; change it in `~/.config/dictate/config.toml`, then choose **Reload Settings** in the menu:

```toml
[app]
hotkey = "ctrl+option+space"   # e.g. "cmd+shift+d", "f13"
supervise_daemon = true        # keep the Parakeet daemon warm (launch, wake, recording start)
```

The menu shows:
- whether Khuluma is ready, recording or processing;
- the hotkey;
- whether the Parakeet daemon is ready;
- a warning if `config.toml` doesn't parse.

It also offers **Stats…**, **Open Log** and **Start at Login**.

- **Timed-out takes:** when the daemon times out on a take, its audio is kept privately for an hour. **Retry** transcribes it again, and **Paste retried dictation** pastes it wherever you are, without sending. A take that times out on the CLI fallback isn't kept.
- **Quitting:** a take still recording is saved to disk first, then transcribed into history and copied to the clipboard (never pasted). Quit waits up to 30 seconds for that and for takes already being transcribed. Saved audio and records that haven't reached history by then are finished at the next launch, without touching the clipboard; a take still in memory past the 30 seconds is lost.
- **Fallback:** if the daemon can't be reached, the take goes through `tmux-whisper inline process` instead. The same happens when the CLI runs in a non-C locale.

**Delivery settings** live in the CLI:

```bash
tmux-whisper autosend on|off            # paste and press the send key, or paste only
tmux-whisper send-mode enter|ctrl_j|cmd_enter
tmux-whisper target origin|current      # the app in front at the start of recording, or at the end
tmux-whisper sound start|stop|process|error on|off
```

**Stats…** shows lifetime words, words per minute, the estimated time saved against typing (always labelled as an estimate, at 40 wpm by default), a 30/60/90-day activity heatmap, your streak and your bests. It reads `tmux-whisper usage --json --days all`, which holds counts and durations only, never what you said.

**Logs:** `~/Library/Logs/Khuluma/app.log` has one `take:` line per take (path, outcome, timings; no text). `tools/khuluma-report.sh` summarises it: outcomes, fallback and failure rates, and where the time goes.

## Vocab

Cleanup removes fillers and repeats, applies your vocab corrections and British spelling. There is one vocab file, `~/.config/dictate/vocab`, used for every take in every app.

```bash
tmux-whisper vocab add "clawed::Claude"     # also "wrong -> right"
tmux-whisper vocab import --dry-run fixes.txt
tmux-whisper vocab dedupe                   # backs up first
tmux-whisper vocab rm "literal text"        # --regex to match a pattern
```

Modes were removed in v0.11. If an older install left `modes/` or `current-mode` in `~/.config/dictate`, `./install.sh` folds each `modes/*/vocab` into `vocab` (skipping rules it already has) and moves the old files to `modes-archive/`. To run it yourself, or preview it first:

```bash
tmux-whisper migrate-modes --dry-run
tmux-whisper migrate-modes
```

## Transcribe audio files

Voice memos go through the same local model:

```bash
tmux-whisper transcribe memo.m4a               # raw transcript to stdout
tmux-whisper transcribe memo.m4a --beside      # writes memo.txt next to it
tmux-whisper transcribe memo.m4a -c            # also copy to the clipboard
tmux-whisper transcribe *.m4a --out-dir notes/ # one .txt per file
tmux-whisper transcribe memo.m4a --format json # text + durations + model
tmux-whisper transcribe - < memo.m4a           # read from stdin
```

- Anything ffmpeg can decode works (m4a, mp3, wav, aac, flac, ogg/opus, video audio tracks). The original is never modified.
- The output is the **raw** transcript: no dictation cleanup. File transcripts aren't counted in `usage` or written to history.
- Parakeet chunks long recordings itself: a 10-minute memo took about 15 seconds on an M1 Air with the model warm. Dictation waits while a long file is transcribing.
- Output files are never overwritten without `--force`, and failures leave no partial output.

**Finder:** `tmux-whisper finder install` adds Quick Actions → "Transcribe with Tmux Whisper". It writes `<name>.txt` next to each selected file, copies the text and posts a notification. Remove it with `tmux-whisper finder remove`.

**Agents:** `integrations/agents/transcribe-audio/SKILL.md` tells Claude Code and Codex to use `tmux-whisper transcribe` for audio files. Copy the folder into `~/.claude/skills/` or `~/.codex/skills/`.

## History and usage

```bash
tmux-whisper last                    # the latest dictation, with timings
tmux-whisper history                 # recent dictations; history N shows one
tmux-whisper history search "invoice"
tmux-whisper history stats
tmux-whisper usage                   # lifetime totals; --json --days N|all for per-day buckets
tmux-whisper bench 20                # stage timings of recent takes
```

- **History** keeps transcripts for `history.retention_days` (7 by default).
- **Usage** is a separate, transcript-free tally of delivered dictations that survives history pruning. It started when the feature was installed and doesn't backfill. Daily buckets started with v0.11.
- **The time-saved figure** is an estimate. It assumes a typing speed (`DICTATE_HISTORY_TYPING_WPM`, 40 by default), and changing it recalculates the estimate without touching the recorded totals.

Most read commands take `--json`. The stable ones are listed in [`docs/CLI_CONTRACTS.md`](docs/CLI_CONTRACTS.md).

## Health checks and repair

```bash
tmux-whisper doctor     # install, config, vocab and daemon, with suggested fixes
tmux-whisper status     # what's running and the effective settings
tmux-whisper version    # CLI version, config schema, running binary, install provenance
tmux-whisper warmup     # start the daemon and load the model
```

If `doctor` reports config drift or invalid TOML:

```bash
tmux-whisper config repair --dry-run
tmux-whisper config repair      # backs up first
```

`tmux-whisper config`, `config get <key>` and `config defaults` show the config without changing it. More fixes, including Khuluma's own messages, are in [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

Khuluma and Finder run the CLI with a minimal environment. Put custom `PATH` entries and `DICTATE_*` overrides in `~/.zshenv` so they apply there too. More in [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Development

- `bin/tmux-whisper`, `bin/tmux-whisper-lib/` and `bin/dictate-lib.sh` hold the CLI (bash).
- `tmux-whisperd/` is the Swift package, with four targets:
  - `TmuxWhisperKit`: the engine, protocol and socket server;
  - `tmux-whisperd`: the daemon;
  - `KhulumaCore`: Khuluma's AppKit-free logic, with most of the tests;
  - `Khuluma`: the app shell.
- The CLI builds the daemon on demand into `~/.local/share/tmux-whisper/native/` and rebuilds it when the sources change.
- `config/` holds the defaults that `install.sh` seeds: config and vocab.
- `tools/` holds the Khuluma build and report scripts and the Homebrew formula updater.
- `docs/plans/` holds the active plan. Finished plans move to `docs/plans/archive/`.

Run the checks before a PR:

```bash
./tests/ci.sh                          # shell syntax, CLI, regression, flow parity, install and bootstrap tests
cd tmux-whisperd && swift test         # Swift tests (KhulumaCore, TmuxWhisperKit)
```

`tests/fixtures/cleanup/` keeps Khuluma's Swift cleanup in step with the CLI's. Regenerate it with `tests/gen-cleanup-fixtures.sh` after changing cleanup. GitHub Actions runs `ci.sh` on every push and pull request.

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers the workflow. [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md) covers releases. [`CHANGELOG.md`](CHANGELOG.md) holds the release notes, with older entries in [`CHANGELOG.archive.md`](CHANGELOG.archive.md). [`ROADMAP.md`](ROADMAP.md) gives the direction.

## Privacy

- **Audio and text** stay on your Mac.
- **What's saved:** history keeps transcripts for the retention period. Before a take reaches history, Khuluma spools its record (text included) to `~/Library/Application Support/Khuluma/pending/`, and removes it once history has it. Saved audio waits in `recovered/` beside it. The usage tally and `app.log` hold counts and timings, never text.
- **The repository** holds no keys or personal settings. Your config is never overwritten by an install.

## License

MIT
