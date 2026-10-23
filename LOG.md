# Log

## Now

The menu utility and integrated Settings are implemented in source on `feat/menu-utility-settings`: compact daily usage, shortcut capture, model selection and opt-in Scribe v2. App/CLI contract 4 keeps transcription destinations compatible. Private UI fixtures and network-free provider checks pass; the daily runtime has not been updated for this work.

Khuluma v0.11.0 (build 332) is the installed daily app, with matching local and Homebrew CLIs. The user verified dictation, paste, cancel, Stats and Start at Login, with no recovered-take warning. Canonical synthetic file transcription passed. The signed app uses `com.ricardo-nth.khuluma`; config, model, sound and runtime paths stay canonical, and the existing app-owned daemon remained running through the package upgrade.

Canonical-only compatibility removal is complete in source #85 and homebrew-tap#7. The immutable source archive matched Git; shell/native checks, pinned bootstrap, both three-scenario hosted package QA runs and the targeted local Brew upgrade passed. Old kegs, the previous app/local code and all data/recovery material remain retained. The completed identity migration is recorded in [its archived outcome](docs/plans/archive/KHULUMA_IDENTITY_RENAME.md).

Continue the existing daily-use observation before phase 1. No installed old KwikCut executable was found in the bounded standard locations checked; recheck any future installed artifact before use. VPS website work is separate. No fresh-account, forced permission-denial/regrant, logout/reboot or package-uninstall trial is claimed.

## Next

- [x] P1 · Build useful menu panel and integrated Settings with shortcut capture and opt-in Scribe · added 2026-10-23
- [ ] P1 · Review the menu/Settings preview, then install matching app/CLI when authorized and verify daily dictation · added 2026-10-23
- [x] P1 · Review the full identity rename plan · added 2026-10-22
- [x] P1 · Complete isolated rename/migration/recovery acceptance, controlled daily cutover and source/tap integration · added 2026-10-22

- [ ] P1 · Before phase 2: search UKIPO and EUIPO by hand for KHULUMA; register khuluma.app · added 2026-10-17
- [ ] P1 · Khuluma app icon: the bundle has none yet (Dock, Finder, Login Items, System Settings show a blank icon); a menu-bar glyph to match · added 2026-10-17
- [ ] P1 · Join the Apple Developer Program before phase 2 · added 2026-10-15
- [ ] P1 · Phase 0 gate: a week of daily use, then `tools/khuluma-report.sh` gates still met · added 2026-10-17
- [ ] P1 · Phase 1 step 1: native usage ledger and history writer, proven against the CLI with shared fixtures (removes `inline record`) · added 2026-10-17
- [ ] P1 · Phase 1 after the native writers: port config, bundle and supervise the daemon, add model download and bundled sounds, then port or drop CLI fallbacks; keep shared files/locks compatible while both writers exist · added 2026-10-22
- [ ] P1 · Phase 1 delivery: use PostEvent permission gates and a bundled child daemon; verify clean-account dictation/Stats/history without CLI and 14 days without CLI invocations or usage mismatch before calling it independent · added 2026-10-22
- [x] P2 · Remove old command/env/app compatibility after canonical-only caller and daily-app checks · added 2026-10-23
- [x] P2 · Align formula updater and intact source/tap siblings at khuluma and homebrew-tap · added 2026-10-22
- [ ] P2 · Skip auto-send for one take: hold a key (Shift or similar, to decide) so the take pastes without pressing Enter; auto-send stays the default · added 2026-10-17
- [ ] P2 · Stats stage 3 ideas (not committed): weeks view, wpm trend, longest take, typing_wpm config, streak line, time of day, opt-in per-app · added 2026-10-16
- [ ] P2 · Lowkey ideas parked from 3c, only with evidence: config file watcher, warm mic/pre-roll · added 2026-10-16
- [ ] P2 · Phase 2 after CLI independence: Developer ID signing/notarization, versioned app distribution and khuluma cask; Settings, History, Transcribe File and bundled agent CLI; verify fresh-Mac permissions and file transcription · added 2026-10-22
- [ ] P2 · Decide the future signed-app cask/update approach before phase 2 distribution; paid membership/domain require separate authorization · added 2026-10-22
- [ ] P2 · Phase 3: repeatable import of legacy config/vocab/history/usage into Khuluma Application Support; preserve old data and totals/streak, keep ledger export shape, redirect or stop old CLI writes · added 2026-10-22
- [ ] P2 · Phase 4 after replacement is usable: interactive CLI deprecation notice, formula and Finder notices; preserve JSON contracts; check remaining integrations over a 30-day notice period · added 2026-10-22
- [ ] P2 · Phase 5 after deprecation: final supported CLI release and replacement links, then formula disable/repository archive with explicit release authorization; retain public history · added 2026-10-22
- [ ] P3 · Deferred separate labs: voxtral-inline API/realtime dictation and faster-whisper-tool batch/subtitle/offline exploration; only after core reliability is stable · added 2026-10-22

