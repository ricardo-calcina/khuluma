# Direction

Khuluma is the native menu-bar app, and only the app (Ricardo, 2026-11-05). The `khuluma` CLI, its Homebrew formula and the tap are retired once the app no longer needs them. What the CLI did, and what the app keeps, is in [`docs/plans/CLI_SUNSET.md`](docs/plans/CLI_SUNSET.md): file transcription (a small command in the app bundle, same call shape for the agent skill), ElevenLabs Scribe and the Finder Quick Action stay; the rest goes with the CLI. Current tasks, priorities and decisions live in [`LOG.md`](LOG.md).

Dictation stays local and fast, recovery must not lose a take, and usage/logs hold counts and timings, not text. The earlier rename and CLI-sunset roadmap is [archived](docs/archive/KHULUMA_RENAME_ROADMAP.md); its App Store research still holds. The two-product plan of 2026-10-27 (a free CLI with SwiftBar beside a paid app) was dropped on 2026-11-05 before any code; it is kept at git tag `archive/two-product-plan`.

## Phases

Phase numbers follow the archived roadmap so LOG items keep their meaning; phase 4 and 5 now come before phase 2.

### Phase 1: the app works without the CLI (app-independence tab)

[`docs/plans/APP_INDEPENDENCE.md`](docs/plans/APP_INDEPENDENCE.md): native config, vocabulary, history, usage and bench writers; data in `~/Library/Application Support/Khuluma` after a one-time copy from `~/.config/khuluma` (the source stays as rollback; this replaces the old phase 3); bundled daemon and model download; bundled sounds; Scribe ported; the built-in transcribe command and the Finder Quick Action. Exit: a clean account with no CLI, Homebrew or developer tools dictates, shows Stats, transcribes a file and passes the skill's call.

### Phase 4: retire the CLI (right after phase 1)

The CLI only exists to serve the app, so it goes as soon as phase 1 exits; it doesn't wait for the app to be sold.

1. **Final CLI release** (`v0.12.0`, Ricardo's yes): every interactive command prints one line saying the CLI is retired and pointing to the app; `--json` output is unchanged so nothing parses a notice. CHANGELOG records the end of support.
2. **Formula**: the tap's `khuluma` formula moves to the final release with `disable! date: <release day>, because: "is retired; Khuluma is now the macOS app at khuluma.app"` (Ricardo's yes). Disable rather than deprecate: no known users besides Ricardo (0 stars, no issues), so a 30-day deprecation window buys nothing.
3. **Ricardo's Mac** (his yes, with a rollback copy), only after the app has run a week with no CLI calls: the Homebrew copy first (`brew uninstall khuluma`, `brew untap ricardo-calcina/tap`), then the install.sh copy in `~/.local/bin`, the CLI's daemon tree under `~/.local/share/khuluma/native/` and the old Finder workflow, all to the Bin. The app's helper then takes `~/.local/bin/khuluma`, and the skill (`~/.claude` and `~/.codex` copies) is checked against it.

Exit: the app runs with no `khuluma` CLI on the Mac, the skill and the Finder action work through the app, and `brew install ricardo-calcina/tap/khuluma` says the formula is disabled and why.

### Phase 5: remove the CLI from the repositories

1. **This repo**: remove `bin/`, `install.sh`, `bootstrap.sh`, the CLI tests and `ci.yml`, the identity-migration tools and `tools/update-homebrew-formula.sh`. Keep `tests/fixtures/cleanup/` as frozen golden files for the Swift tests, and `tools/khuluma-report.sh`. Rewrite README, `docs/INTEGRATIONS.md`, `docs/TROUBLESHOOTING.md` and `docs/RELEASE_CHECKLIST.md` for the app; `docs/CLI_CONTRACTS.md` keeps only what the app still follows, or goes. The repo keeps its history and its name.
2. **The tap** (`ricardo-calcina/homebrew-tap`): it holds only the `khuluma` formula, `formula_renames.json`, release QA notes and docs. After the disabled formula has been live a few weeks, a README banner, then archive the repo (Ricardo's yes). An archived repo stays readable, so `brew` can still explain the disable.
3. **The skill**: `integrations/agents/transcribe-audio/SKILL.md` follows the app's command.

Exit: CI runs only the Swift and icon workflows; no doc tells anyone to install or run the CLI.

### Phase 2: ship the app (after the Apple Developer Program)

Developer ID signing, hardened runtime, notarisation, a versioned `.dmg` from khuluma.app with in-app updates (Sparkle). No Homebrew cask: the tap is gone. A History window joins Stats. Payment and licensing are decided with the website, and so is whether the app's source stays in this public MIT repository. Exit: a fresh Mac downloads the `.dmg`, Gatekeeper opens it without a warning, and permissions prompt once.

### Parked: Mac App Store

Revisit after phase 2 has paying users. Data in Application Support suits the sandbox; automatic paste remains an App Review risk (archived roadmap, "App Store blockers"). Free vs paid on the store is undecided.
