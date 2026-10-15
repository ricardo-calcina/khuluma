# Lowkey roadmap: rename, CLI sunset, App Store later

Status: approved (2026-10-15). Phases 0–5 are the plan; phase 6 (Mac App Store) is parked until Lowkey has proven itself in daily use and been improved further. Start with phase 0. Nothing is renamed by this document. Follows phase 3c (`LOWKEY_PHASE3C_PLAN.md`) and the stats window (`LOWKEY_STATS_PLAN.md`).

Three goals, in order of commitment:
1. **Rename the project to Lowkey.** Lowkey (`tmux-whisperd/`, bundle id `com.ricardo-nth.lowkey`) is already the daily driver; "tmux-whisper" describes the CLI's tmux flow, which is no longer the main path.
2. **Make Lowkey the main tool**, then sunset the bash CLI (`bin/tmux-whisper`) and archive the `tmux-whisper` repo.
3. **Maybe list Lowkey on the Mac App Store, later.** Parked: no work planned. The research in "App Store blockers" stays here so a sandboxed build isn't designed out by accident.

## Decisions this roadmap proposes
- **New repo, archive the old one** (recommended; confirm in phase 0) rather than renaming `ricardo-nth/tmux-whisper` in place. Lowkey moves to `ricardo-nth/lowkey` with its history (`git filter-repo` on `tmux-whisperd/`, `docs/plans/LOWKEY_*`, `tools/*lowkey*`). The old repo gets a final CLI release and is archived. Archive URLs (Homebrew formula, `bootstrap.sh`, release tarballs) keep working without depending on rename redirects, and an archived repo can't be confused with the live product. The cost: issues, stars and watchers stay behind (transfer the open ones). Renaming in place keeps them, but then there's no repo to archive, and the redirects break if anything is ever created under the old name. GitHub doesn't promise that rename redirects cover tag archives or `raw.githubusercontent.com` links, which are exactly what the formula and `bootstrap.sh` use ([gh-rename]). Archiving makes code, releases, issues and PRs read-only, and doesn't close open issues ([gh-archive]).
- **Direct download only for now.** Ship Lowkey signed with Developer ID and notarized, as a Homebrew cask in `ricardo-nth/tap`. The App Store needs a sandboxed build with a different shape (see blockers) and is parked.
- **Keep the bundle id** `com.ricardo-nth.lowkey`. It's already Lowkey's. Moving from the local self-signed identity to Developer ID changes the signing identity, so Microphone and Accessibility are granted once more. TCC identifies an app by bundle id **plus** its code requirement, and the self-signed requirement very likely won't match a Developer ID signature ([tcc-identity], [tn2206], [dts-tcc]). The same applies to a later move to App Store signing, which isn't documented as preserving grants: test it.
- **The tmux flow ends with the CLI.** Lowkey already pastes into the frontmost app, terminals included. tmux's distinct features (origin-pane targeting, the async queue) aren't carried over unless real use shows they're missed.

## What depends on the names today

