# Troubleshooting

Use this page for quick diagnosis and high-confidence fixes.

## Khuluma

Khuluma shows errors on its menu's first line, and logs each one in `~/Library/Logs/Khuluma/app.log` (**Open Log** in the menu). `tools/khuluma-report.sh` summarises recent takes without printing any text.

**"Accessibility permission missing: text is on the clipboard"**
- Fix: in System Settings → Privacy & Security → Accessibility, turn Khuluma on. The text of that take is on the clipboard; paste it by hand.
- Rebuilding with a different signing identity resets the permission. Use `tools/make-signing-identity.sh` once, so rebuilds keep it.

**The start chime plays, but nothing is recorded ("no audio captured")**
- Check Microphone permission for Khuluma (Privacy & Security → Microphone).
- After switching microphones or headphones, Khuluma restarts its audio engine for the new input. `app.log` shows the input in use (`audio: input is …`).

**"Parakeet: unavailable" or "warming up" in the menu, or slow first takes**
- On first run the app downloads the Parakeet model into FluidAudio's cache; the menu shows the progress, and takes made meanwhile are kept and recovered once it's ready.
- Supervision (on by default) keeps the bundled daemon warm at launch, on wake and when a recording starts. `app.log` shows `daemon:` lines when it can't start or load the model.

**"transcription timed out … (Retry in the menu)"**
- The daemon didn't answer in time. The audio is kept for an hour. **Retry** transcribes it again; then **Paste retried dictation** pastes it where you are, without sending.

**"Khuluma was in front: text is on the clipboard"**
- Khuluma never pastes into its own windows (e.g. Stats). Paste the text by hand.

**Text pasted but not sent, or sent with the wrong key**
- Check Auto-send in the menu footer, the paste-without-sending key and the App rules on Settings → Text.
- If `settings.json` doesn't parse, Khuluma warns in the menu and uses the last valid settings, or, with none, the defaults with paste-only delivery. Fix the file (**Open Config**), then **Reload Settings**.

## File transcription

- `command not found: khuluma`: link the app's helper with `ln -s ~/Applications/Khuluma.app/Contents/Helpers/khuluma ~/.local/bin/khuluma`.
- `no speech detected`: the recording is silent or too quiet.
- Model or daemon errors: open Khuluma so its daemon is running, then retry.
