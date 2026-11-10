# Log

## Now

Pick up (Hex parity push): slice 1 built and checked in source (tests and snapshots pass), not installed · next: Ricardo's OK to install and try it, then slice 2 (vocabulary inside the model) · branch: wip/hex-parity

Hex parity push (Ricardo, 2026-11-10): after comparing Khuluma with anomalyco/hex, bring over what suits a Mac-only app, in slices on `wip/hex-parity`, each one a setting. Order and what was left out are in Next and Decisions.

Pick up (CLI sunset tab): keep list handed to the app tab (t4j) on 2026-11-05 · next: when it confirms the app runs without the CLI, prepare phase 4 (final v0.12.0 with notice, formula disable!) for Ricardo's yes · branch: wip/product-split

Installed build 470 on 2026-11-07 (Ricardo's OK, 9f412d4). Parakeet is selected for dictation. Both transcription actions appear in Finder under Services. Rollback: `~/Applications/.khuluma-app.V9Bt9W/previous.app` (build 464).

Installed build 449 on 2026-11-06 (app independence, Ricardo's OK): the app runs without the CLI and keeps its own data, imported from ~/.config/khuluma (copy only, left as rollback). Rollback: `~/Applications/.khuluma-app.NH9hiz/previous.app` (build 415). 14-day watch to 2026-11-20: no `khuluma` process started by the app; usage matches delivered takes in history. Until the CLI is retired, the CLI's daemon and the app's own daemon both hold the model. The CLI sunset (phase 4) can start now.

Focus from 2026-11-05: Khuluma is the app only; the CLI and Homebrew tap are being sunset (Decisions). Tab "Khuluma app without the CLI" (branch `wip/app-independence`, worktree `../khuluma-wt-app-independence`) makes the app independent and brings over what's kept: file transcription as a small command built into the app, and ElevenLabs Scribe. Tab "Khuluma CLI sunset" (branch `wip/product-split`, worktree `../khuluma-wt-product-split`) lists what the CLI does, then retires the CLI, formula and tap once the app no longer needs them. Apple Developer Program and the trademark search wait until then; the khuluma.app website runs in its own tab in VPS `products/Khuluma/site`.

Window and menu restyle (2026-11-05) is installed as build 415 from main: Stats, Settings and Vocabulary share one ink-and-ember look (Theme.swift; DESIGN.md), Settings has a four-page sidebar, and Activity keeps one height for every range. Ricardo approved it from a preview build. The menu dropdown matches, and the window now shows in Cmd-Tab and the Dock while open (Ricardo confirmed Cmd-Tab in the preview). Wired headphones and AirPods are still to try on the microphone picker (Next). App rollback is `~/Applications/.khuluma-app.aX5hsD/previous.app` (build 411).

Direction from 2026-10-27: Khuluma splits into two products. The Khuluma CLI, the free tool that grew out of the tmux-whisper setup, stays on the Homebrew tap and gets its SwiftBar integrations back. The native Swift dictation app becomes its own paid product, signed and notarised, installed from the App Store or a website download, not Homebrew. Phases 2, 4 and 5 and the SwiftBar, cask and App Store decisions below predate this and need re-planning (Next P1).

The user accepts the current dictation cleanup and Settings as working well; this work is closed for now. Further settings expansion, repeated-word cleanup and provider comparisons are parked below for a later session.

Khuluma v0.11.0 build 367 and its matching contract-5 CLI were installed from `4dcf33e` (superseded by build 383 on 2026-11-05). Source [CI](https://github.com/ricardo-calcina/khuluma/actions/runs/40016372572) and [Swift](https://github.com/ricardo-calcina/khuluma/actions/runs/40016372589) passed before cutover. The signed app relaunched on the native pipeline; doctor reports zero issues/warnings. A real 35-second take delivered through the native path after cutover. The installation preserved F17, config, existing vocabulary, icon preference/catalog and daemon binary/PID. The installer skipped warm-up and sound replacement; Homebrew and public releases are unchanged.

The installed Settings and vocabulary editor load the existing rules and export equivalent JSON. Installed CLI vocabulary save and filler/sentence/brand cleanup pass against a private synthetic profile. Cleanup is now enabled with Exact repeated sentences (level 3). The prepared vocabulary is active: 11 fillers, 28 brand rules and 7 other-word rules; all previous corrections survive. The installed app confirms the saved settings, and a combined filler/repetition/brand sample passes. A local replay of the latest 97-second dictation exactly reproduces the saved result, including removal of four hesitations. New tool-name variants are active; the separate sentence-repetition check passes. Personal vocabulary contents remain outside Git. The source combines menu/Stats/Settings, adaptive/animated icon themes, audio retention and vocabulary work in four grouped merges on main.

App recovery is `/Users/admin/Applications/.khuluma-app.Ma81E6/previous.app` (build 355). CLI/code receipts and installer backups remain recorded under `/private/tmp/khuluma-vocabulary-install-aef6o_rh/`; verification and preservation evidence are there too. Preserve newer user data when recovering. Continue the daily-use phase-0 observation before native-writer work.

## Next

- [ ] P1 · Install and try Hex parity slice 1 (needs Ricardo's OK): hold key, a real mute during a take with other audio playing, the indicator over a full-screen app · added 2026-11-10
- [x] P1 · Hex parity slice 1: hold-to-talk on its own shortcut (300 ms short-tap discard, 200 ms release tail), mute other audio while recording, keep Mac awake, on-screen recording/transcribing indicator; all off by default, in Settings › Dictation · added 2026-11-10
- [ ] P1 · Hex parity slice 2: vocabulary inside the model (FluidAudio 0.15.6 CTC rescoring in khulumad, extra ~98 MB model, off by default); measure on real kept takes before it ships · added 2026-11-10
- [ ] P1 · Hex parity slice 3: transcribe while recording, with whole-clip fallback; today stop→delivered is p50 1.2 s, p90 2.1 s, nearly all transcription (app.log, 211 takes); measure before it ships · added 2026-11-10
- [ ] P2 · Hex parity slice 4: History window with paste-last (already in phase 2), a Labs page for experiments, and "Keep microphone ready" (pre-roll; costs an always-on mic indicator, so opt-in) · added 2026-11-10

- [ ] P2 · Retire `~/.config/dictate` (pre-rename folder, untouched since 2026-10-22) so it can be binned. Still pointing at it: `~/.local/bin/tmux-whisper-lib/` (config.sh socket `~/.config/dictate/.cache/tmux-whisperd.sock` and sounds in `~/.local/share/sounds/dictate`, which is already gone) and `~/.local/bin/dictate-lib.sh`, both old tmux-whisper libs from 2026-10-21 (fits CLI sunset phase 4); `khuluma-lib/identity.sh` lines 107–119 treat `~/.config/dictate` as the legacy marker for rename-v1, so confirm removing it doesn't re-trigger or break that check; `~/.config/khuluma/tools/pad-sfx.sh` examples still say `sounds/dictate`. Then bin the remaining install leftovers once rollback isn't needed: `.khuluma-install.*` (2026-11-05) and `.khuluma-cutover-*` in `~/.local/bin`, `~/.local/share/khuluma`, `~/.config/khuluma`, plus `~/.config/khuluma/.migration` (rename-v1, committed) · added 2026-11-08
- [x] P2 · Try Finder Local and Cloud on the same file with quiet speech and laughter and compare output and timing · added 2026-11-06

- [ ] P2 · Swift tests leave their temp fixture roots behind on purpose (RetainedTestArtifacts): ~4,900 `$TMPDIR/khuluma-*` dirs, 145 MB from 5-6 Nov runs; macOS sweeps them after ~3 days unused. DaemonKit tests do the same in /private/tmp (1,332 `khuluma-kit-*`, 0.4 MB). Proposal: delete a test's root when it passes, keep it on failure. Needs Ricardo's yes, since retention was deliberate · added 2026-11-06
- [ ] P2 · tests/test_app_build_helpers.py fails 8/36 on main (same before 34c0ac1): the fixture's mock git doesn't answer the build script's dirty-tree check, so success-path cases stop at "Working tree has uncommitted changes" · added 2026-11-06
- [ ] P3 · Experiment with selectable app themes (e.g. Dracula, Catppuccin) and an ivory light variant; Theme.swift tokens are structured for it (Ricardo, 2026-11-06) · added 2026-11-06
- [ ] P2 · Speaking-pace WPM on build 458: Ricardo is trying it in daily use and reports any issue; check new history entries carry metrics.speech_ms and usage.json gains pause_duration_ms · added 2026-11-06
- [ ] P1 · Watch build 449 for 14 days (to 2026-11-20): no `khuluma` process started by the app, usage matches delivered takes in history, nothing lost; first-run on a clean account not tested (Ricardo skipped it) · added 2026-11-06
- [ ] P2 · After the 14-day watch and the CLI sunset: write up why Khuluma became app-only (the reasons, what moved into the app, what was dropped, how the import works) for Ricardo's blog, and add a public roadmap page to the khuluma.app site (VPS products/Khuluma/site, its own tab) · added 2026-11-06
- [ ] P1 · Sunset the CLI: inventory and keep list done (docs/plans/CLI_SUNSET.md, confirmed 2026-11-05) and ROADMAP re-planned; next the app tab ports what's kept, then phase 4 (final release, disable formula, remove from the Mac) and phase 5 (remove CLI code, archive tap), each publishing step needing Ricardo's yes · added 2026-10-27, changed 2026-11-05
- [x] P1 · Enable cleanup and exact repeated sentences; import the prepared vocabulary and verify active output · added 2026-10-24
- [x] P1 · Combine the approved menu, icon, audio and vocabulary branches on main; verify the integrated source · added 2026-10-24
- [x] P1 · Audit saved dictation and prepare conservative hesitation/sentence/brand cleanup in source · added 2026-10-23
- [x] P1 · Expose cleanup and one sectioned vocabulary editor with reviewed JSON import/export in Settings · added 2026-10-23
- [x] P1 · Install the merged contract-5 app/CLI together after CI; verify Settings/editor, export, health and preserved daemon · added 2026-10-23
- [x] P1 · Confirm a real delivered take from installed build 367 on the contract-5 native pipeline · added 2026-10-24
- [x] P1 · Build useful menu panel and integrated Settings with shortcut capture and opt-in Scribe · added 2026-10-23
- [x] P1 · Install the approved menu/Settings app and matching CLI, preserving data/daemon and verifying daily use · added 2026-10-23
- [x] P1 · Review the full identity rename plan · added 2026-10-22
- [x] P1 · Complete isolated rename/migration/recovery acceptance, controlled daily cutover and source/tap integration · added 2026-10-22

- [ ] P1 · Before phase 2: search UKIPO and EUIPO by hand for KHULUMA (khuluma.app bought by Ricardo 2026-11-05) · added 2026-10-17
- [ ] P1 · khuluma.app website: decide what it offers before the signed app exists (waitlist, the free CLI, or both); build it in VPS products/Khuluma/site, reusing the approved studio-site Khuluma page copy · added 2026-11-05
- [x] P1 · Install raised adaptive light/dark app icon and 18 pt menu glyph; verify Finder automatic switching · added 2026-10-17
- [ ] P1 · Join the Apple Developer Program before phase 2 (after app independence and the split, Ricardo 2026-11-05) · added 2026-10-15
- [ ] P1 · Phase 0 gate: a week of daily use, then `tools/khuluma-report.sh` gates still met · added 2026-10-17
- [ ] P1 · Phase 1 step 1: native usage ledger and history writer, proven against the CLI with shared fixtures (removes `inline record`) · added 2026-10-17
- [ ] P1 · Phase 1 after the native writers: port config, bundle and supervise the daemon, add model download and bundled sounds, then port or drop CLI fallbacks; keep shared files/locks compatible while both writers exist · added 2026-10-22
- [ ] P1 · Phase 1 delivery: use PostEvent permission gates and a bundled child daemon; verify clean-account dictation/Stats/history without CLI and 14 days without CLI invocations or usage mismatch before calling it independent · added 2026-10-22
- [ ] P2 · Add “Show app icon in Dock” next to the Open at login setting · added 2026-10-24
- [ ] P2 · Clarify the Repetition selector with plain labels and before/after examples; explain each option’s scope, preserved repeats and how it interacts with cleanup · added 2026-10-24
- [ ] P2 · Audit existing CLI/config options against the app Settings; identify useful controls still missing from the UI before expanding it · added 2026-10-24
- [ ] P2 · Cleanup round (after the split): better transcript cleanup with selectable levels, including an optional cloud model; covers the repetition labels, repeated-word cleanup and Parakeet vs Scribe items · added 2026-11-05
- [ ] P2 · Test conservative repeated-word cleanup such as “don't don't”, preserving intentional emphasis and grammatical doubles · added 2026-10-24
- [ ] P2 · Compare Parakeet and ElevenLabs Scribe on real repeats, intonation and laughter/non-speech output; verify provider behavior before choosing cleanup rules · added 2026-10-24
- [x] P2 · Remove old command/env/app compatibility after canonical-only caller and daily-app checks · added 2026-10-23
- [x] P2 · Align formula updater and intact source/tap siblings at khuluma and homebrew-tap · added 2026-10-22
- [ ] P2 · Paste retried dictation from the menu refuses while the Khuluma window is frontmost (pre-existing; Terra review): capture and restore an external target for that path · added 2026-11-05
- [ ] P2 · Check live on build 415: Settings sidebar Tab/arrow focus and VoiceOver; Vocabulary tab-strip arrows and in-place editing (Activity hover confirmed fine 2026-11-05) · added 2026-11-05
- [ ] P2 · Finish the microphone picker hardware checks (iPhone Continuity mic confirmed on build 398; it takes ~2.2 s to start, so speak after the chime): wired headphones and AirPods, pick the current default explicitly, unplug the chosen mic between takes and mid-take; each take's `audio: take input requested=… actual=… fallback=…` line in ~/Library/Logs/Khuluma/app.log should match · added 2026-11-05
- [ ] P3 · Vocabulary examples are keyed by Said text: a repeat replaces, and duplicate Said rows in an imported file share one table row (Terra review, same as before the editor change) · added 2026-11-05
- [x] P2 · Menu: microphone picker (native submenu under the figures, current input shown; same choice in Settings → Dictation; falls back to the system default when the chosen mic is missing) · added 2026-11-05
- [x] P2 · Vocabulary tab as a standard Mac list editor: editable table, +/− under it, Import/Export in an action menu, keep the draft/Save model · added 2026-11-05
- [ ] P3 · Visual identity (colour, Ndebele/cursed-speech motifs) parked: 2026-10-30 Stats concepts read as non-Mac; keep the native look and current layout until a subtler direction comes up · added 2026-10-30
- [ ] P2 · Stats stage 3 ideas (not committed): weeks view, wpm trend, typing_wpm config, time of day, opt-in per-app · added 2026-10-16
- [x] P2 · Use total words, estimated time saved and average WPM in the menu and Stats summary · added 2026-10-23
- [ ] P2 · Review the existing file-transcription entry/output flow before choosing a drag target · added 2026-10-23
- [x] P2 · Choose and install cursed-speech set 1 Recording/Finishing replacements; preserve set 2 · added 2026-10-23
- [x] P2 · Slowly rotate the Processing fang seal, including menu tracking and Reduce Motion stop/resume · added 2026-10-23
- [x] P2 · Install and verify rounder Recording mouth and immediate Settings switch between both status icon themes · added 2026-10-23
- [ ] P2 · Lowkey ideas parked from 3c, only with evidence: config file watcher, warm mic/pre-roll · added 2026-10-16
- [ ] P2 · Phase 2 after phases 4-5: Developer ID signing/notarisation, versioned .dmg from khuluma.app with Sparkle (no cask); History window; verify fresh-Mac permissions · added 2026-10-22, changed 2026-11-05
- [ ] P2 · Phase 4 after phase 1 exits: final CLI release v0.12.0 with a retirement notice, formula disable!, then remove the CLI from Ricardo's Mac after a week with no CLI calls (ROADMAP.md) · added 2026-10-22, changed 2026-11-05
- [ ] P2 · Phase 5: remove the CLI code, tests, ci.yml and docs from the repo (keep cleanup fixtures and khuluma-report.sh), update the transcribe-audio skill, archive ricardo-calcina/homebrew-tap a few weeks after the disable · added 2026-10-22, changed 2026-11-05
- [ ] P3 · Deferred separate labs: voxtral-inline API/realtime dictation and faster-whisper-tool batch/subtitle/offline exploration; only after core reliability is stable · added 2026-10-22

## Decisions

- Hex parity (Ricardo, 2026-11-10): tap to start and stop stays the default; hold-to-talk is a second shortcut, off until set. The on-screen indicator, mute other audio and keep-awake are switches, off by default (Ricardo prefers the menu bar to a HUD). Mute, not media pause: pausing other apps needs a private macOS API. Pre-roll is left for slice 4: first audio arrives ~210 ms after the key and the chime follows it, so tap-to-talk loses nothing today. Not brought over: cross-platform, meetings, Annotate, local API/SDK, TypeScript config, LLM rewriting. Sparkle and onboarding stay in phase 2.

- Checks and worktrees (Ricardo, 2026-11-06): local checks run only what a change affects, through `tools/test-affected.sh` (CONTRIBUTING.md, "Validation Requirements"); the full Swift suite is CI's job on push, locally only for `Package.swift` or cross-cutting changes, or before an install when CI isn't available. For Khuluma, tabs work in the main checkout and share `native/.build` (~1.4 GB each), committing only their own files; a worktree only when two tabs must edit the same files.
- App data (Ricardo, 2026-11-05): the app keeps its data in `~/Library/Application Support/Khuluma`, settings in `settings.json`, bench.tsv dropped, a one-time copy-only import from `~/.config/khuluma` (the source stays as the rollback); Scribe ported (Keychain, then the CLI's zshrc lookup); the app runs its own bundled daemon. The shared data contract and writer tags are withdrawn with the sunset. Details in docs/plans/APP_INDEPENDENCE.md.
- CLI sunset (Ricardo, 2026-11-05; replaces the 2026-10-27 two-product split): Khuluma is the native app only. Ricardo doesn't use the CLI from the terminal or tmux and won't maintain a separate tool or tap. What's kept moves into the app (file transcription as a small command built into the app, which the transcribe-audio skill uses; ElevenLabs Scribe). Then the CLI, its formula and the tap are retired. No long-term app and CLI sharing of data: a one-time import into the app instead.
- Microphone choice stays a submenu row in the menu, not an inline ticked list (tried in f983018, reverted 2026-11-05): Ricardo rarely switches and mostly stays on System Default; the row only needs to show the input in use. The case for choosing is two inputs at once, e.g. recording a video on the phone while Khuluma keeps the MacBook mic.
- Icon/theme recovery: `/Users/admin/Applications/.khuluma-app.74v7dj/previous.app` retains signed build 353; current QA is at `/private/tmp/khuluma-themes-qa.RxaJYA/`. `.khuluma-app.xMyT3X/previous.app` retains build 351, `.khuluma-app.atWD6N/previous.app` build 347, `.khuluma-app.LYC8GT/previous.app` build 342 and `.khuluma-app.LYfteh/previous.app` build 340. Earlier motion/status/app-icon QA remains under `/private/tmp/khuluma-{motion,status,icons}-qa.*` as recorded in `assets/icons/README.md`. Preserve newer user data when recovering.

- Local menu/Settings cutover recovery: `/Users/admin/Applications/.khuluma-live.qBasYG/previous.app` retains build 332; `code-manifest.json` and code backups retain the matching prior local CLI/receipt. Preserve newer usage/history when recovering.

- Prefer canonical-only interfaces. v0.11.0 removed ordinary old command/environment/app compatibility after concrete caller and daily-workflow checks, superseding the former 30-day identity wait. Preserve data, historical releases, explicit recovery and wrong-profile/competing-writer refusals. The completed per-file removal plan remains in Git at `8da982b:LOG.md`; source #85 records implementation.
- Recovery on this Mac remains under `/Users/admin/Documents/Codex/2026-10-22/all-right-next-i-want-to/work/`: `khuluma-live-cutover/`, `khuluma-implementation-evidence/local-brew-recovery-3kf3c92v/` and `khuluma-compat-2026-10-23/`. The committed data manifest is `~/.config/khuluma/.migration/rename-v1/manifest.json`. Closed controller journals are historical: never replay them or restore an old snapshot over newer user work.

- Khuluma is the product; local, fast dictation and never losing a take remain the priorities. The CLI is its back end until native replacements are proven. Keep shared-file and locking contracts while the app and CLI share those files.
- Name chosen: Khuluma. Approved rename target is bundle `com.ricardo-nth.khuluma` with a separate `Khuluma Local Code Signing` identity; preserve the existing Lowkey identity and data for other apps/rollback. The controlled cutover and final v0.10.0 app acceptance passed. Name research is dated in `docs/plans/KHULUMA_NAME_CHECK.md`; official UK/EU checks remain open above.
- Distribution: a notarised .dmg from khuluma.app with Sparkle; no Homebrew cask (the tap is retired); Mac App Store parked, the archived roadmap keeps the sandbox research (2026-11-05).
- Tmux capture, CLI recording, LLM rewriting, silence trim, bash chunking, Raycast and SwiftBar were dropped; reintroduce none without evidence. Usage, Stats and logs keep counts/timings, not transcript text; history and pending recovery are the intentional text stores.
- Rename the existing repository in place to preserve all history; retain neutral `ricardo-calcina/tap` and rename its formula to `khuluma`. The in-place repository rename, immutable v0.10.0 release and canonical formula/map are published and verified. The app continues to depend on its matching CLI; cask/CLI-independence/deprecation/archive are separate future work.

## Done

- 2026-11-10 · Hex parity slice 1 in source: hold-to-talk on a second shortcut, mute other audio, keep Mac awake, on-screen indicator, all off by default; policy tests and snapshots pass, not installed · wip/hex-parity, CHANGELOG Unreleased

- 2026-11-08 · Machine tidy-up binned the October `.khuluma-install.*`/`.khuluma-cutover-*` leftovers and `*.bak.*` config copies in `~/.config/khuluma` and `~/.config/dictate`; kept the app rollback `~/Applications/.khuluma-app.V9Bt9W`, the 2026-11-05 install dirs and `.migration` · chief tab
- 2026-11-07 · Moved the old Automator Finder workflow to the Bin; verified only Local and Cloud remain on a WAV · build 470

- 2026-11-07 · Build 470 Finder test on one 8.6 s clip: both caught quiet speech, Scribe added `[laughs]`; Parakeet 0.47 s, Scribe 1.81 s after upload confirmation · 9f412d4

- 2026-11-07 · Installed build 470 and verified both new Finder Services on a WAV; dictation still uses Parakeet · 9f412d4

- 2026-11-06 · Added Scribe sound labels switch and independent Local and Cloud Finder actions in source · CHANGELOG Unreleased

- 2026-11-06 · Checked native Scribe routing, recovery and account authentication; 30 focused tests passed. Corrected file tool docs; no audio uploaded · README.md

- 2026-11-06 · Light mode is white (warm-neutral tracks, re-tuned ember ramp), title bar tabs centred with hover, custom Words per day switch and range control, no ≈ on Time saved; dark unchanged; Codex review; installed as build 464, now the stable version (old rollbacks binned at Ricardo's request) · 6e0559b, DESIGN.md Colors
- 2026-11-06 · Moved ~2.6 GB of old /private/tmp Khuluma build and preview folders to the Bin (Ricardo's yes) · LOG Next
- 2026-11-06 · Affected-only checks: tools/test-affected.sh picks builds, suites and the isolated UI snapshot from the changed files (fail safe, two Codex reviews); CONTRIBUTING and AGENTS make it the default · tools/test_affected.py
- 2026-11-06 · WPM measures speaking time (pauses over 1 s left out, via Parakeet/Scribe word timings; time saved too); real takes 185 → 194 WPM; two Codex reviews; installed as build 458 · db4a4aa, CHANGELOG Unreleased
- 2026-11-06 · App independence merged and installed as build 449: own data folder + one-time import, bundled daemon and model download, Scribe, khuluma transcribe/Quick Action in the app, no CLI calls · docs/plans/APP_INDEPENDENCE.md, CHANGELOG Unreleased
- 2026-11-06 · App independence: Scribe, khuluma transcribe/Quick Action and no CLI calls (slices E-G); three isolated acceptance runs (import matches his data, own daemon, model download, recovery, quit) · wip/app-independence a79c4fa
- 2026-11-05 · CLI sunset inventory and keep list confirmed (Finder action and transcribe kept, history readers dropped); ROADMAP re-planned for phases 1, 4, 5 then 2 · docs/plans/CLI_SUNSET.md
- 2026-11-05 · App-independence plan reviewed by two Codex Sol runs and re-planned app-only after the sunset decision; shared data contract withdrawn · docs/plans/APP_INDEPENDENCE.md
- 2026-11-05 · Ricardo bought the khuluma.app domain · Next
- 2026-11-05 · Ricardo confirmed a take on the iPhone Continuity mic on build 398 (requested = actual, fallback none, delivered); design refresh settled · app.log 11:16Z
- 2026-11-05 · Installed build 398 (app only; daemon kept, doctor healthy) · ~/Applications/.khuluma-app.TEUOtl/previous.app
- 2026-11-05 · Pinned mics start on their real hardware format (iPhone Continuity mic failed on 391), checked converter per Codex Terra review, Cancel Recording on the Recording row; inline mic list tried and reverted · 15793b2, 7dc3db8
- 2026-11-05 · Installed build 391 from d99bd84 (app only; CLI and daemon unchanged, doctor healthy) · ~/Applications/.khuluma-app.f7GuFA/previous.app
- 2026-11-05 · Microphone picker in the menu and Settings with a take-safe engine policy; two Codex Sol reviews, fixes in b8fd358 and 7bf864e · d99bd84
- 2026-11-05 · Installed build 415: menu restyle, ember Auto-send switch, recording emblem and Cancel capsule, window in Cmd-Tab/Dock while open (AppMainMenu.swift); doctor 0/0 · ~/Applications/.khuluma-app.aX5hsD/previous.app
- 2026-11-05 · Menu dropdown restyled to match (ink figures, ember 7-day bars, red recording mic); not installed yet · 2b40e75
- 2026-11-05 · Installed build 411 (app only; CLI unchanged): ink-and-ember Stats, Settings sidebar, Vocabulary restyle; doctor 0 issues/0 warnings · ~/Applications/.khuluma-app.d3jzzj/previous.app
- 2026-11-05 · Settings sidebar (4 pages) and Vocabulary restyle in the Stats language, ember accent; built by Opus/Sonnet workers, reviewed by Codex Terra, review fixes in c58a8e8 and 89400bd; not installed yet · CHANGELOG Unreleased
- 2026-11-05 · Stats window restyled in one ink (like the icon), hairlines not boxes, ring marks, small caps labels; Activity one height for all ranges, heatmap centred, hover readout in the range line; window starts 560×712; not installed yet · CHANGELOG Unreleased
- 2026-11-05 · Stats Activity adapts: heatmap fills the width with Words per day off, chart beside it on 30 days and under it on 60/90; hover line fixed width;  203 Swift tests pass; not installed yet · CHANGELOG Unreleased
- 2026-11-05 · Paste without sending confirmed on build 398: a real Shift+F5 take pasted and was not sent · app.log 12:46Z
- 2026-11-05 · Vocabulary tab rebuilt as a standard Mac list editor; Codex Terra review fixes in a7bb4fe · 4d904cc
- 2026-11-05 · Installed build 383 and matching CLI from main (30 Oct tabs, menu figures/7-day strip, Auto-send switch, paste without sending); daemon kept, doctor healthy · ~/Applications/.khuluma-app.5r9WGE/previous.app
- 2026-10-27 · #88 merged; app rebuilt from main and installed as build 377 (rollback ~/Applications/.khuluma-app.1OP0aL/previous.app); a real 14 s take delivered warm on the native path (total 1.3 s) with the shared FluidAudio model · app.log 12:15Z
- 2026-10-27 · khulumad on FluidAudio 0.15.6 (exact); my config's model_path now points at FluidAudio's shared cache (~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3), so Khuluma and the Kwik apps share one Parakeet v3 copy; same transcript as before on a 30 s clip at the same warm speed (2-3 s); 164 Swift tests and tests/ci.sh pass; the app was restarted to pick up the new path · CHANGELOG Unreleased
- 2026-10-24 · Updated active GitHub references for ricardo-calcina; app identifiers and historical evidence preserved · GitHub username migration

- 2026-10-24 · Logged future Dock visibility control beside menu bar icons and clearer repetition choices/examples; implementation deferred · Next

- 2026-10-24 · User accepted daily cleanup and Settings; parked missing CLI controls, word repeats and provider comparison for later · build 367; Next

- 2026-10-24 · Latest local audio replay matches saved cleanup; added eight tool-name aliases with backup; installed UI and combined cleanup pass, history unchanged · /private/tmp/khuluma-latest-dictation-audit-18nx83jr/

- 2026-10-24 · Enabled cleanup/level 3 and imported vocabulary; native UI and saved-config/output checks pass, previous corrections retained · /private/tmp/khuluma-vocabulary-activation-5_6hfxzx/verification.json

- 2026-10-24 · Installed signed build367/contract-5 CLI after hosted CI; installed editor/export/private cleanup/doctor and real native take pass; config/vocab/daemon preserved · 4dcf33e; /private/tmp/khuluma-vocabulary-install-aef6o_rh/

- 2026-10-24 · Combined four approved branches; full CI/164 Swift/36 helper/44 render/native editor-export-theme checks pass; daily runtime unchanged · 4064293, ef6866c, f83b614, 89eb00b

- 2026-10-23 · Installed migration-link expiry fix; removed 13 expired archive names, preserving 79 transcripts/31 recent WAVs/recovery links/Trash; real take saved history without new Trash WAV · 54a4350; /private/tmp/khuluma-audio-install-g4pgzkti/manifest.json

- 2026-10-23 · Installed CLI audio cleanup; private installed history/48-hour expiry/retry, doctor and signature checks pass; app/config/daemon unchanged · 5031d94; /private/tmp/khuluma-audio-install-cuixo7za/manifest.json

- 2026-10-23 · Audio cleanup saves history before deleting working WAVs; archive expiry uses 48 hours without Trash; 292 flow/provider/5 deletion-boundary checks pass · bin/khuluma-lib/audio_cleanup.py

- 2026-10-23 · Installed signed build 355 round Recording mouth and both Settings themes; 36 helper/32 static/98 motion/native Picker/relaunch/signature/doctor checks pass, config/daemon/catalog preserved · 2b460a9; assets/icons/README.md

- 2026-10-23 · Installed signed build 353 with slow Processing rotation; timed/menu-open/phase/Reduce Motion/static/signature/doctor checks pass, config/daemon/assets preserved · fb06b5b; assets/icons/README.md

- 2026-10-23 · Added Settings cleanup and one JSON vocabulary with reviewed import/export, Undo, backups and conflict guards; build/CI/19 Swift/967 parity/native UI checks pass; source only · native/Sources/Khuluma/Settings; docs/CLI_CONTRACTS.md

- 2026-10-23 · Prepared conservative hesitation/sentence cleanup and brand punctuation fixes; 69-take private replay 108→0 hesitations, shell checks/15 Swift tests/962 parity cases pass; daily runtime unchanged · native/Sources/KhulumaCore/Cleanup; feat/dictation-cleanup

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
