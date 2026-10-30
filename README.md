# Khuluma

Dictation for macOS. Press a key, speak, and the text is pasted into the app in front of you. Parakeet (Swift/CoreML) transcribes locally by default. You can explicitly choose ElevenLabs Scribe v2 in Settings; that sends audio to ElevenLabs and uses your API credits.

**Khuluma** means "speak" in isiNdebele and isiZulu. Current work, installed-state evidence and open gates are in [`LOG.md`](LOG.md). The [archived identity-rename outcome](docs/plans/archive/KHULUMA_IDENTITY_RENAME.md) records the transition from the earlier Tmux Whisper/Lowkey identities. The project has three parts:

- **Khuluma** (`native/Sources/Khuluma`): the menu-bar app you dictate with. It owns the hotkey, the microphone, the sounds, delivery (paste, optionally send) and the Stats window. It transcribes over the daemon's socket and cleans the text up in Swift.
- **`khulumad`**: the local Parakeet daemon that keeps the model loaded.
- **The `khuluma` CLI** (`bin/`): Khuluma's back end for now. It holds config, vocab, history and usage, starts and warms the daemon, and transcribes audio files. Khuluma calls it through a small set of JSON commands ([`docs/CLI_CONTRACTS.md`](docs/CLI_CONTRACTS.md)).

The tmux pane flow, CLI recording, LLM post-processing, the Raycast scripts and the SwiftBar plugin were removed from the current code (see `CHANGELOG.md`).

## Requirements

- macOS 14 or later
- `python3` 3.11+ (for `tomllib`) and `ffmpeg`
- Xcode or the Command Line Tools (`swift`), to build the daemon and Khuluma
- A Parakeet CoreML model on disk, at `~/.local/share/khuluma/models/parakeet-tdt-0.6b-v3-coreml` (or `-v2-coreml`), or anywhere `swift_parakeet.model_path` in the config points. Install doesn't download it; FluidInference publishes these CoreML conversions on Hugging Face. A v3 folder needs `JointDecisionv3.mlmodelc` (FluidAudio 0.15.6); download again if yours only has `JointDecision.mlmodelc`. FluidAudio's own cache works too: point `model_path` at `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` to share one copy with other FluidAudio apps.

## Source and installed runtime

A checkout is separate from the installed app and daemon. `tools/build-khuluma-app.sh` builds `native/` in retained private scratch space and installs `~/Applications/Khuluma.app`; the CLI's default installed daemon is `~/.local/share/khuluma/native/khulumad/.build/release/khulumad`. Config or environment overrides may change daemon paths. Preserve build trees, models and caches during documentation housekeeping. The install and build commands below change the runtime; they are not documentation checks.

## Install

Khuluma is built from a clone, and it needs the CLI from the same checkout: the two share an app contract number, and Khuluma refuses takes from a CLI with a different one.

