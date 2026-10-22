# Log

## Now

Khuluma v0.10.0 is the installed daily app and CLI. Build 327 uses `com.ricardo-nth.khuluma` and its dedicated local signer; config, runtime, model and sound paths are canonical. The user verified dictation, paste, cancel, Stats, normal relaunch, Start at Login and Finder transcription. Source release `v0.10.0` and the canonical Homebrew formula are published. The completed [identity migration record](docs/plans/archive/KHULUMA_IDENTITY_RENAME.md) preserves the reviewed plan and actual evidence.

Canonical-only compatibility removal is in progress in isolated source/tap worktrees under the approved goal. Caller and macOS preference API checks passed; implementation review and serialized checks precede any daily switch. Continue the existing daily-use observation before phase 1. Keep all prior app/runtime/data/certificate recovery material. KwikCut is a CLI; no installed old executable was found in the bounded standard locations checked. Its canonical discovery source and retained private candidate are updated, and no actual installed old caller was found. Recheck any future installed artifact before use. The user approved the local VPS page preview on 2026-10-23; website publication remains pending the broader relaunch. No fresh-account, forced permission-denial/regrant, logout/reboot or package-uninstall trial is claimed.

## Next

- [x] P1 · Review the full identity rename plan · added 2026-10-22
- [x] P1 · Complete isolated rename/migration/recovery acceptance, controlled daily cutover and source/tap integration · added 2026-10-22

- [ ] P1 · Before phase 2: search UKIPO and EUIPO by hand for KHULUMA; register khuluma.app · added 2026-10-17
- [ ] P1 · Khuluma app icon: the bundle has none yet (Dock, Finder, Login Items, System Settings show a blank icon); a menu-bar glyph to match · added 2026-10-17
- [ ] P1 · Join the Apple Developer Program before phase 2 · added 2026-10-15
- [ ] P1 · Phase 0 gate: a week of daily use, then `tools/khuluma-report.sh` gates still met · added 2026-10-17
- [ ] P1 · Phase 1 step 1: native usage ledger and history writer, proven against the CLI with shared fixtures (removes `inline record`) · added 2026-10-17
- [ ] P1 · Phase 1 after the native writers: port config, bundle and supervise the daemon, add model download and bundled sounds, then port or drop CLI fallbacks; keep shared files/locks compatible while both writers exist · added 2026-10-22
- [ ] P1 · Phase 1 delivery: use PostEvent permission gates and a bundled child daemon; verify clean-account dictation/Stats/history without CLI and 14 days without CLI invocations or usage mismatch before calling it independent · added 2026-10-22
- [ ] P2 · Remove old command/env/app compatibility after canonical-only caller and daily-app checks; follow the removal plan below, with no calendar wait · added 2026-10-23
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

- Prefer canonical-only interfaces. The 2026-10-23 direction supersedes the former 30-day identity-compatibility wait: remove old aliases and adapters once concrete caller/workflow checks pass. The user authorized implementation and a controlled verified rollout in isolated worktrees. Preserve the daily runtime until checks and recoverable code refresh are ready. Preserve data, recovery, historical releases and wrong-profile/competing-writer refusals.
- Recovery on this Mac remains under `/Users/admin/Documents/Codex/2026-10-22/all-right-next-i-want-to/work/`: `khuluma-live-cutover/` and `khuluma-implementation-evidence/local-brew-recovery-3kf3c92v/`. The committed data manifest is `~/.config/khuluma/.migration/rename-v1/manifest.json`. Closed controller journals are historical: never replay them or restore an old snapshot over newer user work.

- Khuluma is the product; local, fast dictation and never losing a take remain the priorities. The CLI is its back end until native replacements are proven. Keep shared-file and locking contracts while the app and CLI share those files.
- Name chosen: Khuluma. Approved rename target is bundle `com.ricardo-nth.khuluma` with a separate `Khuluma Local Code Signing` identity; preserve the existing Lowkey identity and data for other apps/rollback. The controlled cutover and final v0.10.0 app acceptance passed. Name research is dated in `docs/plans/KHULUMA_NAME_CHECK.md`; official UK/EU checks remain open above.
- Direct distribution is the planned channel. Mac App Store phase 6 is parked; the old roadmap keeps the sandbox research. Free/paid store distribution is undecided.
- Tmux capture, CLI recording, LLM rewriting, silence trim, bash chunking, Raycast and SwiftBar were dropped; reintroduce none without evidence. Usage, Stats and logs keep counts/timings, not transcript text; history and pending recovery are the intentional text stores.
- Rename the existing repository in place to preserve all history; retain neutral `ricardo-nth/tap` and rename its formula to `khuluma`. The in-place repository rename, immutable v0.10.0 release and canonical formula/map are published and verified. The app continues to depend on its matching CLI; cask/CLI-independence/deprecation/archive are separate future work.

## Compatibility removal plan

Implementation authorized, 2026-10-23; planning anchors refer to source `5a9e525` and tap `9f56a01` and must be rechecked before edits. Target: only `khuluma`, `KHULUMA_*`, the canonical app identity and doctor schema 2 in ordinary operation. No fixed waiting period and no new forwarding layers. The separate native-CLI-independence roadmap remains unchanged.

### Readiness

- [x] Confirm the actual external executables/explicit overrides in use. Scoped shell, both agent skills and installed Finder routes are already canonical; no inherited legacy environment names were found.
- [x] Correct the earlier installed-KwikCut assumption: it has an executable target, not an app bundle. No standard installed command/app/source build output or shell alias was found. Its retained private `kwikcut` candidate and three discovery tests are canonical; only Notes/tests/package inputs were compared, not its entire source provenance. Test the executable actually invoked, or rebuild private KwikCut/KwikCore copies if one is needed; preserve both projects' dirty work.
- [ ] Stage canonical-only source and package candidates in isolated worktrees/fixtures with every old command unavailable. Prove file transcription, skills, Finder and any actual KwikCut invocation use canonical paths. Do not hide the daily installed shim to run this test.
- [x] Before deleting app imports, verify the four canonical preference keys through UserDefaults, not cached-plist inference. Confirm no old process or active take marker remains; the checked default Lowkey Support/Logs/timed-out folders are absent. Preserve both preference domains and all recovery data.