| Surface | Name today | Who depends on it | At rename | At sunset |
| --- | --- | --- | --- | --- |
| GitHub repo | `ricardo-nth/tmux-whisper` | Formula `url` (tag archives), `bootstrap.sh` (`--repo`, raw URLs), README badges and links, install receipts (`source=`), issue links in docs and CHANGELOG, `AGENTS.md` and `docs/agents/issue-tracker.md` | New repo `ricardo-nth/lowkey`; old repo untouched | Final CLI release, README points to Lowkey, archive |
| Homebrew | formula `ricardo-nth/tap/tmux-whisper` (CLI only, at v0.9.0; doesn't ship Lowkey) | `brew install/upgrade` users; `tools/update-homebrew-formula.sh`; `docs/RELEASE_CHECKLIST.md` | Add cask `lowkey` (notarized `.app`). Formula unchanged | `deprecate!` with a date and `replacement_cask: "lowkey"`, later `disable!` ([brew-deprecate]) |
| Config and data | `~/.config/dictate/` (`config.toml`, `.config.toml.last-good`, `current-mode`, `modes/`, `vocab`, `history/*.json`, `history/bench.tsv`, `usage.json`, `install-receipt.env`, `backups/`), daemon socket `~/.config/dictate/.cache/tmux-whisperd.sock`, sounds `~/.local/share/sounds/dictate/`, models `~/.local/share/tmux-whisper/models/` | The CLI (writer of everything), Lowkey (reads config only through `app-config --json`, but watches `usage.json` directly in `StatsModel.swift` and talks to the socket path `app-config` gives it) | Unchanged | Lowkey owns its data under `~/Library/Application Support/Lowkey/` (the sandbox container, if the App Store happens), with a one-time import from `~/.config/dictate` |
| Runtime state | `/tmp/dictate-processing/` markers, `/tmp/whisper-dictate*.state`, `<socket>.lifecycle.lock`, ~126 `DICTATE_*` env vars (the plugin-only `/tmp` flags went in #63) | CLI ↔ Lowkey idle checks and lifecycle lock, the daemon's idle check before upgrades | Unchanged | Private to Lowkey; env vars dropped (settings live in config) |
| CLI contracts (`docs/CLI_CONTRACTS.md`) | `tmux-whisper <cmd> --json` | Lowkey (`app-config`, `inline process/record/cleanup`, `warmup`, `usage`), the `transcribe-audio` agent skill, any script of yours | Frozen: additive fields only, no renames | Final version documented; no new fields |
| `usage --json` | `schema_version` 1 (+ `--days`) | Lowkey stats window (`usage --json --days all`); SwiftBar until #62 | Unchanged | Replaced by Lowkey reading its own ledger; the JSON shape is kept as Lowkey's export format so the stats code doesn't change |
| Raycast scripts | `integrations/raycast/tmux-whisper-{inline,toggle,cancel}.sh`, package "Tmux Whisper" | Nobody on your machine since 2026-10-15 (Lowkey owns the dictation key, F17, and Ctrl+Esc cancels) | Removed in phase 0's tidy-up, with `integrations doctor/repair` | Gone |
| SwiftBar plugin | `tmux-whisper-status.0.2s.sh` | Retired in #62 (2026-10-15); only the `tmux-whisper swiftbar` notice stub is left | Stub removed in phase 0's tidy-up | Gone |
| Finder Quick Action, `transcribe` | `Transcribe with Tmux Whisper.workflow`, `tmux-whisper transcribe` | Finder users; the `transcribe-audio` skill in `~/.claude/skills` and `~/.codex/skills` (and `integrations/agents/`) | Unchanged | Needs a replacement first (see below) |
| Lowkey app | bundle id `com.ricardo-nth.lowkey`, `~/Library/Logs/Lowkey`, `~/Library/Application Support/Lowkey/` | TCC grants (Microphone, Accessibility), Login Items (`SMAppService`), `tools/lowkey-report.sh` | Already named Lowkey | Unchanged |
| Lowkey's text | "tmux-whisper CLI not found", "Update tmux-whisper for daily stats", "Couldn't load stats from tmux-whisper" (`CLIBridge.swift`, `AppController.swift`, `StatsView.swift`) | Users | Unchanged while the CLI is required | Gone with the CLI dependency |
| Daemon | `tmux-whisperd`, Swift package `tmux-whisperd`, library `TmuxWhisperKit` | CLI builds it from source (`swift build` in `pkgshare`/`~/.local/share/tmux-whisper`) on first use; Lowkey connects to its socket | Unchanged | Bundled inside Lowkey.app (as `lowkeyd` or an XPC service); package renamed with the repo move |

## What Lowkey still needs from the CLI
Today Lowkey's happy path (hotkey → capture → Parakeet over the socket → Swift cleanup → paste) doesn't touch the CLI, but everything around it does. From `CLIBridge.swift`:

| Need | CLI call today | What Lowkey needs instead |
| --- | --- | --- |
| **Settings** | `app-config --json` at launch and on config change (hotkey, sounds, inline delivery, cleanup, transcription, pipeline, capabilities). The CLI parses TOML, applies `DICTATE_*` overrides, validates, keeps `.config.toml.last-good` | A Swift config reader/writer with the same validation and last-good fallback, and a Settings window for what's now set with CLI commands (`autosend`, `mode`, `vocab add/import`, paste target, sounds, hotkey). Config file format unchanged during the overlap so both can read it |
| **History** | `inline record --json` writes `history/*.json` (7-day retention, 2-day audio), plus the `[debug] keep_logs` archive | A Swift history writer with the same file format and retention, then a History window (search, copy, re-paste) to replace `history list/search/export`, `last` and `replay` |
| **Usage** | `inline record` (`usage_only` for deferred takes) writes `usage.json` under its lock, take-id dedupe, per-day buckets; `usage --json --days all` reads it for Stats | A Swift ledger writer with the same exactly-once semantics (locked write, take-id dedupe, validation rules, the `untracked_deliveries` handling) proven against the CLI's writer with shared fixtures, as 3a did for cleanup |
| **Bench** | `inline record` appends `history/bench.tsv` (`app:native`), trimmed under a lock | Replaced by the `take:` line in `app.log` and `tools/lowkey-report.sh`, which already carry more. Drop `bench.tsv` at sunset |
| **Cleanup fallback** | `inline cleanup --json` (shadow compare, `[app] verify_pipeline`) | Nothing: retire verify once the parity window closes (it's a rollout check) |
| **Processing fallback** | `inline process --json [--defer-usage]` for LLM post-processing, silence trim, chunking, a non-C CLI locale, an unreachable daemon, any native error, and Retry of timed-out takes | Native versions of what's still used: silence trim and chunking (or drop them), and LLM post-processing (port it with the API key in the Keychain, or drop it). An unreachable daemon becomes Lowkey's own problem once it owns the daemon |
| **Daemon lifecycle** | `warmup --json` starts or replaces `tmux-whisperd` under the lifecycle lock; the CLI builds the daemon from source with `swift build` if needed | Lowkey ships the daemon prebuilt in its bundle and owns start, upgrade and stop (as a child process of Lowkey, phase 1; an XPC service only if the App Store build needs one). The lifecycle lock stays while the CLI still runs. Rebuilding from source goes away |
| **Model** | None: the README says install doesn't download models; the user places Parakeet in `~/.local/share/tmux-whisper/models/` | A first-run download with consent and size shown (FluidAudio can fetch from Hugging Face), checksum check, resumable, stored under Application Support |
| **Recovered takes** | `inline record` with status `recovered` at quit/next launch | Same, through the native history writer |
| **File transcription** | `tmux-whisper transcribe`, Finder Quick Action, the agent skill | Drag-and-drop onto Lowkey or a "Transcribe File…" menu item, plus a small command-line tool for agents. The direct-download build can ship a `lowkey` CLI inside the bundle (`Contents/MacOS/lowkey`, symlinked by the cask); it talks to the running app or daemon, not the bash CLI |
| **Sounds** | Paths from `app-config` (`~/.local/share/sounds/dictate`) | Bundled default sounds in the app; custom sounds chosen in Settings |

Anything not listed (tmux flow, CLI inline capture, `bench-matrix`, `budget`, `keybind`, `swiftbar`, `integrations doctor/repair`, `watch`, `logs follow`, `devices`, `doctor`) is CLI-only operator surface that ends with the CLI. `doctor` and `debug` get a slim equivalent in Lowkey's menu (an "About and diagnostics" view, copying a transcript-free report).

## Phases

### Phase 0 (P0): check the name, then review and tidy the codebase
Two pieces of work before anything is renamed or ported, so the rename and phase 1 only touch code that survives.

**P0a. Name check.** The last cheap moment to change the name: after phase 2 it's in the repo, the cask, the bundle and your TCC grants.
- What's known (2026-10-14): an App Store name can be used by one app per localization, and only App Store Connect says whether it's free ([asc-name]). Existing "Lowkey" apps: an iPhone group chat app ([lowkey-chat]), lowkey.fyi on iPhone/iPad ([lowkey-fyi]), and a gaming-clips product acquired by Niantic ([lowkey-yc]). No native Mac app named exactly "Lowkey" or "Lowkey Dictation" was found, which doesn't prove the name is free. Trademarks weren't checked.
- Check: trademark registers (USPTO, UKIPO, EUIPO) in software classes (9, 42); the Mac and iOS App Stores; `ricardo-nth/lowkey` on GitHub and a cask named `lowkey` in `homebrew/cask` (`brew search --cask lowkey`); a domain if you want one; and how findable it is, since "lowkey" is everyday slang and a search for it won't find the app.
- Compare "Lowkey" as is, a different spelling (e.g. Lowkee, Lowki, LowKey) and a longer store/display name ("Lowkey Dictation"), against the same checks.
- Exit: one name chosen and recorded at the top of this document, with the checks behind it.

**P0b. Codebase review and tidy-up.** A full review of the CLI, Lowkey and the docs, then deletions, so the code that goes into the rename is already the shape Lowkey 1.0 needs. Run it as a review first (a findings list plus decisions for you), then tidy-up PRs by area, each with `./tests/ci.sh` green and an oracle review.
- **Decisions first** (they decide how much goes): is the tmux flow still used (`history sessions` shows the split by flow)? Is CLI inline capture (`inline start/stop/toggle`, ffmpeg device handling, osascript paste) still used now that Lowkey owns the key? Keep, port or drop LLM post-processing, silence trim and chunking? Anything dropped here never has to be ported in phase 1.
- **Decided (2026-10-16), from `history/bench.tsv` and `app.log`:**
  - **Drop the tmux flow.** No tmux takes in 800 logged runs since May 2026. The tmux keybind already pointed at a script that no longer exists.
  - **Drop CLI inline capture**, and with it `recording.sh`, `audio.sh`, ffmpeg device detection, `devices`/`device` and osascript paste. Last used 2026-09-30; every take since 2026-10-06 came through Lowkey. The end-to-end checks for tail rescue, `keep_logs` and audio retention move onto `inline process`.
  - **Drop LLM post-processing, silence trim and audio chunking**, plus `budget`, `bench-matrix`, `replay` and `history reprocess`. All three were off, and none of the 104 saved history entries used post-processing. Phase 1 doesn't port them. `merge_transcript_chunks` stays because tail rescue uses it.
  - **Drop operator commands with no user:** `watch`, `keybind`, `debug`, `logs follow`. `bench` is slimmed.
  - **Lowkey requires the CLI it was built with.** `app-config --json` reports an integer app contract, and Lowkey has a matching constant (CI checks they agree). On a mismatch Lowkey refuses takes and says which versions differ and to run `./install.sh --force`. This replaces the capability checks: version strings alone can't do it, because every capability was added while the CLI said `0.10.0-dev`.
  - The v0.10.0 gates passed on 2026-10-16 (68 warm native takes, median overhead 70ms; 96 verify matches, 0 mismatches), so `[app] native_pipeline` and `[app] verify_pipeline` go. The CLI's `inline cleanup` stays for `tests/gen-cleanup-fixtures.sh`, and `inline process` stays as Lowkey's fallback (daemon unreachable, native errors, Retry).
- **Candidates to delete:**
  - The Raycast scripts and the `integrations doctor/repair` adapter machinery that exists for them; the `tmux-whisper swiftbar` notice stub.
  - Lowkey's support for older CLIs. App and CLI ship from one tree, so Lowkey can require the CLI version it was built with and say so clearly, instead of capability checks (`take_markers`, `lifecycle_lock`, `warmup_json`, `usage_days`, `deferred_usage`), the lifetime-only Stats window, the "Update tmux-whisper" notices and supervision turning itself off.
  - Rollout switches, once the v0.10.0 gates in `tools/lowkey-report.sh` pass: `[app] native_pipeline = false` (the phase 2 path) and `[app] verify_pipeline` with its `inline cleanup` shadow compare. Keep what `tests/gen-cleanup-fixtures.sh` needs.
  - Legacy log handling in `lowkey-report.sh` (`done(native)` lines from before the `take:` line).
  - Whatever the decisions above drop (tmux flow, CLI capture, LLM), and CLI operator commands with no remaining user (`bench-matrix`, `budget`, `keybind`, `watch`, …).
  - Docs: finished plans moved to `docs/plans/archive/`, `ROADMAP.md` rewritten around Lowkey, the CHANGELOG archive TODO done.
- **Structure:** split `AppController.swift` (~1,500 lines) by responsibility; keep `LowkeyCore` the testable, AppKit-free core; check module boundaries (`TmuxWhisperKit`, `LowkeyCore`, `Lowkey`) are the ones phase 1 and the new repo want. No renames yet: names change in phase 2.
- Exit: nothing left that exists only for SwiftBar, Raycast or an older CLI or app version; the decisions recorded here; CI green; deletions listed in CHANGELOG; and a week of daily Lowkey use afterwards with the `lowkey-report.sh` gates still met.

**Also in phase 0:** confirm new repo vs rename in place, and join the Apple Developer Program before phase 2 (needed for Developer ID notarization).

### Phase 1: Lowkey stops needing the CLI
Native config, history, usage writers, the daemon in the bundle, model download, sounds in the bundle. Also gate delivery on `CGPreflightPostEventAccess`/`CGRequestPostEventAccess` instead of `AXIsProcessTrustedWithOptions` (`Deliverer.swift`): it's the narrower permission, and the one a sandboxed build can get. Launch the bundled daemon as a child process (works for both channels) rather than an `SMAppService` agent. Each port proven against the CLI with shared fixtures (as `tests/fixtures/cleanup/` did for cleanup), and the CLI and Lowkey write the same files under the same locks while both exist.
- Order: usage ledger + history writer (removes `inline record`) → config reader (removes `app-config`) → daemon in the bundle and Lowkey-owned lifecycle (removes `warmup`) → model download → native or dropped fallbacks (removes `inline process`).
- Lowkey keeps working with the CLI installed (CLI tmux takes still use the daemon and the same ledger).

Exit: on a clean macOS user account with no CLI, no Homebrew and no model, Lowkey installs, downloads the model, dictates, shows Stats and history. On your machine, 14 days of daily use with zero CLI invocations in `app.log` (a new `cli=` count in `lowkey-report.sh`), no usage mismatch between Lowkey's ledger and a CLI read of the same file, and the 3c release gates still met.

### Phase 2: ship Lowkey on its own
- Developer ID signing, hardened runtime, notarization, a versioned `.zip`/`.dmg` per release, and a `lowkey` cask in `ricardo-nth/tap`. Sparkle or "check for updates" via the cask (`brew upgrade --cask`). Notarization needs a paid developer account ([apple-program], [apple-notarization]). A personal tap could carry a self-signed app, but Gatekeeper would warn on every fresh install. Since September 2026 `homebrew/cask` disables casks that fail Gatekeeper ([brew-5], [brew-acceptable-casks]), so a notarized build also leaves the door open to the official cask repo.
- Settings window, History window, Transcribe File, the bundled `lowkey` CLI (for the agent skill).
- New repo `ricardo-nth/lowkey` (filter-repo of the Lowkey parts), its own CI (`swift test`, the cleanup fixtures), README, CHANGELOG starting at Lowkey 1.0. Issue tracker docs (`docs/agents/`) move with it.
- `tmux-whisper` keeps shipping CLI fixes only.

Exit: a fresh Mac installs with `brew install --cask ricardo-nth/tap/lowkey`, Gatekeeper opens it without a warning, and Microphone and Accessibility prompt once. The `transcribe-audio` skill works through the bundled `lowkey` CLI.

### Phase 3: data moves to Lowkey
- First launch of the new version imports `~/.config/dictate` (config, modes, vocab, history, `usage.json` with its daily buckets and seen take ids) into `~/Library/Application Support/Lowkey/`, and leaves the old folder in place with a `MOVED_TO_LOWKEY` note. The CLI, if still installed, is told where the data went (`tmux-whisper` reads a pointer file) or stops writing usage.
- `usage --json`'s shape is kept as Lowkey's internal ledger and export format, so Stats doesn't change.

Exit: import is idempotent (run twice, same result), tested on a copy of your real `~/.config/dictate`; lifetime totals and streak identical before and after.

### Phase 4: deprecate the CLI
- CLI release that prints a one-line notice on interactive commands (not in `--json` output) pointing to Lowkey; README and `docs/INTEGRATIONS.md` say "deprecated".
- Formula: `deprecate! date: "…", because: "is replaced by the Lowkey app", replacement_cask: "lowkey"`. Deprecation warns and still installs; `disable!` refuses. The replacement is a suggestion, not an automatic migration ([brew-deprecate]). Homebrew can migrate a formula to a same-tap cask through `tap_migrations.json` since 5.0.6, but with a different name and later reports of failures ([brew-21207]), so the plan doesn't rely on it.
- Raycast scripts, SwiftBar plugin and Finder Quick Action marked deprecated by `integrations doctor`, with what replaces each.

Exit: 30 days with the notice live; nothing of yours still calls `tmux-whisper` (Raycast, SwiftBar, skills, shell aliases, `~/.zshenv`).

### Phase 5: sunset and archive
- Final CLI release (tagged, CHANGELOG notes the end of support). Formula `disable!` after the deprecation period.
- `ricardo-nth/tmux-whisper`: README banner pointing to `ricardo-nth/lowkey`, open issues transferred, repo archived ([gh-archive]).
- `homebrew-tap` keeps the disabled formula (so `brew` explains why) and the `lowkey` cask.

Exit: archived; `brew install ricardo-nth/tap/tmux-whisper` says it's disabled and names the cask.

### Phase 6 (parked): Mac App Store
Not planned. Revisit once Lowkey has shipped through phase 2 and been improved in daily use. If it's picked up: a separate sandboxed build target (`Lowkey-AppStore` entitlements, socket in an app-group container, no Sparkle, no bundled CLI), not the direct build with entitlements bolted on, starting with a TestFlight build. Until then, phase 1 shouldn't rule it out: gate paste on PostEvent, bundle the daemon as a child process, keep data under Application Support.

## App Store blockers to check
Reference for the parked phase 6. Checked 2026-10-14 against Apple's guidelines, documentation and DTS answers on the developer forums. Nothing here was tested with a sandboxed Lowkey build. Short version: **automatic paste is technically possible in the sandbox but is a real App Review risk**. The definite blockers are the ones Lowkey can fix: no sandbox, the external CLI, home-directory paths and signing.

| Area | Lowkey today | Verdict | What it would take |
| --- | --- | --- | --- |
| **App Sandbox** | Not sandboxed; hardened runtime with `device.audio-input` only (`App/Lowkey.entitlements`) | **Blocker** (fixable) | The App Store requires the sandbox (guideline 2.4.5(i), [asr-guidelines], [apple-sandbox]). Some App Store apps predate the rule and aren't sandboxed, so existing listings aren't proof of what a new app may do ([dts-grandfathered]). An architecture change, not an entitlement toggle: everything below follows from it |
| **Paste into other apps** (pasteboard + synthetic Cmd+V, optional Return, re-activating the previous app) | `Deliverer.swift` gates delivery on `AXIsProcessTrustedWithOptions`, then posts `CGEvent`s; it already logs `CGPreflightPostEventAccess` | **Needs work; review uncertain** | Apple distinguishes full Accessibility (controlling other apps through AX: generally not sandbox-compatible) from **PostEvent** (posting synthetic events: sandbox-compatible, listed under Accessibility in Settings) ([dts-postevent-2026], [dts-postevent-2025]). Gate on `CGPreflightPostEventAccess`/`CGRequestPostEventAccess` ([apple-request-postevent]) instead of AX trust. Worth doing in phase 1 anyway: it's the narrower permission. **But** the same March 2026 thread is a developer rejected repeatedly under 2.4.5 for exactly pasteboard + Cmd+V, and DTS can't promise review outcomes ([dts-postevent-2026]). Precedent cuts both ways: Paste (clipboard manager) does direct paste from the App Store ([paste-mas]), while MacWhisper's App Store edition drops system-wide dictation ([macwhisper-editions], [macwhisper-dictation]) and Spokenly's App Store build makes you press Cmd+V yourself ([spokenly-mas]). Superwhisper, Wispr Flow, VoiceInk and Aqua Voice distribute their Mac apps as direct downloads ([superwhisper], [wispr], [voiceink], [aqua]). Plan: explain PostEvent in the review notes and link the DTS answer; if rejected, the App Store build copies and the user pastes |
| **Global hotkeys** | Carbon `RegisterEventHotKey`, `ctrl+option+space`, Ctrl+Esc while recording | **Fine** | Works in the sandbox with no permission prompt; KeyboardShortcuts (App Store compatible) uses the same API ([keyboardshortcuts]). macOS 15.0 refused Option/Shift-only hotkeys; 15.2 restored them ([dts-sequoia-hotkeys]). Lowkey's defaults include Control, so they're unaffected. Settings should still reject Option-only combinations on 15.0–15.1 |
| **The bundled daemon** | `tmux-whisperd` built from source by the bash CLI (`swift build`), started by `warmup --json`, socket at `~/.config/dictate/.cache/tmux-whisperd.sock` | **Blocker as it stands; a bundled helper is fine** | Depending on `~/.local/bin`, Homebrew, Python or a separate installer conflicts with 2.4.5(ii), 2.4.5(viii) and 4.2.3(i) ([asr-guidelines]); a sandboxed app can't run binaries outside its bundle and containers anyway ([apple-file-access], [dts-external-binary]). Bundle the daemon prebuilt and launch it as a child with `app-sandbox` + `inherit` and no other entitlements ([apple-helper-tool]), or as an XPC service, which Apple prefers. An `SMAppService` agent must be sandboxed itself when its app is ([macos-14-2], [dts-smappservice]). The socket moves into an app-group container ([apple-app-groups]): keep its name short, since `sun_path` is 104 bytes unless the code uses the larger form macOS allows (253) ([dts-sun-path]) |
| **Model download** | None: the user installs the Parakeet model by hand | **Fine in principle; onboarding needed** | Apple documents downloading and compiling Core ML models on device ([apple-coreml-download]); DTS knows of no rule against downloaded model files but defers to App Review ([dts-model-download]). Guideline 4.2.3(ii) requires disclosing the size and asking before a first-launch download, not only large ones ([asr-guidelines]). Needs `network.client` and storage in the container. Apple-hosted asset packs (macOS 26+, App Store and TestFlight only) are an option, not a need ([apple-asset-packs]). Precedent: Whisper Transcription and Private LLM download models from the App Store ([whisper-transcription], [private-llm]). Keep inference code in the bundle: downloads are weights only |
| **`~/.config/dictate` and other home paths** | Hard-coded `~/.config/dictate` (via the CLI, and `usage.json` in `StatsModel.swift`), `/tmp/dictate-processing`, `~/Library/Logs/Lowkey` | **Needs migration** | Sandboxed apps get their container, not the home folder ([apple-protecting-data], [apple-file-access]). Phase 3's move to Application Support covers it: import `~/.config/dictate` once through an open panel (security-scoped bookmark) or Apple's container migration manifest ([apple-container-migration]). Temporary-exception entitlements for home paths exist but need justifying at review and aren't promised ([apple-temp-exceptions]): don't depend on them |
| **Microphone, login, other 2.4.5 points** | `audio-input` entitlement, usage string present, `SMAppService.mainApp` opt-in | **Routine** | The sandbox needs `com.apple.security.device.microphone` too (not interchangeable with the hardened-runtime `audio-input`) ([apple-mic-entitlement], [apple-audio-input]). Start at Login is already opt-in, as 2.4.5(iii) and `SMAppService` expect ([apple-smappservice]). App Store builds must update through the store (2.4.5(vii)), so no Sparkle in that build |
| **Signing and account** | Local self-signed identity | **Blocker** (fixable) | Apple Developer Program, US$99/year ([apple-program]). Direct downloads need Developer ID + hardened runtime + notarization; the App Store needs Apple distribution signing ([apple-certificates], [apple-notarization]) |

**If phase 6 is picked up:** build a minimal sandboxed variant (bundled daemon as a child or XPC service, container storage, PostEvent gate, model download with consent) and run it daily for a week before deciding to submit. If you submit, start with a TestFlight build, and decide upfront whether a copy-only App Store build is worth shipping if automatic paste is rejected. For a dictation app, auto-paste is most of the value, which is why most competitors stay outside the store.

## Open questions
- Lowkey versioning: start at 1.0 in the new repo, or continue the CLI's 0.x?
- Settled in phase 0: the name (P0a); new repo vs rename in place. (Tmux flow, CLI capture, LLM post-processing, silence trim and chunking: dropped, see P0b.)
- Parked with phase 6: free or paid on the App Store (paid needs the Paid Apps agreement and tax/banking in App Store Connect).

## Sources
Checked 2026-10-14. Forum answers are dated where it matters, since sandbox behaviour has changed across macOS versions.

GitHub and Homebrew
- [gh-rename] GitHub Docs, Renaming a repository
- [gh-archive] GitHub Docs, Archiving repositories
- [brew-deprecate] Homebrew Docs, Deprecating, disabling and removing formulae
- [brew-21207] Homebrew/brew#21207, formula → cask migration via `tap_migrations.json` (fixed in 5.0.6, later failure reports)
- [brew-5] Homebrew 5.0.0 release notes (Nov 2025): casks failing Gatekeeper disabled from Sept 2026
- [brew-acceptable-casks] Homebrew Docs, Acceptable casks

Permissions and signing
- [tcc-identity] Apple, privacy preferences policy identity (bundle id + code requirement)
- [tn2206] Apple TN2206, macOS code signing in depth (designated requirements; archived)
- [dts-tcc] Apple Developer Forums, DTS on TCC needing a stable signature (Oct 2020)
- [apple-program] Apple Developer Program
- [apple-certificates] Apple, certificate types
- [apple-notarization] Apple, notarizing macOS software before distribution

Name
- [asc-name] App Store Connect help, add a new app (one name per localization)
- [lowkey-chat] App Store, Lowkey – Group chat (iPhone)
- [lowkey-fyi] App Store, lowkey.fyi (iPhone/iPad)
- [lowkey-yc] Y Combinator, Lowkey (gaming clips, acquired by Niantic)

App Store and sandbox
- [asr-guidelines] App Review Guidelines (2.4.5, 2.5.2, 4.2.3)
- [apple-sandbox] Apple, App Sandbox
- [dts-grandfathered] Apple Developer Forums, DTS on App Store apps that predate mandatory sandboxing (Sept 2025)
- [dts-postevent-2026] Apple Developer Forums, DTS on PostEvent vs Accessibility in the sandbox, and a 2.4.5 rejection for pasteboard + Cmd+V (Mar 2026)
- [dts-postevent-2025] Apple Developer Forums, DTS confirming sandboxed event posting (Jun 2025)
- [apple-request-postevent] Apple, `CGRequestPostEventAccess`
- [keyboardshortcuts] sindresorhus/KeyboardShortcuts (sandbox and App Store compatible, `RegisterEventHotKey`)
- [dts-sequoia-hotkeys] Apple Developer Forums, macOS 15 Option-only hotkey restriction and its 15.2 reversal (Nov 2024)
- [apple-helper-tool] Apple, embedding a helper tool in a sandboxed app
- [macos-14-2] macOS 14.2 release notes (sandboxed `SMAppService` targets, trampolines)
- [dts-smappservice] Apple Developer Forums, DTS worked example of `SMAppService` and the sandbox
- [apple-app-groups] Apple, App Groups entitlement
- [dts-sun-path] Apple Developer Forums, DTS on Unix socket path lengths (Mar 2026)
- [apple-file-access] Apple, accessing files from the macOS App Sandbox
- [dts-external-binary] Apple Developer Forums, DTS on running external inference binaries from the sandbox (Jul 2025)
- [apple-protecting-data] Apple, protecting user data with App Sandbox
- [apple-container-migration] Apple, migrating your app's files to its sandbox container
- [apple-temp-exceptions] Apple, temporary exception entitlements (archived)
- [apple-coreml-download] Apple, downloading and compiling a Core ML model on the user's device
- [dts-model-download] Apple Developer Forums, DTS on downloading model files (Jul 2025)
- [apple-asset-packs] App Store Connect help, Apple-hosted asset packs
- [apple-mic-entitlement] Apple, `com.apple.security.device.microphone`
- [apple-audio-input] Apple, `com.apple.security.device.audio-input`
- [apple-smappservice] Apple, `SMAppService`

Competitors
- [paste-mas] Paste 3 announcement (direct paste, App Store)
- [macwhisper-editions] MacWhisper vs Whisper Transcription (App Store edition)
- [macwhisper-dictation] MacWhisper, dictation not available in the App Store edition
- [spokenly-mas] Spokenly, App Store build requires manual Cmd+V
- [whisper-transcription] App Store, Whisper Transcription
- [private-llm] App Store, Private LLM (Mac)
- [superwhisper] Superwhisper download page
- [wispr] Wispr Flow installation docs
- [voiceink] VoiceInk installation docs
- [aqua] Aqua Voice for Mac

[gh-rename]: https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository
[gh-archive]: https://docs.github.com/en/repositories/archiving-a-github-repository/archiving-repositories
[brew-deprecate]: https://docs.brew.sh/Deprecating-Disabling-and-Removing
[brew-21207]: https://github.com/Homebrew/brew/issues/21207
[brew-5]: https://brew.sh/2025/11/12/homebrew-5.0.0/
[brew-acceptable-casks]: https://docs.brew.sh/Acceptable-Casks
[tcc-identity]: https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary/identity
[tn2206]: https://developer.apple.com/library/archive/technotes/tn2206/_index.html
[dts-tcc]: https://developer.apple.com/forums/thread/663889
[apple-program]: https://developer.apple.com/programs/
[apple-certificates]: https://developer.apple.com/help/account/certificates/certificates-overview
[apple-notarization]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
[asc-name]: https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
[lowkey-chat]: https://apps.apple.com/us/app/lowkey-group-chat/id1521276224
[lowkey-fyi]: https://apps.apple.com/us/app/lowkey-fyi/id6744252950
[lowkey-yc]: https://www.ycombinator.com/companies/lowkey
[asr-guidelines]: https://developer.apple.com/app-store/review/guidelines/
[apple-sandbox]: https://developer.apple.com/documentation/security/app-sandbox
[dts-grandfathered]: https://developer.apple.com/forums/thread/707680
[dts-postevent-2026]: https://developer.apple.com/forums/thread/820594
[dts-postevent-2025]: https://developer.apple.com/forums/thread/789896
[apple-request-postevent]: https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()
[keyboardshortcuts]: https://github.com/sindresorhus/KeyboardShortcuts
[dts-sequoia-hotkeys]: https://developer.apple.com/forums/thread/763878?answerId=804374022
[apple-helper-tool]: https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
[macos-14-2]: https://developer.apple.com/documentation/macos-release-notes/macos-14_2-release-notes
[dts-smappservice]: https://developer.apple.com/forums/thread/802443
[apple-app-groups]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups
[dts-sun-path]: https://developer.apple.com/forums/thread/817602
[apple-file-access]: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
[dts-external-binary]: https://developer.apple.com/forums/thread/792312
[apple-protecting-data]: https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
[apple-container-migration]: https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container
[apple-temp-exceptions]: https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html
[apple-coreml-download]: https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device
[dts-model-download]: https://developer.apple.com/forums/thread/793131
[apple-asset-packs]: https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs
[apple-mic-entitlement]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone
[apple-audio-input]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
[apple-smappservice]: https://developer.apple.com/documentation/servicemanagement/smappservice
[paste-mas]: https://pasteapp.io/blog/meet-paste-3-for-mac
[macwhisper-editions]: https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference
[macwhisper-dictation]: https://docs.macwhisper.com/article/14-how-to-use-the-dictation-feature
[spokenly-mas]: https://spokenly.app/docs/mac-app-store
[whisper-transcription]: https://apps.apple.com/us/app/whisper-transcription/id1668083311
[private-llm]: https://apps.apple.com/us/app/private-llm-local-ai-chat/id6448106860?platform=mac
[superwhisper]: https://superwhisper.com/download
[wispr]: https://docs.wisprflow.ai/articles/6203703148-redirect-loops-when-attempting-to-download-the-app-from-the-wispr-flow-website
[voiceink]: https://tryvoiceink.com/docs/installation
[aqua]: https://aquavoice.com/mac
