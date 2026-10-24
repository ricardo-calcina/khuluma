# Troubleshooting

Use this page for quick diagnosis and high-confidence fixes.

## 1) Run the health checks

```bash
khuluma doctor
khuluma status
```

- `doctor`: install/dependency/vocab/runtime checks with suggested fixes
- `status`: current runtime + effective settings snapshot

## 2) Khuluma

Khuluma shows errors on its menu's first line, and logs each one in `~/Library/Logs/Khuluma/app.log` (**Open Log** in the menu). `tools/khuluma-report.sh` summarises recent takes without printing any text.

**"khuluma … is older than this Khuluma: run ./install.sh --force"**, or **"this Khuluma … is older than khuluma …: rebuild it with tools/build-khuluma-app.sh"**
- The CLI and the app come from different checkouts, so their app contracts differ, and Khuluma takes no dictation until they match. If the mismatch is found at launch, the hotkey isn't registered at all; if it's found later (a reinstall while Khuluma runs), the hotkey plays the error sound and shows this message. A take that was already recording is saved, and recovered at a later launch with a matching CLI.
- After fixing it, choose **Reload Settings** or relaunch Khuluma.
- Fix: from the same checkout, run `./install.sh --force` and `tools/build-khuluma-app.sh`.

**"khuluma CLI not found"**
- Khuluma looks in `~/.local/bin` and Homebrew's `bin`.
- Fix: run `./install.sh`, then relaunch Khuluma.

**"Accessibility permission missing: text is on the clipboard"**
- Fix: in System Settings → Privacy & Security → Accessibility, turn Khuluma on. The text of that take is on the clipboard; paste it by hand.
- Rebuilding with a different signing identity resets the permission. Use `tools/make-signing-identity.sh` once, so rebuilds keep it.

**The start chime plays, but nothing is recorded ("no audio captured")**
- Check Microphone permission for Khuluma (Privacy & Security → Microphone).
- After switching microphones or headphones, Khuluma restarts its audio engine for the new input. `app.log` shows the input in use (`audio: input is …`).

**"Parakeet: unavailable" or "warming up" in the menu, or slow first takes**
- Fix: run `khuluma warmup`, then `khuluma doctor` to see what's wrong with the daemon or model ("Parakeet backend unavailable" in section 3).
- Supervision (`[app] supervise_daemon = true`, the default) keeps the model warm at launch, on wake and when a recording starts.

**"transcription timed out … (Retry in the menu)"**
- The daemon didn't answer in time. The audio is kept for an hour. **Retry** transcribes it again; then **Paste retried dictation** pastes it where you are, without sending.
- A timeout on the CLI fallback ("khuluma did not answer within Ns") keeps no audio, so there's nothing to retry.

**"Khuluma was in front: text is on the clipboard"**
- Khuluma never pastes into its own windows (e.g. Stats). Paste the text by hand.

**Text pasted but not sent, or sent with the wrong key**
- Check `khuluma autosend` and `khuluma send-mode`.
- If config.toml doesn't parse, Khuluma warns in the menu and uses the last valid settings, or, with none, the defaults with paste-only delivery. Fix the file (section 3), then **Reload Settings**.

## 3) Setup and config issues

Which install are you actually running?

- Use `khuluma doctor`.
- Check the resolved binary path and install channel before assuming the wrong copy is broken.

Upgrade or refresh by channel:

- Homebrew stable:

```bash
brew upgrade khuluma
khuluma doctor
khuluma status
```

- Bootstrap install:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-calcina/khuluma/main/bootstrap.sh | bash -s -- --force
khuluma doctor
khuluma status
```

- Local clone:

```bash
git pull
./install.sh --force
khuluma doctor
khuluma status
```

`--force` refreshes binaries but preserves your live config and vocab.

Schema mismatch:

- Symptom in `khuluma doctor`: `config schema: ... status=mismatch`
- Fix:

```bash
khuluma config repair --dry-run
khuluma config repair
```

Invalid TOML:

- Symptoms:
  - `khuluma doctor`: `config schema: invalid`
  - `khuluma status`: `headline: Config file is invalid TOML.`
- Fix:

```bash
khuluma config repair --dry-run
khuluma config repair
```

Missing dependencies:

- `python3` and `ffmpeg` are required.
- `swift` is required when the local `khulumad` binary needs to be built or rebuilt.
- Typical Homebrew installs:

```bash
brew install python ffmpeg
```

Parakeet backend unavailable:

- Symptoms in `khuluma doctor`:
  - `khulumad binary: ... (build needed)`
  - `khulumad socket: ... (offline)`
  - `parakeet model: missing`
- Fix:
  - run `./install.sh --force`
  - run `khuluma warmup`
  - verify `swift_parakeet.model_path` in `~/.config/khuluma/config.toml`
  - ensure `swift` is installed if the native backend needs to rebuild
  - if you keep models outside the default location, set `swift_parakeet.model_path` explicitly

## 4) Old modes

Modes were removed in v0.11: every take uses `~/.config/khuluma/vocab`.

- Symptom in `khuluma doctor`: `modes/: found but no longer read`, or `khuluma mode` fails with "modes were removed in v0.11".
- Fix: fold the old `modes/*/vocab` into `vocab` and archive the rest (`./install.sh` does this too):

```bash
khuluma migrate-modes --dry-run
khuluma migrate-modes
```

A rule whose wrong words are already in `vocab` with a different correction is skipped and listed; `vocab` keeps its own. `--skip <mode>` leaves a whole mode's rules out (they are still archived). Nothing is deleted: `modes/`, `current-mode` and a copy of the previous `vocab` go to `~/.config/khuluma/modes-archive/<date>-modes-removed/`.

If it stops with "not valid UTF-8" or "is a symlink", nothing was changed: fix that file (or move the linked `modes/` out of `~/.config/khuluma` and import its vocab with `khuluma vocab import <file>`), then run it again.

## 5) Vocabulary workflow issues

Accepted correction formats:

- `wrong::right`
- `wrong -> right`
- `wrong → right`

Invalid import lines:

- `khuluma vocab import <file>` now reports line numbers for invalid entries (first 5).
- Preview a batch without mutating your live vocab:

```bash
khuluma vocab import --dry-run <file>
```

- Clean and normalize existing vocab safely:

```bash
khuluma vocab dedupe
```

This writes a timestamped backup before rewrite.

Export a clean snapshot for sharing/versioning:

```bash
khuluma vocab export <file>
```

Remove entries safely:

```bash
khuluma vocab rm "literal text"
khuluma vocab rm --regex "pattern"
```

## 6) Environment and retired integrations

- Khuluma and the Finder Quick Action run the CLI in a minimal environment. If custom PATH entries or env-based overrides work in your shell but not from them, put them in `~/.zshenv`.
- The Raycast scripts and the SwiftBar plugin were retired; Khuluma replaces them. Old copies may remain under `~/.config/dictate/integrations/raycast` or `~/.config/swiftbar/plugins/tmux-whisper-status.0.2s.sh`. These legacy filenames are not active Khuluma integrations.