### Ordered changes

| Batch | Exact scope | Required result |
|---|---|---|
| 1 · Environment | `bin/khuluma-lib/identity.sh:5–80`: remove 63 `DICTATE_*` and two `LOWKEY_*` translations; remove normalization calls at CLI:18, identity:142, install:8 and build/sign/report/updater tools. Remove bootstrap:6–12 and Finder handler:14–24 copied alias loops. Remove `native/Sources/KhulumaCore/CLIEnvironment.swift:5–11` legacy config override. | Canonical custom config/model/sound roots still resolve. Obsolete routing overrides must fail before writes rather than silently creating another profile. Update identity/environment tests and canonicalise live fixture-generator inputs (`tests/gen_cleanup_fixtures.py:119,204`). |
| 2 · Command/schema | Remove `bin/tmux-whisper` and `bin/khuluma-lib/doctor_compat.py`; remove installer staging/shipping at `install.sh:155,171` and compatibility checks in `tests/test_identity_cli.sh:62–89` / `tests/ci.sh:10`. | Canonical help/version/defaults remain pure, doctor uses schema 2 and newly installed old commands are absent. Removing shipping entries alone does not retire existing owned local shims. |
| 3 · App/convenience | `native/Sources/KhulumaCore/CLIIdentity.swift:65–89`: canonical candidates only; remove shim wording:36. Remove launch imports at `native/Sources/Khuluma/main.swift:14–21`, `native/Sources/KhulumaCore/LegacyPreferences.swift` and `native/Sources/KhulumaCore/LegacyNames.swift` once readiness passes. Decouple `native/Sources/KhulumaCore/AppRuntimePaths.swift:49` and `native/Tests/KhulumaCoreTests/AppRuntimePathsTests.swift:60` from the deleted preference helper. Remove obsolete marker recognition at `native/Sources/KhulumaCore/Transcription/TakeMarker.swift:101,113–118`, daemon-name fallback at `bin/khuluma:1782`, Lowkey report-log/process fallback at `tools/khuluma-report.sh:17–19,318`, and deliberate old-bundle acceptance in `tools/build-khuluma-app.sh:126–134`. | Preserve canonical identity/root checks, preview isolation, lifecycle locks, unrelated-bundle refusal, competing-writer and wrong-signer rejection. Update focused discovery/environment/marker/preferences tests and remove obsolete alias/import expectations. |
| 4 · Package | Tap `Formula/khuluma.rb:15,22,56,74–78`: stop installing/wrapping/documenting/testing the old command. Update `release/homebrew-qa.py:198,270,278–279,308,316–317` to require canonical behavior and current-shim absence. | Fresh install, v0.9→next and v0.10→next upgrades retain one owner and unchanged profiles. Keep the tiny `formula_renames.json` package-ownership mapping independently of executable compatibility; retain the frozen v0.9 formula fixture. |
| 5 · Controlled rollout | Run current project checks, build matching source/app only where changed, use the existing dedicated signer and controlled idle switch. Recoverably retire only inspected owned active local shims; let the tested package upgrade manage Brew links, retain old kegs and backups. Repeat representative canonical caller/app checks. | Dictation, paste, cancel, Stats/settings, Finder and file transcription work with one canonical profile/model/daemon. Preserve app contract 3, config schema 1, wire 0.3.0 and unrelated installed apps. No app independence refactor. |
| 6 · Release/docs | Prepare a new immutable release, naturally v0.11.0 if still unused, with explicit breaking-interface notes and a measured archive checksum; update the matching formula and current README/AGENTS/integration guidance. | Never alter v0.9/v0.10 tags, archives or historical changelogs. Publish only after the immutable source/archive and matching package checks pass in this authorized implementation. |

### Keep and prove

- Keep fail-closed startup/root admission (`identity.sh:173–207`, `migration.sh:4–36`, `native/Sources/KhulumaCore/CLIIdentity.swift:44–61`), safe matching receipts and canonical source/pkgshare/library API checks. The retained old config/runtime roots still exist; they must never become alternate writers. There is no active old library-layout loader fallback to delete.
- Keep explicit migration/rollback and Finder transaction recovery as isolated operator facilities, not automatic runtime fallback. Preserve history/usage readers, raw data/models/sounds, old preference domains, closed recovery journals/copies and the shared Lowkey certificate actually used by KwikLog/MouseNav. DiskScan's old-storage classification is not a CLI caller.
- Verify canonical-only fixtures, meaningful existing shell/Swift suites and disposable Brew upgrades; do not weaken assertions just to remove old text. Retain historical writer fixtures. Adapt any invoked KwikCut tests that permanently delete fixture roots before running them under the recovery rule.
- Final acceptance uses the real daily app and representative synthetic file/caller checks after safe preparation. A failure restores retained code while preserving the latest authoritative data; never replay a closed migration journal or overwrite newer records with an old snapshot.

## Done

- 2026-10-23 · Verified canonical callers and preference APIs; staged compatibility removal in isolated worktrees, daily v0.10 untouched · caller-readiness-c8324fbf21

- 2026-10-23 · Planned canonical-only compatibility removal; replaced calendar wait with caller/runtime gates and corrected unsupported installed-KwikCut claim · Compatibility removal plan

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
