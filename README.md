# Khuluma

Dictation for macOS. Press a key, speak, and the text is pasted into the app in front of you. Parakeet (Swift/CoreML) transcribes locally by default. You can explicitly choose ElevenLabs Scribe v2 in Settings; that sends audio to ElevenLabs and uses your API credits.

**Khuluma** means "speak" in isiNdebele and isiZulu. Current work, installed-state evidence and open gates are in [`LOG.md`](LOG.md). The [archived identity-rename outcome](docs/plans/archive/KHULUMA_IDENTITY_RENAME.md) records the transition from the earlier Tmux Whisper/Lowkey identities. Everything is one Swift package in `native/`:

- **Khuluma** (`native/Sources/Khuluma`): the menu-bar app you dictate with. It owns the hotkey, the microphone, the sounds, cleanup, delivery (paste, optionally send), History, Vocabulary, Stats and Settings, and keeps its data in `~/Library/Application Support/Khuluma`.
- **`khulumad`**: the local Parakeet daemon that keeps the model loaded. The app bundles it and supervises it.
- **`khuluma`** (`native/Sources/khuluma-cli`): a small command bundled in the app, `khuluma transcribe`, for audio files from a terminal or an agent.

The bash `khuluma` CLI, `install.sh` and the Homebrew formula were retired in 2026-11; before that, the tmux pane flow, CLI recording, LLM post-processing, the Raycast scripts and the SwiftBar plugin (see `CHANGELOG.md`).

## Requirements

- macOS 14 or later
- Xcode or the Command Line Tools (`swift`), to build the app

The Parakeet model downloads on first run into FluidAudio's shared cache (`~/Library/Application Support/FluidAudio/Models`).

## Install

Khuluma is built from a clone:

```bash
git clone https://github.com/ricardo-calcina/khuluma.git
cd khuluma
tools/make-signing-identity.sh   # checks the dedicated identity; prints safe creation instructions if absent
tools/build-khuluma-app.sh       # build, sign and install ~/Applications/Khuluma.app
open ~/Applications/Khuluma.app
```

On first launch, allow Microphone and Accessibility (for pasting) in System Settings → Privacy & Security.

After pulling changes, run `tools/build-khuluma-app.sh` again. It requests a graceful quit before replacement and relaunches an app that was running. Khuluma saves queued takes and drains its work; the helper waits up to 60 seconds and refuses replacement if the app stays open. The previous bundle is kept for rollback.

The bundle ID is `com.ricardo-nth.khuluma`, signed with a dedicated `Khuluma Local Code Signing` identity so rebuilds keep the macOS permissions.

## Using Khuluma

Press the hotkey to start, speak after the chime, press it again to stop. Ctrl+Esc cancels a recording. The default hotkey is `ctrl+option+space`; record a new one in **Settings**.

The compact, arrowless menu panel shows words, estimated time saved and words per minute in three centered columns, for all time or today (Settings → Appearance → Menu figures), with an optional 7-day bar strip under them. Click the menu icon again to close it. Recording, processing, warm-up and error notices appear when needed. The Auto-send switch in the footer turns sending on or off. The window icon opens the Khuluma window and the gear opens it on **Settings**. The window has four tabs in its title bar, Stats, History, Vocabulary and Settings (Command-1/2/3/4; Command-comma for Settings; Escape returns to Stats). The **History** tab lists recent dictations by day; search narrows it, and Copy puts a dictation's text back on the clipboard. Dictations are kept for the configured number of days.

**Settings** has seven pages in a sidebar (General, Recording, Sounds, Transcription, Text, Cloud, Advanced). It records a new shortcut from a key press and controls the transcription provider, auto-send, the paste-without-sending key, sounds, Start at Login and diagnostic logging. Open Log, Open Config and Reload Settings live there.

Under **Settings → Transcription → Dictation model**, Parakeet is the default. Selecting **ElevenLabs Scribe v2** sends dictation and saved recordings being recovered to ElevenLabs. **Label sounds** is on by default for Scribe and includes labels such as `(laughter)`. Turn it off for speech only. **Language** offers Auto-detect or a fixed language, with English as the default. You can save the ElevenLabs API key in the macOS Keychain on **Settings → Cloud**.

**Sounds:** Settings → Sounds sets a sound for each moment: recording starts, recording stops, text delivered, cancelled and a problem. Each event can use the bundled default, be silent (None), or play your own file from the sounds folder (Show in Finder opens it; Choose File… copies a file in). Play sounds turns them all off at once. If there is no Keychain key, Khuluma looks for `ELEVENLABS_API_KEY` or `ELEVEN_LABS_API_KEY` in its environment or as a literal export in supported zsh settings without executing those files.

**Delivery:** on Settings → Text, **App rules** let one app always paste without sending, or always send, whatever the Auto-send switch says; the paste-only key still wins everywhere. **Restore clipboard after pasting** puts back what you had copied once the text has pasted; the dictation stays in History.

