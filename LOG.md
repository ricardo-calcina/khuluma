# Log

## Now

Khuluma v0.11.0 build 355 is installed from `2b460a9`. Recording now uses a round mouth; Settings → Appearance → Menu bar icons switches immediately between Cursed speech and Full emblem and remembers the choice. Full emblem rotates only its centre. Signature, 36 helper cases, 32 static/98 timed captures, native Picker/relaunch/scroll/Back, Reduce Motion and doctor pass. Config, daemon binary/PID, adaptive app icon and Ready/seal assets are preserved. Cursed speech remains the default. Both themes keep the four-second spin, native tint, 36-point slot and 28-by-20-point canvases. Evidence and capture limits are in `assets/icons/README.md`.

Both cursed-speech sets and their renderer remain at `assets/icons/menu-bar/concepts/`. Phase timing, delivery, overlap priority and error handling are unchanged. The raised app icon still uses the compiled native catalog; its Finder light/dark switching was verified in build 347. General appearance remains Auto and icon style Dark → Auto; the approved temporary public build branch is removed.

The menu utility and integrated Settings from build 340 remain in the installed icon update, with the matching local CLI (contract 4). Stats uses three sections across the viewport, with an accurate full-target milestone bar, toolbar utilities and compact Settings. File-transcription entry/output remains a separate design question.

The user confirmed build 340 menu toggling, dictation and Control-Escape cancellation. Live Stats matches the CLI. F17, Parakeet, canonical data/config/model/sound paths, signing identity and the running daemon were preserved. The Homebrew keg and public release remain unchanged; build 340 and older code/receipt backups are retained for recovery.

Canonical-only compatibility removal is complete in source #85 and homebrew-tap#7. The immutable source archive matched Git; shell/native checks, pinned bootstrap, both three-scenario hosted package QA runs and the targeted local Brew upgrade passed. Old kegs, the previous app/local code and all data/recovery material remain retained. The completed identity migration is recorded in [its archived outcome](docs/plans/archive/KHULUMA_IDENTITY_RENAME.md).

Continue the existing daily-use observation before phase 1. No installed old KwikCut executable was found in the bounded standard locations checked; recheck any future installed artifact before use. VPS website work is separate. No fresh-account, forced permission-denial/regrant, logout/reboot or package-uninstall trial is claimed.

## Next

- [x] P1 · Build useful menu panel and integrated Settings with shortcut capture and opt-in Scribe · added 2026-10-23
- [x] P1 · Install the approved menu/Settings app and matching CLI, preserving data/daemon and verifying daily use · added 2026-10-23
- [x] P1 · Review the full identity rename plan · added 2026-10-22
- [x] P1 · Complete isolated rename/migration/recovery acceptance, controlled daily cutover and source/tap integration · added 2026-10-22

