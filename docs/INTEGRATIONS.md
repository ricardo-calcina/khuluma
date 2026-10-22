# Integrations

Khuluma, the native menu-bar app in `native/`, is the main way to dictate. The installed `khuluma` CLI still owns config, history, usage and the daemon lifecycle that Khuluma reads through it. The Finder Quick Action and the agent skill wrap `khuluma transcribe`.

## Support Boundaries

- Supported platform: macOS with the requirements listed in the README.
- Supported install channels: Homebrew stable, bootstrap from GitHub, and local clone installs via `./install.sh`.
- Supported runtime source of truth: the CLI, config under `~/.config/khuluma`, install receipt, processing markers, and CLI status/diagnostic commands.
- Unsupported as production surfaces: alternate backend experiments and direct parsing of private files when a CLI read contract exists.

## Supported surfaces

| Surface | Status | Install/update path | Notes |
| --- | --- | --- | --- |
| Khuluma (native menu-bar app) | Daily driver | `tools/build-khuluma-app.sh` (see the README) | Owns the hotkey, capture, sounds, paste and the Stats window. Transcribes over the daemon socket and cleans text natively; uses the installed CLI for settings, history, usage and the daemon lifecycle (`docs/CLI_CONTRACTS.md`). |
| `khuluma` CLI | Supported (Khuluma's back end) | Local `./install.sh --force` for Khuluma; Homebrew or bootstrap for the CLI alone | Source of truth for config, vocab, history, usage, status and doctor. Khuluma needs the CLI from its own checkout (app contract). |
| CLI inline and tmux dictation | Retired (v0.10.0) | None | Khuluma replaces both. `inline process`, `inline record` and `inline cleanup` stay as Khuluma's back end. |
| Finder Quick Action (transcribe files) | Supported | `khuluma finder install` | Runs `integrations/finder/khuluma-transcribe.sh`, which calls `khuluma transcribe --beside --clipboard`. The handler is installed beside the binary (Homebrew's `share/khuluma`, or `~/.local/share/khuluma/integrations`). |
| Agent skill (`integrations/agents/transcribe-audio/`) | Supported | Copy into your agent's skills folder | Tells Claude Code and Codex to use `khuluma transcribe` for audio files. |
| Raycast scripts, SwiftBar plugin | Retired (v0.10.0) | None | Khuluma owns the dictation key and the menu-bar item. Old copies under `~/.config/khuluma/integrations/raycast` or SwiftBar's plugin folder can go to the Trash. |

## Environment Expectations

GUI launchers (Khuluma, Finder) run the CLI with a smaller environment than an interactive terminal. If behaviour differs from the terminal, check the environment first.

- Keep custom PATH dependencies and env-based overrides in `~/.zshenv`, which the CLI loads; don't rely on `.zshrc`.
- Use `khuluma status` and `khuluma doctor` to compare the installed runtime against what you see.
- v0.11.0 uses only `khuluma`/`KHULUMA_*`: old command discovery, environment translation and the former doctor JSON adapter are removed. Obsolete variables, including empty assignments, are refused before writes; update launcher environments rather than relying on a fallback.

## Channel Differences

Homebrew is the stable channel. It is best when you want tagged releases and normal `brew upgrade` behavior.

Bootstrap is for pinned installs or testing a GitHub ref without keeping a clone. Prefer explicit `--ref` for reproducible setup.

Local clone installs are for active development. Run `./install.sh --force` after local code changes before judging installed CLI or Khuluma behaviour.

## Identity migration

For pre-Khuluma installations, complete the v0.10.0 coordinated app/preferences/folder transition before using v0.11.0. The immutable v0.10.0 source retains that transition implementation. Normal v0.11.0 startup no longer imports Lowkey domains/folders or selects old command names. Explicit data inspection/recovery and fail-closed root admission remain.

An existing Tmux Whisper/Lowkey installation needs one coordinated transition of its data, executable routes, daemon, app identity, login intent and Finder action. The procedure is operator/agent-controlled. This release supplies the data engine and refusal guards; it does not ship a portable automated coordinator. A completed migration on one Mac and a successful Homebrew package installation are separate evidence from an upgrade of another legacy installation, including v0.9.0.

From a canonical source checkout, start with these inspection commands:

```bash
tools/migrate-khuluma-identity.sh --help
tools/migrate-khuluma-identity.sh --dry-run
```

Dry-run creates no files and reports paths, counts and conflicts, or a reason inspection cannot proceed safely. It does not stop writers, gate commands or prepare the app. Keep a working legacy runtime in place until the complete handoff is ready; `install.sh --force`, bootstrap, a formula rename and the build helper do not perform this legacy cutover.

The public entry point delegates to [`tools/khuluma_identity_migration.py`](../tools/khuluma_identity_migration.py). Its module docstring, also shown by `--help`, defines the exact `rename-v1` receipt fields. `admit`, `gate_bytes`, `held_locks` and `finalize` enforce the current protocol. Receipts are evidence produced by a coordinator after it establishes the barrier and performs the checks, not a configuration template to fill in to bypass a refusal.

| Operation | Required controller proof | Result |
| --- | --- | --- |
| `--dry-run` | None | Inspection only, or the recorded migration state. |
| `--apply` | `--admission-receipt` | Stages data and records `cutover-staged`; this is not completed installation. |
| `--resume` | Current `--admission-receipt`; matching `--verification-receipt` for commit | Continues recorded work, or commits after controlled startup verification. |
| `--rollback` | Current `--admission-receipt` | Reverses the data transition while preserving post-cutover records; the coordinator restores code and routes. |

For a live handoff the admission receipt must be an owned regular 0600 JSON file with `scope: "live_controller"`, `schema_version: 1`, `migration_version: "rename-v1"`, `state: "gated"`, a canonical UUID nonce and a lifetime of at most one hour. It binds the current controller PID/UID/start fingerprint, the six exact old/new config/model/sound roots, a private nonce token, each exact gate and backup hash, and the recorded writer, processing, socket and lock paths. Gates must match the engine's nonce-bound `gate_bytes` exactly. A fixture receipt cannot authorize paths outside its private fixture root. The controller must remain alive and its proof current throughout the handoff.

Commit additionally requires an owned regular 0600 verification receipt matching the manifest's migration ID, nonce and roots, and the admission controller identity. It must have `schema_version: 1`, `migration_version: "rename-v1"`, `state: "verified"`, a timestamp between manifest creation and the current time, and checks proving `cli_contract: 3`, `serving_daemons: 1`, `usage_schema: 1`, `canonical_roots: true`. These numeric/layout checks do not substitute for the real macOS and user-workflow observations below. Never fabricate either receipt.

The operator or agent coordinating a legacy upgrade must complete this sequence:

1. Inventory every actual route: source/local/Homebrew commands and wrappers, the app, login launch and Finder handlers. Record effective roots, custom overrides, the original login opt-in and exact restore locations privately. Stage a matching canonical CLI/helpers, verified native build, signed app, Finder action and consumer updates before touching the working runtime. Preserve old code, certificates and user data; use metadata/hashes rather than copying personal content into reports.
2. Stop new admission through every route with supported controls and exact backed-up refusing gates. Before quitting, disable the old app's login registration through its own supported ServiceManagement/menu controls where needed; a foreign helper cannot unregister an arbitrary old `mainApp` identity. The new migration lock cannot stop an old binary that does not know about it. Finish current takes or durably recover them, gracefully quit the exact app, drain accepted requests and stop the exact owned daemon. Resolve processing markers, sockets and bench/build/restart lock ownership. If any route or writer cannot be accounted for, restore the working routes and defer the cutover; do not force-kill a take.
3. Keep the external gates active while the engine takes locks in this order: admission, old/new lifecycle paths in stable order, last-good paths in stable order, then usage paths in stable order; release in reverse. Never delete or replace a held lock inode to seize ownership. Refresh the source fingerprints under that barrier and preserve config/last-good, vocab, history/audio sidecars, usage, completion ledgers and receipts together. Keep pending/recovered Support data intact. Custom paths stay unchanged; only verified factory defaults and same-volume model/sound moves are eligible.
4. Have the live coordinator invoke apply/resume with its current admission proof. Retain the engine's manifest, snapshots and collision decisions. Stage matching code, native resources, app and Finder routing under the same barrier. Do not run the ordinary installer over admission gates.
5. Treat `cutover-staged` as incomplete. The engine publishes staged root metadata and releases its runtime/data locks before apply/staging-resume returns. Keep external admission gates closed, complete file/layout/signature checks and allow only controlled canonical startup using the staged admission proof; do not hold engine locks across startup. Verify canonical CLI identity and effective roots, app contract 3, one serving daemon, model/socket/processing paths, numeric usage continuity and the allowed preferences import. The controller owns this startup; the data engine does not start or stop services.
6. Observe a real dictation, controlled file transcription, Stats/pending/recovery and permissions through the controlled runtime. Preserve post-cutover records if rollback is needed. Only after these checks may the coordinator issue verification proof, resume to a durable `committed` state with its matching startup marker and release the public gates last. After release, complete acceptance with normal relaunch without private admission/CLI/daemon overrides, actual public Finder Quick Action routing, aliases reaching the same ledger, and the original login intent restored through the canonical app's supported controls. Public Finder handlers remain refusing gates before release, so their real invocation is a post-release check. Record installed/live evidence separately from source and package tests.
7. On failure, keep or re-establish admission, gracefully quiesce any new writer and use the manifest's rollback path under fresh valid controller proof. Preserve the latest authoritative data rather than restoring an old usage snapshot over new work. The coordinator must also restore the exact app/code/Finder/command routes and login intent. If safe restoration cannot be proved, retain the recovery material and barrier, report the exact obstruction, and require operator attention; never report success or silently leave a broken route.

For later pickup, the private data record is `<new-config>/.migration/rename-v1/manifest.json`; `<new-config>/.khuluma-identity.json` controls normal startup admission. Do not edit either by hand. Dry-run reports the manifest's state and resume flag; it does not verify startup-marker publication, and after rollback it plans a new transition. A recorded `prepared` or `cutover-staged` state requires the original coordinator's retained session/recovery procedure; a bare data-engine resume cannot restore app or command routes. An expired receipt or dead controller requires newly verified proof after reconciling the actual gates and writers. That proof must preserve the recorded manifest nonce, exact roots and matching gates; a new nonce cannot resume the interrupted migration.

Normal canonical operation without a migration receipt requires both a `committed` manifest and its matching committed startup marker, including migration ID, nonce, version and config root. A committed manifest with `resume_required: false` in dry-run alone does not establish this. If commit was interrupted after the manifest write but before marker publication, keep or re-establish admission and use the retained coordinator's `--resume` procedure with current same-nonce admission proof and the original, unchanged verification evidence recorded by the manifest. The engine verifies that evidence before repairing the marker; do not hand-edit it. A `rolled-back` manifest requires confirmation that the old routes and latest data were restored before another upgrade. Without a reviewed coordinator and recovery session, stop after inspection and keep the working installation.

## Stable Vs Experimental Surfaces

Integrations should consume the stable JSON read contracts in `docs/CLI_CONTRACTS.md`; human-readable output is for operators and is not a parsing contract.

When adding integration behavior, prefer one of these shapes:

- extend the CLI/runtime source of truth
- expose a small documented command
- keep adapter scripts thin
- add deterministic tests that do not require a real microphone or real transcription


## Isolated app validation

A staged native instance requires `KHULUMA_SUPPORT_DIR`, `KHULUMA_LOG_DIR` and `KHULUMA_DEFAULTS_SUITE` together, with explicit private fixture roots and a distinct defaults suite. Give it a fixture-routed canonical CLI/config/socket/model reference too. Isolated mode disables frame autosave and prevents login-item changes. Normal startup has no automatic legacy import either. The synthetic `-KhulumaStatsSnapshot <directory>` path runs before ordinary app startup and uses fixed data rather than a personal ledger.

Installed agent skills, shell shortcuts, any actual KwikCut executable and Finder must resolve the canonical CLI. Verify them with old commands unavailable in an owned fixture before retiring inspected active shims. The Homebrew old-package rename map remains ownership metadata; it does not install a forwarding command. Retained data, preference domains, certificates and prior release artifacts are recovery material, not active callers.
