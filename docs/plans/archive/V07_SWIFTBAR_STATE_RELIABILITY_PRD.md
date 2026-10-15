# PRD: v0.7 SwiftBar State Reliability

## Problem Statement

Tmux Whisper has crossed into the v0.7 integration-platform track. The adapter lifecycle work is already in good shape: integration status, doctor, dry-run repair, real repair, and provenance/drift reporting all exist and the installed adapters currently report as current.

The next problem is the user-facing reliability of the SwiftBar menu state. The SwiftBar plugin is the visible indicator for recording, processing, ready, cancel, and error states. It already polls runtime markers and Raycast wrappers already request refreshes, but the roadmap still calls out SwiftBar/menu-state reliability as the first behavior-level integration-platform problem: event-driven refresh, stop-to-processing immediacy, sound cue timing, and stale menu-state recovery.

From the user's perspective, the integration files can be perfectly installed while the menu-bar state still feels laggy, briefly stale, or insufficiently trustworthy during the moments that matter: start, stop, processing, paste/send completion, cancel, and recovery from stale markers.

## Solution

Implement a focused SwiftBar state reliability slice for v0.7.

The solution should make SwiftBar status updates more deterministic around runtime lifecycle transitions while keeping the CLI and tmux-first behavior stable. Event-driven refresh should complement, not replace, SwiftBar's polling model. Runtime marker cleanup should prevent stuck recording or processing states. The implementation should remain shell-native and adapter-focused, without starting the native macOS companion track.

The result should be that a daily user can trust the menu-bar state:

- Recording appears promptly when a tmux or inline run starts.
- Processing appears promptly when inline recording stops and transcription/paste/send still owns the frontmost app.
- Ready or just-processed appears promptly after processing finishes.
- Cancel and error states remain brief and do not leave stale flags behind.
- Stale runtime markers are cleaned or surfaced consistently instead of leaving the menu bar stuck.
- Raycast and CLI-triggered flows behave consistently.

## User Stories

1. As a daily tmux-first user, I want SwiftBar to show recording promptly after I trigger tmux dictation, so that I know the hotkey worked.
2. As an inline dictation user, I want SwiftBar to show recording promptly after I trigger inline dictation, so that I do not speak into a dead-looking menu state.
3. As an inline dictation user, I want SwiftBar to switch to processing promptly after I stop recording, so that I know not to move away from the frontmost app too early.
4. As an inline dictation user, I want SwiftBar to keep showing processing until transcription, paste, and optional send are finished, so that the visible state matches when the target app is safe.
5. As a Raycast inline user, I want the Raycast script and SwiftBar state to agree, so that hotkey-driven usage feels reliable.
6. As a Raycast tmux-toggle user, I want the tmux recording state in SwiftBar to update after start and stop, so that I can use the menu bar as a sanity check.
7. As a user cancelling a run, I want SwiftBar to briefly show cancelled and then return to ready, so that cancellation is acknowledged without creating a sticky state.
8. As a user hitting an error path, I want SwiftBar to show a clear error briefly and offer a cleanup path, so that I know what happened and how to recover.
9. As a user with stale state files, I want SwiftBar to clean obviously stale recording state, so that the menu bar does not remain stuck after a crashed process.
10. As a user with stale processing markers, I want SwiftBar to clean stale marker files, so that processing does not linger after the owner process is gone.
11. As a support/debugging operator, I want CLI status and SwiftBar state to use compatible interpretations of recording and processing markers, so that I do not get conflicting diagnoses.
12. As an integration maintainer, I want SwiftBar refresh behavior to be expressed through one small helper or command surface, so that Raycast scripts and CLI lifecycle code do not keep duplicating refresh details.
13. As an integration maintainer, I want refresh calls to be best-effort and non-blocking where possible, so that hotkey latency is not worsened by menu-bar plumbing.
14. As an integration maintainer, I want refresh failures to be harmless, so that dictation still works when SwiftBar is not installed or cannot be opened.
15. As a tester, I want deterministic regression tests for recording, processing, ready, cancel, and stale-marker states, so that future integration work does not regress menu-state reliability.
16. As a reviewer, I want the implementation to preserve existing CLI JSON contracts, so that scripts and future wrappers are not broken by this behavior slice.
17. As a release maintainer, I want the changelog to describe the behavior-level SwiftBar reliability improvement, so that v0.7 progress is clear.
18. As the next implementation agent, I want the scope to stay limited to SwiftBar state reliability, so that I do not accidentally start the native macOS companion or broader integration-versioning work.