- [ ] P1 · Before phase 2: search UKIPO and EUIPO by hand for KHULUMA; register khuluma.app · added 2026-10-17
- [x] P1 · Install raised adaptive light/dark app icon and 18 pt menu glyph; verify Finder automatic switching · added 2026-10-17
- [ ] P1 · Join the Apple Developer Program before phase 2 · added 2026-10-15
- [ ] P1 · Phase 0 gate: a week of daily use, then `tools/khuluma-report.sh` gates still met · added 2026-10-17
- [ ] P1 · Phase 1 step 1: native usage ledger and history writer, proven against the CLI with shared fixtures (removes `inline record`) · added 2026-10-17
- [ ] P1 · Phase 1 after the native writers: port config, bundle and supervise the daemon, add model download and bundled sounds, then port or drop CLI fallbacks; keep shared files/locks compatible while both writers exist · added 2026-10-22
- [ ] P1 · Phase 1 delivery: use PostEvent permission gates and a bundled child daemon; verify clean-account dictation/Stats/history without CLI and 14 days without CLI invocations or usage mismatch before calling it independent · added 2026-10-22
- [x] P2 · Remove old command/env/app compatibility after canonical-only caller and daily-app checks · added 2026-10-23
- [x] P2 · Align formula updater and intact source/tap siblings at khuluma and homebrew-tap · added 2026-10-22
- [ ] P2 · Skip auto-send for one take: hold a key (Shift or similar, to decide) so the take pastes without pressing Enter; auto-send stays the default · added 2026-10-17
- [ ] P2 · Stats stage 3 ideas (not committed): weeks view, wpm trend, typing_wpm config, time of day, opt-in per-app · added 2026-10-16
- [x] P2 · Use total words, estimated time saved and average WPM in the menu and Stats summary · added 2026-10-23
- [ ] P2 · Review the existing file-transcription entry/output flow before choosing a drag target · added 2026-10-23
- [x] P2 · Choose and install cursed-speech set 1 Recording/Finishing replacements; preserve set 2 · added 2026-10-23
- [x] P2 · Slowly rotate the Processing fang seal, including menu tracking and Reduce Motion stop/resume · added 2026-10-23
- [x] P2 · Install and verify rounder Recording mouth and immediate Settings switch between both status icon themes · added 2026-10-23
- [ ] P2 · Lowkey ideas parked from 3c, only with evidence: config file watcher, warm mic/pre-roll · added 2026-10-16
- [ ] P2 · Phase 2 after CLI independence: Developer ID signing/notarization, versioned app distribution and khuluma cask; Settings, History, Transcribe File and bundled agent CLI; verify fresh-Mac permissions and file transcription · added 2026-10-22
- [ ] P2 · Decide the future signed-app cask/update approach before phase 2 distribution; paid membership/domain require separate authorization · added 2026-10-22
- [ ] P2 · Phase 3: repeatable import of legacy config/vocab/history/usage into Khuluma Application Support; preserve old data and totals/streak, keep ledger export shape, redirect or stop old CLI writes · added 2026-10-22
- [ ] P2 · Phase 4 after replacement is usable: interactive CLI deprecation notice, formula and Finder notices; preserve JSON contracts; check remaining integrations over a 30-day notice period · added 2026-10-22
- [ ] P2 · Phase 5 after deprecation: final supported CLI release and replacement links, then formula disable/repository archive with explicit release authorization; retain public history · added 2026-10-22
- [ ] P3 · Deferred separate labs: voxtral-inline API/realtime dictation and faster-whisper-tool batch/subtitle/offline exploration; only after core reliability is stable · added 2026-10-22

## Decisions

- Icon/theme recovery: `/Users/admin/Applications/.khuluma-app.74v7dj/previous.app` retains signed build 353; current QA is at `/private/tmp/khuluma-themes-qa.RxaJYA/`. `.khuluma-app.xMyT3X/previous.app` retains build 351, `.khuluma-app.atWD6N/previous.app` build 347, `.khuluma-app.LYC8GT/previous.app` build 342 and `.khuluma-app.LYfteh/previous.app` build 340. Earlier motion/status/app-icon QA remains under `/private/tmp/khuluma-{motion,status,icons}-qa.*` as recorded in `assets/icons/README.md`. Preserve newer user data when recovering.

- Local menu/Settings cutover recovery: `/Users/admin/Applications/.khuluma-live.qBasYG/previous.app` retains build 332; `code-manifest.json` and code backups retain the matching prior local CLI/receipt. Preserve newer usage/history when recovering.

- Prefer canonical-only interfaces. v0.11.0 removed ordinary old command/environment/app compatibility after concrete caller and daily-workflow checks, superseding the former 30-day identity wait. Preserve data, historical releases, explicit recovery and wrong-profile/competing-writer refusals. The completed per-file removal plan remains in Git at `8da982b:LOG.md`; source #85 records implementation.
- Recovery on this Mac remains under `/Users/admin/Documents/Codex/2026-10-22/all-right-next-i-want-to/work/`: `khuluma-live-cutover/`, `khuluma-implementation-evidence/local-brew-recovery-3kf3c92v/` and `khuluma-compat-2026-10-23/`. The committed data manifest is `~/.config/khuluma/.migration/rename-v1/manifest.json`. Closed controller journals are historical: never replay them or restore an old snapshot over newer user work.