## Decisions

- Prefer canonical-only interfaces. v0.11.0 removed ordinary old command/environment/app compatibility after concrete caller and daily-workflow checks, superseding the former 30-day identity wait. Preserve data, historical releases, explicit recovery and wrong-profile/competing-writer refusals. The completed per-file removal plan remains in Git at `8da982b:LOG.md`; source #85 records implementation.
- Recovery on this Mac remains under `/Users/admin/Documents/Codex/2026-10-22/all-right-next-i-want-to/work/`: `khuluma-live-cutover/`, `khuluma-implementation-evidence/local-brew-recovery-3kf3c92v/` and `khuluma-compat-2026-10-23/`. The committed data manifest is `~/.config/khuluma/.migration/rename-v1/manifest.json`. Closed controller journals are historical: never replay them or restore an old snapshot over newer user work.

- Khuluma is the product; local, fast dictation and never losing a take remain the priorities. The CLI is its back end until native replacements are proven. Keep shared-file and locking contracts while the app and CLI share those files.
- Name chosen: Khuluma. Approved rename target is bundle `com.ricardo-nth.khuluma` with a separate `Khuluma Local Code Signing` identity; preserve the existing Lowkey identity and data for other apps/rollback. The controlled cutover and final v0.10.0 app acceptance passed. Name research is dated in `docs/plans/KHULUMA_NAME_CHECK.md`; official UK/EU checks remain open above.
- Direct distribution is the planned channel. Mac App Store phase 6 is parked; the old roadmap keeps the sandbox research. Free/paid store distribution is undecided.
- Tmux capture, CLI recording, LLM rewriting, silence trim, bash chunking, Raycast and SwiftBar were dropped; reintroduce none without evidence. Usage, Stats and logs keep counts/timings, not transcript text; history and pending recovery are the intentional text stores.
- Rename the existing repository in place to preserve all history; retain neutral `ricardo-nth/tap` and rename its formula to `khuluma`. The in-place repository rename, immutable v0.10.0 release and canonical formula/map are published and verified. The app continues to depend on its matching CLI; cask/CLI-independence/deprecation/archive are separate future work.

## Done

- 2026-10-23 · Added usage menu, Settings, shortcut capture and opt-in Scribe; source/UI/provider checks passed, daily app unchanged · native/Sources/Khuluma/Settings; tests/test_providers.sh

- 2026-10-23 · Shipped canonical-only v0.11.0; app/local/Brew checks passed, data and recovery intact · #85; homebrew-tap#7; v0.11.0

- 2026-10-23 · Verified canonical callers and preference APIs; staged compatibility removal in isolated worktrees, daily v0.10 untouched · caller-readiness-c8324fbf21

- 2026-10-23 · Planned canonical-only compatibility removal; replaced calendar wait with caller/runtime gates and corrected unsupported installed-KwikCut claim · 8da982b:LOG.md

- 2026-10-22 · Completed identity rename; final v0.10.0 build327 passed user dictation/paste/cancel; recovery retained · #83; v0.10.0
- 2026-10-22 · Published immutable source release and canonical tap; fresh/old-upgrade QA and local Brew transition passed · v0.10.0; homebrew-tap#5
- 2026-10-22 · Archived the completed per-file migration record; current work stays in LOG; website remains preview-only · docs/plans/archive/KHULUMA_IDENTITY_RENAME.md

- 2026-10-22 · Committed canonical daily handoff; user verified dictation/paste/Stats, normal relaunch/login and Finder after Services refresh; recovery retained · docs/plans/archive/KHULUMA_IDENTITY_RENAME.md

- 2026-10-22 · Verified signed build324 and intact local source/tap moves; real pre-data rollback restored old app/serving daemon after lifecycle cache refusal · 64c96e2; docs/plans/archive/KHULUMA_IDENTITY_RENAME.md

