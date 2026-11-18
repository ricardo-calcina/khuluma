# Direction

Khuluma is the native menu-bar app, and only the app (Ricardo, 2026-11-05). The bash `khuluma` CLI, its Homebrew formula and `install.sh` were retired in 2026-11 ([archived plan](docs/plans/archive/CLI_SUNSET.md)): the app keeps its own data, runs its own daemon, and bundles file transcription (`khuluma transcribe`, for the agent skill), ElevenLabs Scribe and the Finder Quick Actions. Current tasks, priorities and decisions live in [`LOG.md`](LOG.md).

Dictation stays local and fast, recovery must not lose a take, and usage/logs hold counts and timings, not text. The earlier rename roadmap is [archived](docs/archive/KHULUMA_RENAME_ROADMAP.md); its App Store research still holds. The two-product plan of 2026-10-27 (a free CLI with SwiftBar beside a paid app) was dropped on 2026-11-05 before any code; it is kept at git tag `archive/two-product-plan`.

## Phases

Phase numbers follow the archived roadmap so LOG items keep their meaning. Phase 1 (the app works without the CLI, [`docs/plans/APP_INDEPENDENCE.md`](docs/plans/APP_INDEPENDENCE.md)), phase 4 (retire the CLI) and phase 5 (remove it from the repositories) are done. The Homebrew tap (`ricardo-calcina/homebrew-tap`) and the copies on Ricardo's Mac are handled outside this repo.

### Phase 2: ship the app (after the Apple Developer Program)

Developer ID signing, hardened runtime, notarisation, a versioned `.dmg` from khuluma.app with in-app updates (Sparkle). No Homebrew cask. Payment and licensing are decided with the website, and so is whether the app's source stays in this public MIT repository. Exit: a fresh Mac downloads the `.dmg`, Gatekeeper opens it without a warning, and permissions prompt once.

### Parked: Mac App Store

Revisit after phase 2 has paying users. Data in Application Support suits the sandbox; automatic paste remains an App Review risk (archived roadmap, "App Store blockers"). Free vs paid on the store is undecided.
