# CLI sunset: what the `khuluma` CLI does and what happens to it

Ricardo, 2026-11-05: Khuluma is the native app only; the CLI, its Homebrew formula and the tap are retired once the app no longer needs them. This is the inventory behind that, from `bin/khuluma` help and dispatch, `bin/khuluma-lib/`, `native/Sources/Khuluma/CLIBridge.swift`, `install.sh`, the formula and the callers found on Ricardo's Mac. The app keeps its data in `~/Library/Application Support/Khuluma` after a one-time copy from `~/.config/khuluma` (the source stays as rollback). The porting is done by the app-independence work ([APP_INDEPENDENCE.md](APP_INDEPENDENCE.md), branch `wip/app-independence`); this file is the keep/drop list it works from.

Calls: **Keep** = the app does it after the sunset (ported if it isn't native yet). **Drop** = gone with the CLI. **App tab** = already in the app-independence slices.

## 1. What the app calls today (CLIBridge.swift)

All ten go once the app is independent; none survive as CLI commands.

| Command | Used for | Replacement |
|---|---|---|
| `version --json` | contract check at launch | app tab: dropped with the CLI pairing |
| `app-config --json` | hotkey, sounds, delivery, provider settings | app tab slice 4: native config reader |
| `app-settings set <key> <value> --json` | every Settings write | app tab slice 4: native config writer under `config.toml.lock` |
| `vocab-sheet show / validate / save --json` | Vocabulary editor | app tab slice 4: native, same lock and backups |
| `history export N --json` | recent dictations in the Vocabulary editor | app tab slice 3: native history reader |
| `inline record --json` | history, bench and usage after each native take | app tab slice 2: native writers |
| `usage --json --days all` | Stats and the menu figures | app tab: Stats reads `usage.json` natively |
| `warmup --json` | builds and starts `khulumad` from source, loads the model | app tab slice 5: bundled daemon the app supervises; model download |
| `inline process <wav> --json --defer-usage` | fallback when the daemon fails, Retry, and **ElevenLabs Scribe** | app tab: fallback dropped, Scribe ported natively (Keep) |

## 2. User-facing features

| Feature | CLI today | In the app today | Call |
|---|---|---|---|
| **File transcription** `transcribe <file>…` with `-q`, `--format json`, `-o`, `--out-dir`, `--beside`, `-c`, `--force`, stdin `-`, `--no-tail-rescue` | yes; the transcribe-audio skill (Claude and Codex copies) runs `khuluma transcribe "<file>" -q [--format json] [-o file]` | no | **Keep.** A helper in the app bundle, linked to `~/.local/bin/khuluma` from Settings, with the same call shape (`transcribe <file>… -q`, `--format json`, `-o`) so the skill keeps working. Flags (Ricardo, 2026-11-05): `-q`, `--format json`, `-o`, several files, `--beside`, `--force`; `-c`, `--out-dir`, stdin `-` and `--no-tail-rescue` are dropped. The link must not replace the CLI at that path until the CLI is retired (the app calls it there today). A mac-tools to-do wants segment timestamps from it later. |
| **ElevenLabs Scribe** | `providers.py`, via `inline process` | provider picker in Settings, runs through the CLI | **Keep.** App tab slice 5 (Keychain first, then the zshrc lookup). |
| **Finder Quick Action** "Transcribe with Khuluma" (`finder install/remove/status`, `integrations/finder/`) | yes; installed on Ricardo's Mac | no | **Keep** (Ricardo, 2026-11-05). The app provides the right-click action, calling its built-in command: `<name>.txt` beside the file, text copied, a notification, as today. The CLI's workflow is replaced at retirement. |
| Delivery: `autosend`, Settings and menu switch | yes | yes | Keep (native already) |
| Delivery: `send-mode enter/ctrl_j/cmd_enter`, `target origin/current` | yes (Ricardo: `current`, `enter`) | read from config only, no UI | **Keep** as app settings (imported from `config.toml`); Settings rows optional later |
| Sounds: master `sound on/off` | yes | yes | Keep (native) |
| Sounds: per event `sound start/stop/process/error on/off`, `inline process-sound` | yes | config only | Keep as app settings (imported) |
| Cleanup: `repeats 0-3`, cleanup on/off | yes | yes | Keep (native) |
| British spelling (`KHULUMA_BRITISH_SPELLING`, default on) | env | Swift cleanup | Keep as is; env override dropped |
| Vocabulary JSON (`vocab-sheet`) | yes | Vocabulary editor with import/export | Keep (native, app tab) |
| Legacy text vocab: `vocab`, `vocab add/import/export/clipboard/dedupe/edit/rm` | yes, refuses once JSON is active (it is on Ricardo's Mac) | no | **Drop.** The app reads the old `vocab` file only if no JSON exists (app tab first run). |
| `migrate-modes` | v0.10 leftover folding | no | Drop |
| History readers: `history`, `history list/search/export/N/stats/sessions/clear`, `last` | yes | no window; editor shows recent takes | **Drop from the CLI.** A History window in the app stays a phase 2 item. Retention (`history.retention_days`, `audio_retention_days`) stays as app settings. |
| `usage [--json] [--days]` | yes | Stats window and menu | Drop (Stats covers it) |
| Debug audio: `keep-logs on/off` | yes | Settings → Advanced | Keep (native) |
| Diagnostics: `doctor`, `status`, `version`, `changelog`, `bench`, `bench export` | yes | Open Log, Open Config in Settings | **Drop.** `tools/khuluma-report.sh` (reads the logs and bench) stays as a repo tool. |
| Config: `config`, `config path/get/defaults/repair` | yes | Open Config, Reload Settings | Drop; the app writes missing defaults itself (app tab first run) |
| Tunables via env: tail pad, tail rescue, activate and send delays, typing wpm, bench rows, `KHULUMA_CLEAN`, `KHULUMA_VOCAB_CLEAN` | env | defaults built in | Drop the env overrides; keep current defaults (`history.typing_wpm` stays an app setting if the app uses it) |

## 3. Install, distribution and repo

| Item | What it is | Call |
|---|---|---|
| `install.sh`, `bootstrap.sh` | install the CLI to `~/.local/bin`, seed config, vocab and sounds, warm up, write a receipt | Drop at retirement. The app bundles sounds and seeds defaults (app tab slice 5). |
| Homebrew formula `khuluma` (v0.11.0), tap `ricardo-calcina/homebrew-tap` | the tap holds only this formula, `formula_renames.json`, release QA notes and docs | Final release with a notice, then `disable!`, then archive the tap repo. Each step needs Ricardo's yes. |
| CLI on Ricardo's Mac | two copies: `~/.local/bin/khuluma` (install.sh, the one the app calls) and `/opt/homebrew/bin/khuluma` (brew v0.11.0) | Removed only after the app tab confirms independence and Ricardo says yes; Homebrew copy first. |
| Daemon build from source (`khulumad` in `~/.local/share/khuluma/native/`) | built by `warmup` | App bundles it (app tab). The old runtime tree goes to the Bin at retirement. |
| Identity migration (`tools/migrate-khuluma-identity.sh`, `khuluma_identity_migration.py`, `migrate.sh`, `migration.sh`, `identity.sh`) | Tmux Whisper/Lowkey → Khuluma data move | Drop; stays in git history and the archived plan |
| `tools/update-homebrew-formula.sh`, `docs/RELEASE_CHECKLIST.md` CLI parts | formula updater | Drop after the final release |
| `bin/`, `tests/*.sh`, `tests/ci.sh`, `.github/workflows/ci.yml` | the CLI and its tests | Drop at retirement; `swift.yml` and `icons.yml` stay |
| `tests/fixtures/cleanup/` and its generator | bash cleanup output the Swift cleanup tests compare against | Keep the fixtures as frozen golden files; drop the generator |
| `integrations/agents/transcribe-audio/SKILL.md` and Ricardo's `~/.claude` and `~/.codex` copies | the skill | Update to the app's command at retirement |
| Docs: README CLI sections, `docs/CLI_CONTRACTS.md`, `docs/INTEGRATIONS.md`, `docs/TROUBLESHOOTING.md` CLI parts | | Rewrite for the app at retirement; CLI_CONTRACTS keeps only the shared data contract the app still follows |

## Order

1. Ricardo confirmed the calls above on 2026-11-05.
2. The app tab ports what's kept, including the built-in transcribe command, and confirms the app runs with no CLI.
3. Here: final CLI release with a notice pointing to the app (Ricardo's yes), formula `disable!` (yes), tap archive (yes), then remove the CLI code, CI and docs, update the skill, and remove the CLI from Ricardo's Mac (yes, with rollback).