In Finder, right-click an audio or video file and choose **Transcribe with Local** or **Transcribe with Cloud**. Local uses Parakeet. Cloud asks before uploading the selected files to ElevenLabs, uses your API credits, detects the language and includes sound labels. Either action writes a separate `.txt` beside each file and copies the transcript to the clipboard. The app's bundled file transcription command uses Parakeet.

- **Timed-out takes:** when the daemon times out on a take, its audio is kept privately for an hour. **Retry** transcribes it again, and **Paste retried dictation** pastes it wherever you are, without sending. If Scribe fails, including on a network or authentication error, Khuluma keeps the recording for recovery.
- **Quitting:** a take still recording is saved to disk first, then transcribed into history and copied to the clipboard (never pasted). Takes already stopped and waiting for or in transcription are saved to disk too, and finish as usual. Quit waits up to 30 seconds for all of them. Saved audio and records that haven't reached history by then are finished at the next launch, into history without touching the clipboard. If a take's audio can't be written to disk, Khuluma stays open instead of losing it.
- **Provider failures:** the app keeps the recording for recovery and does not switch providers automatically.

**Paste last dictation:** an optional shortcut (Settings → Recording, off by default) pastes your most recent dictation again, without sending. It waits for the shortcut's own modifier keys to come up first, and Restore clipboard after pasting applies to it too.

**Paste without sending:** with auto-send on, hold Shift as you press the shortcut to finish (for example ⇧F17 or ⌃⌥⇧Space) and that take is pasted without pressing the send key. Choose Option, Control, Command or Off in Settings → Text; the key must not already be part of your shortcut.

