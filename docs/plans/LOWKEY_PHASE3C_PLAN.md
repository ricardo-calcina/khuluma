# Lowkey phase 3c: always warm, never lose a take

Status: reviewed (2026-10-10, two oracle reviews: strategy + risks), revised. Follows 3b (PR #50), see `LOWKEY_PHASE3_PLAN.md`. Ships after v0.10.0, which is gated on 3b's real-use measurements.

3c-1 lands in three PRs: **(a)** CLI/daemon foundations (items 1, 2, the daemon/CLI half of 3, app-config capabilities); **(b)** Lowkey supervision (rest of 3), timeouts (4), hotkey swap (rest of 5), idle device change (7); **(c)** instrumentation and `tools/lowkey-report.sh` (6).

## Where 3b left us (measured)
- **Overhead:** ~37 ms beyond the `asr` stage on the first native take (97 s take: queue 1 ms, cleanup 16 ms, paste 55 ms incl. the configured 35 ms send delay). The CLI path's was a median 992 ms (n=13). Caveat: `asr` still includes WAV prep and socket work, so "overhead beyond Parakeet" isn't fully measured yet (item 4).
- **One model, already warm:** the model lives only in `tmux-whisperd` (~11 MB RSS, memory-mapped CoreML; RSS alone doesn't establish CoreML memory pressure on an 8 GB machine). Lowkey (~19 MB) loads none.
- **Start latency** (n=14): engine start median 53 ms, hotkey → chime 86 ms, **hotkey → first audio 207 ms** (p90 248). The chime is played *before* capture starts, so the "speak now" cue comes ~120 ms before the first captured buffer.

## Decision: supervise the daemon, don't absorb it
In-process ownership (the original 3c) would save ~10–20 ms per take (WAV write/read, socket hop). The costs: socket takeover races, two lifecycle owners, an app build that links FluidAudio, and ASR failures taking down hotkey/capture/paste. **3c keeps `tmux-whisperd` as the only model owner and makes Lowkey supervise it.**

Revisit in-process ownership only if **warm, uncontended** measurements (item 4) show transport (WAV + socket) costing a material share of stop → text, and a prototype shows a worthwhile gain without weakening isolation. Daemon crashes/hangs trigger *diagnosis*, not migration. Streaming/partial results would be a separate architecture experiment (a daemon can stream too).

## 3c-1: reliability core (one PR, v0.11.0)

### 1. Shared daemon lifecycle lock (CLI)
`ensure_swift_parakeet_daemon` pings, removes the socket on failure, launches, then writes meta, all unlocked. Lowkey warmups, CLI fallbacks and installer refreshes can race: orphan daemons, meta naming the wrong pid, or a live socket deleted from under its owner.
- One per-socket lifecycle lock (`<socket>.lifecycle.lock`, same mkdir/stale scheme as the build lock) around ensure/launch, restart and warmup's launch step. Recheck ping after acquiring it.
- Never unlink a socket that accepts connections. Write meta atomically (temp + mv) only after the launched pid is serving.
- Test: simultaneous app-style warmup + CLI fallback + `refresh_tmux_whisperd` leaves exactly one daemon, matching meta, and a working socket.

### 2. Per-take markers covering the whole take
- Lowkey publishes a marker **before capture starts** (`inline-lowkey-<take>`-style file in a dir from `app-config`, `pid=` first line, `phase=recording|queued|processing`). It is kept through stop, the queue, the settings wait, native processing or the CLI fallback, and removed on every terminal path (delivered, no speech, failure, cancel, failed start). It replaces 3b's processing-only marker.
- The CLI's `dictation_pipeline_idle` treats live markers as busy and **prunes dead-pid markers itself** (today it treats any file as busy and never prunes; SwiftBar does the pruning).
- SwiftBar keeps showing "processing" only for `phase=queued|processing` (optionally "recording" for `phase=recording`).
- Residual race (accepted): idle check → SIGTERM can still interleave with a hotkey press. The daemon drains accepted work and the app falls back, so the cost is one slow take, not a lost one.
- Tests: cancel, failed engine start, crash (dead pid), rapid consecutive takes, upgrade during recording, upgrade immediately after stop.

### 2b. Quit and rebuild never discard a recording (done early, 2026-10-10)
Observed 2026-10-10: `tools/build-lowkey-app.sh` quit Lowkey mid-recording and the take (~57 s) was lost. Quit only drained processing and persistence, not an in-progress capture.
- `applicationShouldTerminate` with a take recording: save its audio to `Application Support/Lowkey/recovered/` first, then transcribe it into history (status `recovered`, no usage) and onto the clipboard, never pasting or sending (the frontmost app at quit time is not the intended target). Leftovers are transcribed into history at the next launch.
- `tools/build-lowkey-app.sh` waits for the app to exit (up to 60 s) instead of replacing it after 0.5 s, then relaunches it. Once item 2's markers exist, it can also wait before asking the app to quit.

### 3. Truthful readiness and bounded supervision
- **Daemon:** ping gains additive fields `model_loaded` (path + version) and `generation` (per-process UUID). A warmup response confirms the loaded model. Older daemons omit them and count as "unknown".
- **CLI:** a `tmux-whisper warmup --json` variant that reports `ready | warming | unavailable` truthfully, unlike `--best-effort`, which exits 0 even when nothing was preloaded.
- **Lowkey states:** `unavailable` (no socket), `warming`, `ready` (this generation has our model loaded). The menu shows them.
- **Triggers (event-driven, no background polling):** launch, wake from sleep, recording start (probe with a bounded ~250 ms ping; the client's unreachable retry stays), and after a native take hits "unreachable". At most one warmup in flight, on a dedicated supervision queue (never the work/settings queues). Back off 30 s → 2 min → 10 min after failures.
- **Capability gate:** supervision runs only when `app-config` advertises marker + lifecycle-lock support (an older CLI keeps 3b behaviour). New `[app] supervise_daemon = true` as an independent off switch. Disabling it leaves CLI-owned daemon use intact.

### 4. Failed takes and hangs
- A reachable daemon whose ASR stalls answers ping but times out the take. On a native timeout: no automatic retry; keep the take's padded WAV privately (0600, app temp, removed after 1 hour or on discard); show "Transcription timed out" with **Retry** / **Discard** in the menu; log daemon generation and whether ping still answers.
- Retry goes through the native path once the daemon is ready, else through `inline process`.

### 5. Never adopt a broken config (done early, 2026-10-10)
Shipped ahead of 3c: the CLI falls back to the last valid `config.toml` copy, `app-config` reports `config.error`/`source`, and Lowkey warns and won't send with fallback defaults. Still for 3c-1: apply hotkey changes only when idle, and restore the old binding if registration fails.
`config_load` turns malformed TOML into defaults (e.g. `autosend = true`). With 3b's per-take fetch, a half-saved `config.toml` can make the next take press Enter.
- `app-config` exposes `config_error` (from `CFG_CONFIG_PARSE_ERROR`). Lowkey rejects such snapshots: it keeps the last valid config, logs it, and shows it in the menu.
- Hotkey changes are applied only when no take is recording. Register the new binding before releasing the old one, and restore the old one if registration fails.

### 6. Instrumentation and the release gates
- Split `asr` into WAV prep/write, per-pass socket elapsed, and daemon `duration_ms` (FluidAudio time only; it excludes model init and gate waits, so never attribute that difference to transport). Tag each take warm/cold/contended and record tail-rescue passes separately.
- Per-take outcome: native / fallback (with reason) / failed; warmups with duration.
- `tools/lowkey-report.sh`: transcript-free summary of app.log. Median/p90 overhead split by take length (short everyday takes matter most), fallback and failure rates, verify mismatches, cold-start recovery times. This replaces eyeballing the log for the v0.10.0/v0.11.0 gates.
- A memory-pressure/swap spot check (`memory_pressure`, `vm_stat`) during a normal working day with the daemon warm.

### 7. Device change while idle
On `AVAudioEngineConfigurationChange` with no take: rebuild the input graph for the new default device (`stop`, `reset`, `prepare`), recreate the converter on next start, and log the device. Mid-take behaviour stays (keep the partial take). Manual test: switch mics while idle, then dictate.

## 3c-2: capture correctness and login (v0.11.0 or next)

### 8. Make the "speak now" cue honest
Experiment first: play the chime when capture is confirmed (engine started, or first buffer arrived) instead of before `engine.start()`. Measure hotkey → chime vs hotkey → first audio, and test real recordings by speaking immediately at the cue (first words present?). Then shorten the wait (e.g. reuse converter/tap across takes). Ship whichever ordering never clips first words, even if the chime comes ~50–100 ms later.

### 9. Start at login
Opt-in menu toggle. One mechanism: `SMAppService.mainApp`, verified first for a self-signed app in `~/Applications` on macOS 27, including the "requires approval" state (shown as such, not treated as failure). Define disable, rebuild and move behaviour. If SMAppService can't work for this signing setup, use a LaunchAgent *instead* (never both). Verify TCC grants survive a login-item launch. With item 3, login also warms the daemon.

## Deferred (only with evidence)
- **Config file watcher (FSEvents):** pipeline settings already refresh per take. Only add it if needing Reload Settings for hotkey/sounds proves a real annoyance. It would need debouncing, path filtering and item 5's validity check.
- **Warm microphone / pre-roll:** after item 8, run *one* measured experiment. Any warm-capture mode needs a new buffer contract: separate engine-running from recording, discard idle buffers, bound pre-roll in memory, clear it on cancel/sleep/device change/opt-out, and accept the always-on mic indicator explicitly.
- **In-process model:** see the decision's revisit criteria.

## Tests (summary)
- Shell: lifecycle lock under concurrent ensure/refresh; idle check with live/dead/phase markers; `app-config` `config_error`, capabilities and marker dir; `warmup --json` states.
- Swift: supervisor state machine with a fake bridge (triggers, single flight, backoff, capability gate, off switch); marker lifecycle on every terminal path; config rejection and hotkey swap; timeout retry/discard.
- Manual: reboot → (login) → first take native and warm; kill the daemon → next take warms during recording; `./install.sh --force` during and right after a take → no cold take; stalled daemon → Retry works; mic switch while idle.

## Open questions for the user
1. Start at login as an opt-in toggle (proposed)?
2. Chime timing: is a ~50–100 ms later chime fine if it guarantees first words are captured?
3. Failed-take retention: is keeping a timed-out take's audio for 1 hour (for Retry) acceptable?