For an older Tmux Whisper/Lowkey installation, start with [Identity migration](docs/INTEGRATIONS.md#identity-migration) before running the installation commands below.

```bash
git clone https://github.com/ricardo-calcina/khuluma.git
cd khuluma
./install.sh                     # the CLI, default config, vocab and sounds
tools/make-signing-identity.sh   # checks the dedicated identity; prints safe creation instructions if absent
tools/build-khuluma-app.sh        # build, sign and install ~/Applications/Khuluma.app
open ~/Applications/Khuluma.app
```

On first launch, allow Microphone and Accessibility (for pasting) in System Settings → Privacy & Security.

After pulling changes in an already canonical installation, refresh both. For an older Tmux Whisper/Lowkey installation, use the identity migration procedure below first:

```bash
git pull
./install.sh --force
tools/build-khuluma-app.sh
```

`build-khuluma-app.sh` requests a graceful quit before replacement and relaunches an app that was running. Khuluma saves queued takes and drains its work; the helper waits up to 60 seconds and refuses replacement if the app stays open.

**Upgrading an older Tmux Whisper/Lowkey installation:** follow [Identity migration](docs/INTEGRATIONS.md#identity-migration). From the canonical checkout, `tools/migrate-khuluma-identity.sh --help` and `--dry-run` inspect the data transition without changing it. The tool is a data engine; this release does not include a portable automated coordinator for app, CLI, daemon, login and Finder cutover. Its apply/resume/rollback operations require proof from an active, reviewed operator/agent-controlled session. Do not fabricate receipts or use `install.sh --force` to bypass that requirement. Keep the working old runtime until that coordinated handoff is prepared. A legacy default is detected rather than silently replaced with an empty profile.

The new bundle ID is `com.ricardo-nth.khuluma`, signed with a separate `Khuluma Local Code Signing` identity. macOS may require Microphone/Accessibility approval and a Start at Login retoggle; permission carryover is verified on the actual Mac, not assumed. Starting with v0.11.0, normal startup no longer imports Lowkey folders or preference keys. Complete the v0.10.0 coordinated transition first when coming from those older identities; keep all original folders and preference domains until verified.

`install.sh` keeps your config, vocab and sounds, including with `--force`, which only refreshes the scripts and adds missing defaults. Other flags: `--no-sounds`, `--with-sounds`, `--replace-sounds` (overwrite your sound files with the bundled ones). It ends with a daemon warm-up, and writes an install receipt to `~/.config/khuluma/install-receipt.env`.

**CLI only:** the published Homebrew formula (`brew install ricardo-calcina/tap/khuluma`) and `bootstrap.sh` install the CLI without the app. They are for file transcription, or a pinned CLI on another machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-calcina/khuluma/main/bootstrap.sh | bash -s -- --ref v0.11.0 --force
```

v0.11.0 exposes the `khuluma` command and `KHULUMA_*` application overrides; standard XDG roots and existing generic overrides such as `SOUNDS_DIR` remain supported. The `tmux-whisper` forwarding command and its older doctor JSON adapter are removed. Rename old environment overrides before updating; obsolete names are rejected before writes, including empty assignments. `khuluma doctor --json` remains schema 2. The local installer retires only the verified v0.10.0 owned shim recoverably and refuses an unknown file at that path.

Canonical config and sounds live at: `~/.config/khuluma` and `~/.local/share/sounds/khuluma`.

## Using Khuluma

Press the hotkey to start, speak after the chime, press it again to stop. Ctrl+Esc cancels a recording. The default hotkey is `ctrl+option+space`; record a new one in **Settings**, or edit `~/.config/khuluma/config.toml` and choose **Reload Settings** there:

```toml
[app]
hotkey = "ctrl+option+space"   # e.g. "cmd+shift+d", "f13"
supervise_daemon = true        # keep the Parakeet daemon warm (launch, wake, recording start)
```

The compact, arrowless menu panel shows words, estimated time saved and words per minute in three centered columns, for all time or today (Settings → Appearance → Menu figures), with an optional 7-day bar strip under them. Click the menu icon again to close it. Recording, processing, warm-up and error notices appear when needed. The Auto-send switch in the footer turns sending on or off. The window icon opens the Khuluma window and the gear opens it on **Settings**. The window has three tabs in its title bar, Stats, Vocabulary and Settings (Command-1/2/3; Command-comma for Settings; Escape returns to Stats).

**Settings** records a new shortcut from a key press and controls the transcription provider, auto-send, the paste-without-sending key, sounds, Start at Login and diagnostic logging. Open Log, Open Config and Reload Settings live there. Scribe reads `ELEVENLABS_API_KEY` from the environment or a literal `export ELEVENLABS_API_KEY=...` in your `.zshrc` (including `ZDOTDIR` and `~/.config/zsh`). It never executes the interactive shell or displays the key. Selecting Scribe applies to dictation, saved-recording recovery and file transcription; Parakeet remains the default. With Scribe selected, **Language** offers Auto-detect or a fixed language (`[transcription] language` in config; `KHULUMA_LANGUAGE` still overrides it). English is the default.

- **Timed-out takes:** when the daemon times out on a take, its audio is kept privately for an hour. **Retry** transcribes it again, and **Paste retried dictation** pastes it wherever you are, without sending. Failed CLI/cloud takes are saved for recovery, including failed network or authentication requests.
- **Quitting:** a take still recording is saved to disk first, then transcribed into history and copied to the clipboard (never pasted). Takes already stopped and waiting for or in transcription are saved to disk too, and finish as usual. Quit waits up to 30 seconds for all of them. Saved audio and records that haven't reached history by then are finished at the next launch, into history without touching the clipboard. If a take's audio can't be written to disk, Khuluma stays open instead of losing it.
- **Fallback:** if the daemon can't be reached, the take goes through `khuluma inline process` instead. The same happens when the CLI runs in a non-C locale.

**Paste without sending:** with auto-send on, hold Shift as you press the shortcut to finish (for example ⇧F17 or ⌃⌥⇧Space) and that take is pasted without pressing the send key. Choose Option, Control, Command or Off in Settings → Dictation; the key must not already be part of your shortcut.

**Delivery settings** live in the CLI:

```bash
khuluma autosend on|off            # paste and press the send key, or paste only
khuluma send-mode enter|ctrl_j|cmd_enter
khuluma target origin|current      # the app in front at the start of recording, or at the end
khuluma sound start|stop|process|error on|off
```

**Stats** leads with the same lifetime words, estimated time saved against typing (at 40 wpm by default) and average words per minute, including pauses. A 30/60/90-day activity heatmap and optional words-per-day chart sit below, followed by a quiet current streak line, dated records for best day/longest take/longest streak, recording time (all-time and today), and progress toward the next word milestone. These three sections share the normal window's height without scrolling. The milestone bar shows total words as a share of the next target. Refresh (Command-R) sits beside Settings; the info button opens coverage dates, privacy details and the last update time. Recording time totals audio from delivered dictations; it is separate from estimated time saved. Records cover all available daily history, regardless of the Activity range. It reads `khuluma usage --json --days all`, which holds counts and durations only, never what you said.

**Logs:** `~/Library/Logs/Khuluma/app.log` has one `take:` line per take (path, outcome, timings; no text). `tools/khuluma-report.sh` summarises it: outcomes, fallback and failure rates, and where the time goes.

## Vocab

Open **Settings → Cleanup & vocabulary** to turn cleanup on and choose repetition handling. The **Vocabulary** tab is one editor with Fillers, Brands, Other words and Examples; an unsaved draft stays while you switch tabs. Add or update individual entries there, or export a JSON file, revise it with an agent and import the updated file. Import shows section totals and added/changed/removed counts, then stages a draft for review. Save Changes applies it to the next take. Undo restores draft edits; Cancel/Escape protects unsaved changes.

**Examples** keep cleanup reliable as the vocabulary grows. Each one is what was said and the text you expect pasted. Typing in Said (or choosing a **Recent** dictation) shows what the current draft gives; Use as Expected copies it. Every example shows a tick or a cross against the draft, live. When a failing example differs by one word or phrase, Add Rule offers the literal Other words rule that fixes it. Saving with failing examples asks first. Examples are stored in `vocabulary.json` but never used as rules. Recent dictations come from history after filler and repetition cleanup, so they test vocabulary spellings rather than filler removal.

Vocabulary corrections and British spelling run by default. Hesitation and repetition cleanup is opt-in. The same settings can be set in `~/.config/khuluma/config.toml`:

```toml
[clean]
enabled = true
repeats_level = 3
```

This removes the unquoted hesitation phrases in Fillers while preserving wording such as “I think”, “actually” and “I mean”. Add observed forms such as `ahhh` or `er` as literal entries; no regular expressions are needed. An empty Fillers section keeps hesitation sounds. Level 3 removes exact adjacent sentences of at least five words (ignoring case and extra spaces), keeping the first copy. It preserves changed wording, short emphasis, and grammatical doubles such as “had had”. It does not summarise, remove non-adjacent repeats, or guess which near-repeat you intended. Sentences need matching punctuation and must fit within 2,002 bytes. Levels 1 and 2 retain the older word/short-phrase stutter cleanup; 0 disables repetition cleanup. `KHULUMA_CLEAN=0|1` overrides `clean.enabled`; `KHULUMA_REPEATS_LEVEL` overrides the configured level.

The first save creates `~/.config/khuluma/vocabulary.json` as the single active vocabulary for every app. The previous `vocab` file is retained intact; its corrections initially appear in Other words. Earlier JSON versions are retained in `vocabulary-backups/`. Saves refuse to overwrite a newer version written by another agent: export your draft, reload the current version, then review your update again.

The portable file is ordinary JSON, with one heard spelling per entry and no duplicate heard phrases across sections. Matching ignores case. Fillers are removals; Brands and Other words use the same literal replacement behavior. A `pnpm` correction leaves `pnpm-lock.yaml` intact. Files support up to 5,000 entries and 1 MB; each phrase is at most 200 characters on one line. See [the example](config/vocabulary.example.json):

```json
{
  "schema_version": 1,
  "fillers": ["um", "uh", "ahhh", "er"],
  "brands": [{"heard": "PN PM", "write": "pnpm"}],
  "words": [{"heard": "source slash", "write": "src/"}]
}
```

Before the first JSON save, the existing text vocabulary and its CLI editing commands still work. Once JSON is active, these old editing commands refuse to change the inactive text file; use Settings or the revision-checked `vocab-sheet` API in [CLI contracts](docs/CLI_CONTRACTS.md).

```bash
khuluma vocab add "clawed::Claude"     # also "wrong -> right"
khuluma vocab add "Kaluma::Khuluma" "khuluma::Khuluma"
khuluma vocab add "PN PM::pnpm" "pnpm::pnpm"
khuluma vocab add "X code::Xcode" "xcode::Xcode"
khuluma vocab import --dry-run fixes.txt
khuluma vocab dedupe                   # backs up first
khuluma vocab rm "literal text"        # --regex to match a pattern
```

Modes were removed in v0.10.0. If an older install left `modes/` or `current-mode` in `~/.config/khuluma`, `./install.sh` folds each `modes/*/vocab` into `vocab` (skipping rules it already has) and moves the old files to `modes-archive/`. To run it yourself, or preview it first:

```bash
khuluma migrate-modes --dry-run
khuluma migrate-modes --skip code   # leave a mode's rules out (still archived)
```

## Transcribe audio files

Voice memos use the selected transcription provider:

```bash
khuluma transcribe memo.m4a               # raw transcript to stdout
khuluma transcribe memo.m4a --beside      # writes memo.txt next to it
khuluma transcribe memo.m4a -c            # also copy to the clipboard
khuluma transcribe *.m4a --out-dir notes/ # one .txt per file
khuluma transcribe memo.m4a --format json # text + durations + model
khuluma transcribe - < memo.m4a           # read from stdin
```

- Anything ffmpeg can decode works (m4a, mp3, wav, aac, flac, ogg/opus, video audio tracks). The original is never modified.
- The output is the **raw** transcript: no dictation cleanup. File transcripts aren't counted in `usage` or written to history.
- Parakeet chunks long recordings itself: a 10-minute memo took about 15 seconds on an M1 Air with the model warm. Dictation waits while a long file is transcribing.
- Output files are never overwritten without `--force`, and failures leave no partial output.

**Finder:** `khuluma finder install` adds Quick Actions → "Transcribe with Khuluma". It writes `<name>.txt` next to each selected file, copies the text and posts a notification. Remove it with `khuluma finder remove`.

**Agents:** `integrations/agents/transcribe-audio/SKILL.md` tells Claude Code and Codex to use `khuluma transcribe` for audio files. Copy the folder into `~/.claude/skills/` or `~/.codex/skills/`.

## History and usage

```bash
khuluma last                    # the latest dictation, with timings
khuluma history                 # recent dictations; history N shows one
khuluma history search "invoice"
khuluma history stats
khuluma usage                   # lifetime totals; --json --days N|all for per-day buckets
khuluma bench 20                # stage timings of recent takes
```

- **History** keeps transcripts for `history.retention_days` (7 by default).
- **Audio:** with `debug.keep_logs` enabled, successful takes keep their working WAV until history is saved, then delete it directly. A separate audio archive remains for `history.audio_retention_days` (2 by default). On the next dictation, archives older than the configured retention period (48 hours by default) are deleted directly to free storage. Failed history writes keep the handed-over working audio for retry. With debug audio disabled, native transcription uses temporary WAVs without an audio archive.
- **Usage** is a separate, transcript-free tally of delivered dictations that survives history pruning. It started when the feature was installed and doesn't backfill. Daily buckets started with v0.10.0.
- **The time-saved figure** is an estimate. It assumes a typing speed (`KHULUMA_HISTORY_TYPING_WPM`, 40 by default), and changing it recalculates the estimate without touching the recorded totals.

Most read commands take `--json`. The stable ones are listed in [`docs/CLI_CONTRACTS.md`](docs/CLI_CONTRACTS.md).

## Health checks and repair

```bash
khuluma doctor     # install, config, vocab and daemon, with suggested fixes
khuluma status     # what's running and the effective settings
khuluma version    # CLI version, config schema, running binary, install provenance
khuluma warmup     # start the daemon and load the model
```

If `doctor` reports config drift or invalid TOML:

```bash
khuluma config repair --dry-run
khuluma config repair      # backs up first
```

`khuluma config`, `config get <key>` and `config defaults` show the config without changing it. More fixes, including Khuluma's own messages, are in [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

Khuluma and Finder run the CLI with a minimal environment. Put custom `PATH` entries and `KHULUMA_*` overrides in `~/.zshenv` so they apply there too. More in [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Development

- `bin/khuluma`, `bin/khuluma-lib/` and `bin/khuluma-lib.sh` hold the CLI (bash).
- `native/` holds the Swift package. Its main targets are:
  - `KhulumaDaemonKit`: the engine, protocol and socket server;
  - `khulumad`: the daemon;
  - `KhulumaCore`: Khuluma's AppKit-free logic, with most of the tests;
  - `Khuluma`: the app shell.
- The CLI builds the daemon on demand into `~/.local/share/khuluma/native/` and rebuilds it when the sources change.
- `config/` holds the defaults that `install.sh` seeds: config and vocab.
- `tools/` holds the Khuluma build and report scripts and the Homebrew formula updater.
- `LOG.md` holds current tasks and decisions. Historical plans remain under `docs/archive/` and `docs/plans/archive/`; the dated name check remains under `docs/plans/`.

For changes affecting the CLI or Swift behavior, use the applicable checks:

```bash
./tests/ci.sh                          # shell syntax, CLI, regression, flow parity, install and bootstrap tests
cd native && swift test         # Swift tests (KhulumaCore, KhulumaDaemonKit)
```

`tests/fixtures/cleanup/` keeps Khuluma's Swift cleanup in step with the CLI's. Regenerate it with `tests/gen-cleanup-fixtures.sh` after changing cleanup. GitHub Actions runs `ci.sh` on every push and pull request.

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers the workflow. [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md) covers releases. [`CHANGELOG.md`](CHANGELOG.md) holds the release notes, with older entries in [`CHANGELOG.archive.md`](CHANGELOG.archive.md). [`ROADMAP.md`](ROADMAP.md) gives the direction.

## Privacy

- **Audio and text** stay on your Mac.
- **What's saved:** history keeps transcripts for the retention period. Before a take reaches history, Khuluma spools its record (text included) to `~/Library/Application Support/Khuluma/pending/`, and removes it once history has it. Saved audio waits in `recovered/` beside it. The usage tally and `app.log` hold counts and timings, never text.
- **The repository** holds no keys or personal settings. Your config is never overwritten by an install.

## License

MIT
