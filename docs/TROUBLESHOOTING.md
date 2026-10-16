# Troubleshooting

Use this page for quick diagnosis and high-confidence fixes.

## 1) Run the health checks

```bash
tmux-whisper doctor
tmux-whisper status
```

- `doctor`: install/dependency/mode/runtime checks with suggested fixes
- `status`: current runtime + effective settings snapshot

## 2) Lowkey

Lowkey shows errors on its menu's first line, and logs each one in `~/Library/Logs/Lowkey/app.log` (**Open Log** in the menu). `tools/lowkey-report.sh` summarises recent takes without printing any text.

**"tmux-whisper … is older than this Lowkey: run ./install.sh --force"**, or **"this Lowkey … is older than tmux-whisper …: rebuild it with tools/build-lowkey-app.sh"**
- The CLI and the app come from different checkouts, so their app contracts differ. Until they match, the hotkey plays the error sound and shows this message instead of recording. A take that was already recording is saved, and recovered at a later launch with a matching CLI.
- Fix: from the same checkout, run `./install.sh --force` and `tools/build-lowkey-app.sh`.

**"tmux-whisper CLI not found"**
- Lowkey looks in `~/.local/bin` and Homebrew's `bin`.
- Fix: run `./install.sh`, then relaunch Lowkey.

**"Accessibility permission missing: text is on the clipboard"**
- Fix: in System Settings → Privacy & Security → Accessibility, turn Lowkey on. The text of that take is on the clipboard; paste it by hand.
- Rebuilding with a different signing identity resets the permission. Use `tools/make-signing-identity.sh` once, so rebuilds keep it.

**The start chime plays, but nothing is recorded ("no audio captured")**
- Check Microphone permission for Lowkey (Privacy & Security → Microphone).
- After switching microphones or headphones, Lowkey restarts its audio engine for the new input. `app.log` shows the input in use (`audio: input is …`).

**"Parakeet: unavailable" or "warming up" in the menu, or slow first takes**
- Fix: run `tmux-whisper warmup`, then `tmux-whisper doctor` to see what's wrong with the daemon or model ("Parakeet backend unavailable" in section 3).
- Supervision (`[app] supervise_daemon = true`, the default) keeps the model warm at launch, on wake and when a recording starts.

**"transcription timed out … (Retry in the menu)"**
- The audio is kept for an hour. **Retry** transcribes it again; then **Paste retried dictation** pastes it where you are, without sending.

**"Lowkey was in front: text is on the clipboard"**
- Lowkey never pastes into its own windows (e.g. Stats). Paste the text by hand.

**Text pasted but not sent, or sent with the wrong key**
- Check `tmux-whisper autosend` and `tmux-whisper send-mode`.
- If config.toml doesn't parse, Lowkey warns in the menu and uses the last valid settings, or, with none, the defaults with paste-only delivery. Fix the file (section 3), then **Reload Settings**.

**A mode never applies**
- A mode whose `flows` file says only `tmux` is hidden from Lowkey; `tmux-whisper doctor` flags it.
- Fix: `tmux-whisper mode flows <name> inline`.

## 3) Setup and config issues

Which install are you actually running?

- Use `tmux-whisper doctor`.
- Check the resolved binary path and install channel before assuming the wrong copy is broken.

Upgrade or refresh by channel:

- Homebrew stable:

```bash
brew upgrade tmux-whisper
tmux-whisper doctor
tmux-whisper status
```

- Bootstrap install:

```bash
curl -fsSL https://raw.githubusercontent.com/ricardo-nth/tmux-whisper/main/bootstrap.sh | bash -s -- --force
tmux-whisper doctor
tmux-whisper status
```

- Local clone:

```bash
git pull
./install.sh --force
tmux-whisper doctor
tmux-whisper status
```

`--force` refreshes binaries but preserves your live config, modes, and vocab.

Schema mismatch:

- Symptom in `tmux-whisper doctor`: `config schema: ... status=mismatch`
- Fix:

```bash
tmux-whisper config repair --dry-run
tmux-whisper config repair
```

Invalid TOML:

- Symptoms:
  - `tmux-whisper doctor`: `config schema: invalid`
  - `tmux-whisper status`: `headline: Config file is invalid TOML.`
- Fix:

```bash
tmux-whisper config repair --dry-run
tmux-whisper config repair
```

Missing dependencies:

- `python3` and `ffmpeg` are required.
- `swift` is required when the local `tmux-whisperd` binary needs to be built or rebuilt.
- Typical Homebrew installs:

```bash
brew install python ffmpeg
```

Parakeet backend unavailable:

- Symptoms in `tmux-whisper doctor`:
  - `tmux-whisperd binary: ... (build needed)`
  - `tmux-whisperd socket: ... (offline)`
  - `parakeet model: missing`
- Fix:
  - run `./install.sh --force`
  - run `tmux-whisper warmup`
  - verify `swift_parakeet.model_path` in `~/.config/dictate/config.toml`
  - ensure `swift` is installed if the native backend needs to rebuild
  - if you keep models outside the default location, set `swift_parakeet.model_path` explicitly

## 4) Mode configuration issues

Invalid fixed mode fallback:

- Symptom: `mode.current: <name> (invalid, fallback=auto)`
- Fix either:
  - reset to auto-detect: `tmux-whisper mode auto`
  - create missing custom mode: `tmux-whisper mode create "<name>"`

If the core modes (`base`, `code`) are missing after install drift, reinstall to seed them:

```bash
./install.sh --force
```

## 5) Vocabulary workflow issues

Accepted correction formats:

- `wrong::right`
- `wrong -> right`
- `wrong → right`

Invalid import lines:

- `tmux-whisper vocab import <file>` now reports line numbers for invalid entries (first 5).
- Preview a batch without mutating your live vocab:

```bash
tmux-whisper vocab import --dry-run <file>
```

- Clean and normalize existing vocab safely:

```bash
tmux-whisper vocab dedupe
```

This writes a timestamped backup before rewrite.

Export a clean snapshot for sharing/versioning:

```bash
tmux-whisper vocab export <file>
```

Remove entries safely:

```bash
tmux-whisper vocab rm "literal text"
tmux-whisper vocab rm --regex "pattern"
```

## 6) Environment and retired integrations

- Lowkey and the Finder Quick Action run the CLI in a minimal environment. If custom PATH entries or env-based overrides work in your shell but not from them, put them in `~/.zshenv`.
- The Raycast scripts and the SwiftBar plugin were retired in v0.11 (Lowkey replaces them). Old copies under `~/.config/dictate/integrations/raycast` or `~/.config/swiftbar/plugins/tmux-whisper-status.0.2s.sh` can go to the Trash.