**While recording:** Settings → Recording and Settings → Transcription offer five opt-in extras, all off until you switch them on. **Hold to talk** gives you a second shortcut: hold it down to record and release to finish (a tap under a third of a second discards the take; Control–Escape and the menu's Cancel still work). **Mute other audio** silences the Mac's sound output just after the start chime and restores it when the take ends, but only if you haven't changed it yourself in the meantime. **Keep Mac awake** stops the Mac sleeping during long dictation. **Show on-screen indicator** puts a small capsule at the bottom of the screen with a level waveform and elapsed time while recording, and a spinner while transcribing. **Transcribe while recording** (off by default, Parakeet only) cuts the audio at pauses and transcribes each finished part as you speak, so long dictation finishes sooner; the recording is also kept on disk while you speak, so an interrupted take is recovered at the next launch.

**Stats** leads with the same lifetime words, estimated time saved against typing (at 40 wpm by default) and average words per minute, including pauses. A 30/60/90-day activity heatmap and optional words-per-day chart under it sit below, followed by four tiles (current streak, best day, longest take, longest streak), then recording time (all-time and today) and progress toward the next word milestone. The milestone bar shows total words as a share of the next target. Refresh (Command-R) sits beside Settings; the info button opens coverage dates, privacy details and the last update time. Recording time totals audio from delivered dictations; it is separate from estimated time saved. Records cover all available daily history, regardless of the Activity range. It reads the app's `usage.json`, which holds counts and durations only, never what you said.

**Logs:** `~/Library/Logs/Khuluma/app.log` has one `take:` line per take (path, outcome, timings; no text). `tools/khuluma-report.sh` summarises it: outcomes, fallback and failure rates, and where the time goes.

## Vocab

Open **Settings → Text** to turn cleanup on and choose repetition handling: **Repeated sentences** keeps a sentence of five or more words said twice in a row once, and **Repeated words** offers Keep, Single words, or Words and short phrases. The two options combine. The **Vocabulary** tab is one editor with Fillers, Brands, Other words and Examples; an unsaved draft stays while you switch tabs. Add or update individual entries there, or export a JSON file, revise it with an agent and import the updated file. Import shows section totals and added/changed/removed counts, then stages a draft for review. Save Changes applies it to the next take. Undo restores draft edits; Cancel/Escape protects unsaved changes.

**Examples** keep cleanup reliable as the vocabulary grows. Each one is what was said and the text you expect pasted. Typing in Said (or choosing a **Recent** dictation) shows what the current draft gives; Use as Expected copies it. Every example shows a tick or a cross against the draft, live. When a failing example differs by one word or phrase, Add Rule offers the literal Other words rule that fixes it. Saving with failing examples asks first. Examples are stored in `vocabulary.json` but never used as rules. Recent dictations come from history after filler and repetition cleanup, so they test vocabulary spellings rather than filler removal.

Vocabulary corrections and British spelling run by default. Hesitation and repetition cleanup is opt-in. Cleanup removes the unquoted hesitation phrases in Fillers while preserving wording such as “I think”, “actually” and “I mean”. Add observed forms such as `ahhh` or `er` as literal entries; no regular expressions are needed. An empty Fillers section keeps hesitation sounds. Level 3 removes exact adjacent sentences of at least five words (ignoring case and extra spaces), keeping the first copy. It preserves changed wording, short emphasis, and grammatical doubles such as “had had”. It does not summarise, remove non-adjacent repeats, or guess which near-repeat you intended. Sentences need matching punctuation and must fit within 2,002 bytes. Levels 1 and 2 retain the older word/short-phrase stutter cleanup; 0 disables repetition cleanup. Levels 4 and 5 combine the two: sentence cleanup plus single words (4), or sentences plus words and short phrases (5).

`~/Library/Application Support/Khuluma/vocabulary.json` is the single active vocabulary for every app. Before the first save, an older plain-text `vocab` file there is shown instead, its corrections in Other words, and it is kept intact. Earlier JSON versions are retained in `vocabulary-backups/`. Saves refuse to overwrite a newer version written by another agent: export your draft, reload the current version, then review your update again.

The portable file is ordinary JSON, with one heard spelling per entry and no duplicate heard phrases across sections. Matching ignores case. Fillers are removals; Brands and Other words use the same literal replacement behavior. A `pnpm` correction leaves `pnpm-lock.yaml` intact. Files support up to 5,000 entries and 1 MB; each phrase is at most 200 characters on one line.:

```json
{
  "schema_version": 1,
  "fillers": ["um", "uh", "ahhh", "er"],
  "brands": [{"heard": "PN PM", "write": "pnpm"}],
  "words": [{"heard": "source slash", "write": "src/"}]
}
```

## Transcribe audio files

The app bundles a `khuluma transcribe` command. Link it onto your `PATH` once:

```bash
ln -s ~/Applications/Khuluma.app/Contents/Helpers/khuluma ~/.local/bin/khuluma
```

```bash
khuluma transcribe memo.m4a               # raw transcript to stdout
khuluma transcribe memo.m4a -q            # no progress messages on stderr
khuluma transcribe memo.m4a --beside      # writes memo.txt next to it
khuluma transcribe a.m4a b.m4a --format json  # one JSON object per file
khuluma transcribe memo.m4a -o notes.txt  # write to a file
```

- m4a, mp3, wav, aac, flac and video audio tracks work; the original is never modified.
- The output is the **raw** transcript: no dictation cleanup. File transcripts aren't counted in usage or written to history.
- While the app runs, its daemon does the work, and dictation waits while a long file is transcribing.
- Output files are never overwritten without `--force`.

**Finder:** right-click audio or video files and choose **Transcribe with Local** or **Transcribe with Cloud** (described above).

**Agents:** `integrations/agents/transcribe-audio/SKILL.md` tells Claude Code and Codex to use `khuluma transcribe` for audio files. Copy the folder into `~/.claude/skills/` or `~/.codex/skills/`.

## History and usage

- **History** keeps transcripts for `history.retention_days` (7 by default).
- **Audio:** with `debug.keep_logs` enabled, successful takes keep their working WAV until history is saved, then delete it directly. A separate audio archive remains for `history.audio_retention_days` (2 by default). On the next dictation, archives older than the configured retention period (48 hours by default) are deleted directly to free storage. Failed history writes keep the handed-over working audio for retry. With debug audio disabled, native transcription uses temporary WAVs without an audio archive.
- **Usage** is a separate, transcript-free tally of delivered dictations that survives history pruning. It started when the feature was installed and doesn't backfill. Daily buckets started with v0.10.0.
- **The time-saved figure** is an estimate. It assumes a typing speed (`history.typing_wpm` in settings.json, 40 by default), and changing it recalculates the estimate without touching the recorded totals.

More fixes are in [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md); the integrations are in [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Development

- `native/` holds the Swift package. Its main targets are:
  - `KhulumaDaemonKit`: the engine, protocol and socket server;
  - `khulumad`: the daemon;
  - `KhulumaCore`: Khuluma's AppKit-free logic, with most of the tests;
  - `Khuluma`: the app shell;
  - `khuluma-cli`: the bundled `khuluma transcribe` helper.
- `native/VERSION` is the app version.
- `tools/` holds the app build, signing check, icon and log-report scripts, and `test-affected.sh`.
- `tests/fixtures/` holds frozen golden files the Swift tests read (cleanup, settings, usage and vocabulary parity with the retired CLI); `tests/` also holds the Python tests for the build script and `test_affected.py`.
- `LOG.md` holds current tasks and decisions. Historical plans remain under `docs/archive/` and `docs/plans/archive/`.

```bash
tools/test-affected.sh          # the checks your change affects
tools/test-affected.sh --full   # the full Swift suite
./tests/ci.sh                   # repo tool checks
```

GitHub Actions runs the Swift suite (`swift.yml`), the repo tool checks (`ci.yml`) and the icon checks (`icons.yml`).

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers the workflow. [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md) covers releases. [`CHANGELOG.md`](CHANGELOG.md) holds the release notes, with older entries in [`CHANGELOG.archive.md`](CHANGELOG.archive.md). [`ROADMAP.md`](ROADMAP.md) gives the direction.

## Privacy

- **Audio and text** stay on your Mac.
- **What's saved:** history keeps transcripts for the retention period. Before a take reaches history, Khuluma spools its record (text included) to `~/Library/Application Support/Khuluma/pending/`, and removes it once history has it. Saved audio waits in `recovered/` beside it. The usage tally and `app.log` hold counts and timings, never text.
- **The repository** holds no keys or personal settings. Your settings are never overwritten by a build or install.

## License

MIT
