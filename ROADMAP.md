# Direction

Khuluma is two products from one source tree (Ricardo, 2026-10-27; order set 2026-11-05):

- **Khuluma CLI**: free, MIT, on the Homebrew tap (`brew install ricardo-calcina/tap/khuluma`). It dictates on its own again, with a SwiftBar menu, and keeps file transcription, history, usage, vocabulary and the Finder Quick Action.
- **Khuluma app**: the paid native menu-bar app, signed and notarised, downloaded from khuluma.app. Not Homebrew. The Mac App Store is parked (below).

Each works alone. When both are installed they share one config, vocabulary, history, usage ledger and log, and every record names the writer (`app` or `cli`), so a problem can be traced to its source. The shared data contract (formats, locks, writer tags, the code that writes shared files) is owned by the "Khuluma app without the CLI" work and lives in [`docs/CLI_CONTRACTS.md`](docs/CLI_CONTRACTS.md).

Dictation stays local and fast, recovery must not lose a take, and usage/logs hold counts and timings, not text. Current tasks are in [`LOG.md`](LOG.md). The earlier rename and CLI-sunset roadmap is [archived](docs/archive/KHULUMA_RENAME_ROADMAP.md): its phases 4 and 5 (deprecate, disable and archive the CLI) are cancelled, and its App Store research still holds.

## Phases

### Phase 1: the app works without the CLI (in progress, separate tab)

As planned: native usage/history writers, config reader, bundled daemon, model download and bundled sounds, native fallbacks. Adds the writer tag and the shared contract both products follow. Exit unchanged: a clean account with no CLI dictates, shows Stats and history; 14 days with no CLI invocations.

### CLI track: the CLI stands alone again (parallel with phase 1)

The CLI was cut back to the app's back end in October (#62, #66, #69: SwiftBar, Raycast, CLI recording and the tmux flow removed, because the app had taken the hotkey and the menu bar). It gets back what a standalone tool needs, under current names and on the native daemon:

1. **CLI dictation**: `khuluma start | stop | toggle | cancel` records from the microphone with ffmpeg, transcribes through `khulumad`, cleans up with the shared vocabulary, and pastes into the front app (optionally sending), saving history and usage as `cli`. Recovery matches the app's promise: a take that fails to transcribe is kept for `khuluma retry`. Rebuilt from the removed `recording.sh`/`audio.sh` (3110956^), not restored wholesale.
2. **SwiftBar plugin** `integrations/swiftbar/khuluma.1s.sh`: Ready / Recording / Processing / Error state, Start/Stop and Cancel, a global shortcut through SwiftBar's `shortcut=`, today's and lifetime words, Auto-send, send mode and sound toggles, Open History, Doctor. Reads only `--json` contracts; no `/tmp` flag files. Rebuilt from the retired plugin (cd2c29d^), dropping tmux and modes.
3. **`khuluma model download`** with consent, so a fresh `brew install` can dictate without hand-placing the model; reuses the FluidAudio shared cache when present.
4. **Install and docs**: `khuluma swiftbar install | remove` (copies the plugin, never edits SwiftBar's settings), README and `docs/INTEGRATIONS.md` describe the CLI as its own product, the formula's desc/caveats/test follow. The `inline process | record` back-end commands stay until phase 1 no longer calls them, then become CLI-internal.
5. **Next to the app**, once the contract lands: one recording at a time across both (the shared recording lock in the contract), one daemon under the existing lifecycle lock, records tagged `cli`, and `doctor` reports when the app is also installed and which one owns the daemon. No contract edits here; requests go to the phase 1 tab.

Not coming back: the tmux pane flow, LLM post-processing and modes. Raycast scripts only if SwiftBar's shortcut proves not enough.

Exit: on a private profile with no app installed, `brew install` from a local formula, `model download`, then a SwiftBar-started take pastes, saves history and counts usage; with the app also installed, both dictate (not at once), and Stats and `khuluma usage` agree, with each record's writer correct.

### Phase 2: the app ships on its own (after the Apple Developer Program)

Developer ID signing, hardened runtime, notarisation, a versioned `.dmg` on khuluma.app with in-app updates (Sparkle). No Homebrew cask: Homebrew is the free CLI's channel. The app does not bundle the CLI; the agent skill and Finder action stay CLI features, and the app gets its own Transcribe File. Payment and licensing are decided with the website.

Old phase 3 (moving data into Application Support) is replaced by the shared contract: where shared data lives is phase 1's decision, and the CLI follows it.

Exit: a fresh Mac downloads the `.dmg`, Gatekeeper opens it without a warning, permissions prompt once, and it dictates with no CLI.

### CLI releases (replaces old phases 4 and 5)

The CLI is maintained, not deprecated. Releases are source tags (`cli-vX.Y.Z` or the existing `vX.Y.Z`) with the formula updated by `tools/update-homebrew-formula.sh`, each one needing Ricardo's yes. The shared contract has a version both products check, so an older CLI next to a newer app (or the reverse) refuses only the writes it can't do safely and says which side to update.

### Parked: Mac App Store

Revisit after phase 2 has paying users. The sandbox can't reach `~/.config/khuluma`, so a store build shares data with the CLI only after the user grants that folder once (security-scoped bookmark), and automatic paste is an App Review risk (archived roadmap, "App Store blockers"). Free vs paid on the store is undecided.

## Open questions

- Whether the paid app's source stays in this public MIT repository, moves to a private one, or changes licence. Decide before phase 2 ships.