- Khuluma is the product; local, fast dictation and never losing a take remain the priorities. The CLI is its back end until native replacements are proven. Keep shared-file and locking contracts while the app and CLI share those files.
- Name chosen: Khuluma. Approved rename target is bundle `com.ricardo-nth.khuluma` with a separate `Khuluma Local Code Signing` identity; preserve the existing Lowkey identity and data for other apps/rollback. The controlled cutover and final v0.10.0 app acceptance passed. Name research is dated in `docs/plans/KHULUMA_NAME_CHECK.md`; official UK/EU checks remain open above.
- Direct distribution is the planned channel. Mac App Store phase 6 is parked; the old roadmap keeps the sandbox research. Free/paid store distribution is undecided.
- Tmux capture, CLI recording, LLM rewriting, silence trim, bash chunking, Raycast and SwiftBar were dropped; reintroduce none without evidence. Usage, Stats and logs keep counts/timings, not transcript text; history and pending recovery are the intentional text stores.
- Rename the existing repository in place to preserve all history; retain neutral `ricardo-nth/tap` and rename its formula to `khuluma`. The in-place repository rename, immutable v0.10.0 release and canonical formula/map are published and verified. The app continues to depend on its matching CLI; cask/CLI-independence/deprecation/archive are separate future work.

## Done

- 2026-10-23 · Installed signed build 355 round Recording mouth and both Settings themes; 36 helper/32 static/98 motion/native Picker/relaunch/signature/doctor checks pass, config/daemon/catalog preserved · 2b460a9; assets/icons/README.md

- 2026-10-23 · Installed signed build 353 with slow Processing rotation; timed/menu-open/phase/Reduce Motion/static/signature/doctor checks pass, config/daemon/assets preserved · fb06b5b; assets/icons/README.md

- 2026-10-23 · Installed signed build 351 cursed-speech set 1; 36 helper/16 native capture/signature/doctor checks pass, config/daemon/app icon preserved; set 2 retained for future theme · 6bc646c; assets/icons/menu-bar/README.md

- 2026-10-23 · Rendered two cursed-speech Recording/Finishing sets with exact Ready glyph, enlarged detail and light/dark 18 pt strips; previews only, runtime unchanged · assets/icons/menu-bar/concepts/

- 2026-10-23 · Rechecked installed build 347 native catalog against Xcode 26.6 provenance and Apple guidance; brainstormed status glyphs, runtime unchanged · assets/icons/app/catalog-build.json; tools/compile-khuluma-icon.sh

- 2026-10-23 · Installed signed build 347 with compiled adaptive icon; Finder light/dark, helper/native-render/signature/doctor checks pass, daemon/config preserved, temporary public build branch removed · 646be9b; assets/icons/README.md

- 2026-10-23 · Installed signed build 342 raised app icon/18 pt menu glyph; helper/native-render/doctor checks pass, config/daemon preserved; Finder adaptive catalog pending · 0ad066f; assets/icons/README.md

- 2026-10-23 · Installed signed build 340 and matching local contract-4 CLI from 6a48abb; CI/17 stats tests/42 renders/doctor pass, user confirmed menu/dictation/cancel; daemon/data preserved · native/Sources/Khuluma/Stats; local recovery .khuluma-live.qBasYG

- 2026-10-23 · Saved selected raised light/dark icon previews and rendered menu template; adaptive packaging still open · assets/icons/README.md

- 2026-10-23 · Distributed Stats viewport space across three sections and corrected/thickened full-target milestone progress; local daily install authorized · native/Sources/Khuluma/Stats; native/Tests/KhulumaCoreTests/StatsTests.swift

- 2026-10-23 · Fit normal Stats without scrolling; moved Refresh and usage info to toolbar; build/42 renders and live info/Escape/navigation pass, daily app unchanged · native/Sources/Khuluma/Stats; DESIGN.md

- 2026-10-23 · Restored quiet dated records, recording totals and word milestones; build/16 stats tests/32 renders and live scroll/accessibility pass · native/Sources/Khuluma/Stats/StatsView.swift; DESIGN.md

- 2026-10-23 · Centered lifetime metrics, tightened menu footer and simplified Stats; build/28 renders and live Settings/Back pass, daily app unchanged · native/Sources/Khuluma/Stats/StatsView.swift; DESIGN.md

- 2026-10-23 · Reused Sys Stats native menu tracking; refined icons, hover, toolbar and Settings; build/28 renders pass, daily app unchanged · native/Sources/Khuluma/StatusDropdownController.swift; DESIGN.md

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