## Implementation Decisions

- Build this as a v0.7 integration-platform behavior slice, not as a v0.6 CLI-polish slice.
- Keep the current tmux-first CLI runtime as the source of truth. SwiftBar should observe and reflect runtime state, not invent a parallel state model.
- Add or consolidate a small SwiftBar refresh helper surface. It should hide the plugin refresh URL details and expose a simple best-effort operation that can be used by CLI lifecycle paths and adapter scripts.
- Refresh requests should be non-blocking on hot paths where practical. A failure to refresh SwiftBar must not fail dictation start, stop, cancel, transcription, paste, or send.
- Ensure refresh requests happen at meaningful lifecycle transitions: recording start, recording stop, inline processing start, processing completion, cancel, and error.
- Preserve SwiftBar's polling behavior. Event-driven refresh is an acceleration and reliability aid, not the only correctness mechanism.
- Keep SwiftBar marker interpretation aligned with CLI status semantics: active recording state, live inline processing markers, stale recording markers, stale processing markers, recent processed flag, recent cancel flag, and error flag.
- Harden stale recovery in the SwiftBar plugin where needed. Obvious stale files should be pruned; ambiguous cases should surface through existing CLI status/doctor flows rather than being silently misrepresented.
- Keep Raycast scripts thin. They may call the shared helper or public CLI command, but they should not grow their own state machine.
- Do not change the meaning or shape of existing stable JSON read contracts unless the change is additive and documented.
- Keep adapter repair/provenance behavior intact. This slice should not rework integration doctor, repair, or install receipt semantics except where a refresh helper naturally belongs in the integration command family.
- Update user-facing docs and changelog only for the behavior shipped in this slice.

## Testing Decisions

- Tests should assert external behavior: visible SwiftBar output, marker cleanup, refresh command behavior, and lifecycle side effects. Do not overfit tests to private helper names.
- Cover the SwiftBar plugin states with regression tests: ready, recording, processing, just processed, cancelled, missing binary, disabled integration, and stale marker cleanup.
- Cover Raycast wrapper behavior with regression tests that verify refresh is requested without making dictation failure-prone.
- Cover CLI lifecycle paths with flow-parity tests where runtime markers are already stubbed: inline start, inline stop-to-processing, processing completion, tmux start, tmux stop, and cancel.
- Use the existing shell test style and temp runtime directories. Do not require live SwiftBar, live Raycast, a real microphone, or real CoreML transcription in CI.
- Add a stub for the SwiftBar refresh mechanism so tests can assert that refresh was requested while keeping macOS GUI calls out of CI.
- Run the full validation command after implementation: `./tests/ci.sh`.
- After implementation, install to the local runtime with `./install.sh --force` and smoke-test the installed command with `tmux-whisper status`, `tmux-whisper integrations doctor`, and `tmux-whisper integrations repair --dry-run`.

## Out of Scope

- Building a native macOS menu-bar companion.
- Replacing SwiftBar polling with a persistent daemon or push-only model.
- Reworking Raycast Script Command setup beyond the refresh/state reliability needs of this slice.
- Changing capture, transcription, Parakeet, tail rescue, chunking, or paste/send semantics.
- Changing Homebrew formula packaging.
- Renaming legacy `dictate` config or temp paths.
- Adding a dashboard or TUI.
- Broad integration versioning beyond what is needed for SwiftBar state reliability.

## Further Notes

- Current branch for the slice: `codex/v0.7-swiftbar-state-reliability`.
- Current stable release remains `v0.6.0`; active development track is `v0.7.x`.
- Baseline before this PRD: repository CI passed, installed runtime reported ready/warm, and installed Raycast/SwiftBar adapters reported current with zero warnings.
- The implementation handoff is intentionally concrete enough for GPT-5.5-low to execute. Review should be done with extra-high reasoning, focusing on shell safety, lifecycle races, non-blocking behavior, and regression coverage.