- 2026-10-22 · Preserved original documentation as exact baseline commits; reviewed public migration/controller handoff · bc2bfca; docs/INTEGRATIONS.md#identity-migration

- 2026-10-22 · Implemented canonical identities and lossless migration; isolated native/shell/recovery/real-model gates passed; daily/public rollout pending · docs/plans/archive/KHULUMA_IDENTITY_RENAME.md

- 2026-10-22 · Started approved rename in isolated source/tap worktrees; preserved existing docs baseline; cold Swift gate 170 tests passed · docs/plans/archive/KHULUMA_IDENTITY_RENAME.md

- 2026-10-22 · Prepared reviewed identity migration plan with exact files/lines, state/rollback and release gates; runtime untouched · docs/plans/archive/KHULUMA_IDENTITY_RENAME.md

- 2026-10-22 · Source collection is now VPS/Apps/Khuluma; nested repo, CLI/runtime identities and installed app preserved · README.md
- 2026-10-22 · Moved with the complete collection under VPS/Apps/tmux-whspr; source identity and installed Khuluma remain separate · ../README.md
- 2026-10-22 · Moved source tmux-whisperd/.build to Trash; pinned source retained and installed Khuluma/daemon hashes unchanged · README.md; tmux-whisperd/Package.resolved
- 2026-10-22 · Consolidated current tasks/decisions in LOG, archived rename roadmap, separated public changelog from queue and clarified runtime/tap paths; source-only checks · LOG.md; docs/archive/KHULUMA_RENAME_ROADMAP.md
- 2026-10-17 · `inline process` saves history before returning and reports `history_saved`; Khuluma's CLI path settles a take's Quit copy only when it is true · #80
- 2026-10-17 · Modes removed: one global vocab (default keeps the base path rules, code spellings dropped), `migrate-modes [--skip]` archives old modes, auto-paragraphs gone; app contract 3; this Mac migrated with --skip code · #78
- 2026-10-17 · Khuluma rename step 3: roadmap, name check and CHANGELOG TODO describe Khuluma; phase 0 kept as decided · #76
- 2026-10-17 · Khuluma rename step 2: the app is Khuluma.app; scripts build-khuluma-app.sh and khuluma-report.sh; Lowkey folders migrate at launch; bundle id and signing identity kept · #75
- 2026-10-17 · Khuluma rename step 1: Swift targets Khuluma, KhulumaCore, KhulumaObjC, KhulumaCoreTests (app still Lowkey.app) · #74
- 2026-10-17 · Public name chosen: Khuluma (isiNdebele "speak"); Thumela runner-up · docs/plans/KHULUMA_NAME_CHECK.md, #67
- 2026-10-16 · Quit saves takes still queued or being transcribed to recovered/, so a Quit that runs out of time no longer loses them · #73
- 2026-10-16 · Name check (P0a): Lowkey ruled out by live LOWKEY software marks in UK/US/EU · docs/plans/KHULUMA_NAME_CHECK.md
- 2026-10-16 · P0b docs: README, ROADMAP, CONTRIBUTING, TROUBLESHOOTING (Lowkey section), domain and templates rewritten around Lowkey; pre-v0.7 changelog archived; pad-sfx.sh removed · #72
- 2026-10-16 · Lowkey's AppController split into TakePipeline, TakePersister, StatusMenu, LoginItem; menu status is a tested LowkeyCore type · #71
- 2026-10-16 · LLM post-processing, silence trim and bash chunking removed (with budget, replay, bench-matrix, mode prompts); app contract 2 · #70
- 2026-10-16 · tmux flow and CLI recording removed (start/stop/toggle, tmux, keybind, devices, watch, debug, logs); Lowkey records, the CLI is its back end · #69
- 2026-10-16 · Lowkey requires its matching CLI (app contract); rollout switches, verify and the older-CLI paths removed after the v0.10.0 gates passed · #68
- 2026-10-16 · Raycast scripts, `integrations` doctor/repair and the `swiftbar` stub removed · #66
- 2026-10-16 · Finished plans moved to docs/plans/archive/ · #65
- 2026-10-16 · P0b review done; dropping tmux flow, CLI capture, LLM post-processing, silence trim, chunking; Lowkey to require its matching CLI · roadmap P0b
- 2026-10-15 · Lowkey rename roadmap approved: phases 0–5, App Store parked · docs/plans/KHULUMA_RENAME_ROADMAP.md
