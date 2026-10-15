# Modes Redesign Spec (Draft)

> Status: Draft (planning only, no code changes yet)
> Scope: Redesign the **mode mental model** and UX without changing the tmux-first product identity.

---

## Summary

The current `short` / `long` modes overload two different concerns:

1. **Intent** (what kind of cleanup/transformation is desired)
2. **LLM budget behavior** (token/chunk sizing, overcorrection risk)

This redesign separates those concerns so the product is easier to understand and use:

- **Flow** = how capture/paste/send works (`tmux` vs `inline`)
- **Mode** = text transformation intent (prompt-backed, extensible)
- **Postprocess policy** = whether/how the LLM runs
- **Budget policy** = transcript-length-aware LLM sizing (only relevant when postprocess runs)

Default built-in mode becomes `code`, and **postprocess defaults to off**.

---

## Problem Statement

`short` / `long` were originally introduced as a practical way to manage:

- recording length expectations
- LLM output token limits
- chunk sizing
- overcorrection risk

That worked technically, but it is confusing in practice because users experience "mode" as a content or formatting choice.

### Why this causes friction

- `short` / `long` sound like recording-length categories, not writing intent.
- When postprocess is off, selecting `short` or `long` often feels meaningless (because mode prompt is not used).
- Users must think about LLM budget behavior even when they only want transcription + paste/send.
- The current model hides extensibility (prompt-backed custom modes) behind unclear built-in names.

---

## Product Positioning (Unchanged)

This redesign does **not** change the product identity:

- `tmux-whisper` remains a **tmux-first voice coding tool**
- `inline` remains a secondary but useful capture flow
- the primary value is async workflow throughput in tmux (record -> process -> paste/send while user context-switches)

---

## Goals

1. Make "mode" mean **intent**, not recording length.
2. Make postprocess behavior explicit and optional.
3. Remove the mental overhead of choosing `short` vs `long`.
4. Make custom prompt-backed modes obvious and easy to extend.
5. Preserve tmux vs inline as **flows**, not modes.
6. Keep migration cost manageable (compat layer / mapping from `short` / `long`).

---

## Non-Goals (This Design Phase)

- Reworking tmux vs inline capture semantics
- Rebranding internal `DICTATE_*` env vars or file paths
- Rewriting whisper transcription behavior (non-LLM transcript quality is still whisper-model dependent)
- Redesigning every config area outside mode/postprocess/budget semantics

---

## New Mental Model

### 1. Flow (capture/output path)

How the tool records, pastes, and sends text.

- `tmux`
- `inline`

Flow is **not** a mode.

### 2. Mode (intent / transformation template)

A mode is a prompt-backed transformation intent (when postprocess is enabled), plus related metadata.

Examples:

- `code` (default)
- `email` (example template / optional built-in)
- custom user modes

Mode answers: "What kind of cleanup/formatting should happen?"

### 3. Postprocess Policy

Controls whether the LLM runs:

- `off`
- `on`
- `auto` (future-friendly, optional)

When postprocess is `off`, transcription output still flows normally; mode remains selected but mode prompts are inactive.

### 4. Budget Policy (LLM only)

Controls transcript-length-aware LLM settings (tokens/chunking/guardrails).

This is **separate from mode** and only applies when postprocess runs.

Long-term goal: mostly automatic sizing based on transcript length.

---

## Defaults (Proposed)

- Default mode: `code`
- Default postprocess policy: `off`
- Default flow behavior: unchanged (`tmux` and `inline` remain separate command flows)
- Budget policy: automatic when postprocess is enabled (implementation can phase in)

Rationale:

- Real usage is already "code + postprocess off"
- whisper transcripts are often good enough
- tmux workflow throughput matters more than forced LLM cleanup
- mode should not feel mandatory for basic usage

---

## Built-In Modes (Initial)

### `code` (default)

Primary mode for tmux-first coding workflows.

Intended behavior when postprocess is enabled:

- preserve technical terms and tool names
- improve punctuation/formatting for prompts and instructions
- reduce obvious mishears using vocab and prompt guidance
- add light formatting improvements (for example backticks around CLI/tools/files where appropriate)
- avoid over-stylizing or "creative" rewriting

### `email` (example template / optional built-in)

Included mainly as an example of extensibility and a practical non-code use case.

Intended behavior when postprocess is enabled:

- structure a thought dump into an email draft
- improve clarity and tone
- produce ready-to-send email-style output

This mode demonstrates the system without making "prose/markdown" a core built-in concept.

---

## Mode Behavior When Postprocess Is Off

Modes remain selectable even when postprocess is off, but mode prompt behavior is inactive.

This should be visible in UX/output/status to reduce confusion.

Example status copy (conceptual):

- `mode: code`
- `postprocess: off (mode prompt inactive)`

This keeps the mode selection stable so users can toggle postprocess on later without re-selecting a mode.

---

## Proposed CLI UX (Conceptual)

### Flow commands (existing concept, clearer naming in docs)

- `tmux-whisper ...` (tmux flow commands)
- `tmux-whisper inline ...` (inline flow commands)

### Mode commands (intent)

- `tmux-whisper mode` -> show current mode + summary
- `tmux-whisper mode list`
- `tmux-whisper mode set <name>`
- `tmux-whisper mode show <name>`
- `tmux-whisper mode create <name>`
- `tmux-whisper mode edit [name]`
- `tmux-whisper mode rm <name>` (optional, later)
- `tmux-whisper mode copy <src> <dst>` (optional, later)

### Postprocess commands (policy)

- `tmux-whisper postprocess` -> show status (`off|on|auto`)
- `tmux-whisper postprocess off`
- `tmux-whisper postprocess on`
- `tmux-whisper postprocess auto` (future/optional)

### Budget/profile commands (advanced)

This can remain advanced/internal initially.

Potential future UX:

- `tmux-whisper budget`
- `tmux-whisper budget auto`
- `tmux-whisper budget show`

But this should not block the mode redesign.

---

## Config Model (Conceptual, Draft)

This spec does not require immediate config schema changes, but the target model should separate concerns.

### Conceptual shape

```toml
[postprocess]
policy = "off"   # off | on | auto

[postprocess.budget]
policy = "auto"  # auto | manual

[mode]
current = "code"

[flow.tmux]
# optional mode override (future/optional)
# mode = "code"

[flow.inline]
# optional mode override (future/optional)
# mode = "code"
```

### Mode definitions (prompt-backed)

Mode definitions remain file-backed and extensible (current pattern is good).

Conceptual metadata for each mode:

- description
- prompt content
- optional postprocess defaults/hints
- optional app triggers

Implementation can phase metadata in without breaking simple prompt-file modes.

---

## Migration Plan (`short` / `long`)

### Behavior mapping (proposed)

- `short` -> `code`
- `long` -> deprecated (optionally map to `email` only if user explicitly wants a second built-in)

### Compatibility approach (phased)

1. Read existing `short` / `long` config and modes
2. Treat `short` as `code` in CLI/status output (with migration hint)
3. Preserve old files temporarily to avoid breaking setups
4. Offer explicit conversion / rename path later if needed

### User-facing messaging

When old mode names are encountered:

- explain that `short` / `long` were budget-oriented legacy names
- direct users to intent-based modes (`code`, `email`, custom)

---

## Rollout Strategy (Implementation Phases)

### Phase 1: Mental model + UX naming cleanup

- Introduce `code` mode as the default visible mode
- Make postprocess status clearer (`off` means no mode prompt is applied)
- Keep existing internal mechanics working
- Add docs explaining flow vs mode vs postprocess

### Phase 2: Budget-policy separation (internal logic cleanup)

- Move `short` / `long`-style budget behavior into transcript-length-aware policy logic
- Reduce direct mode coupling to token/chunk settings
- Add better guardrails against overcorrection

### Phase 3: Extensibility polish

- Improve mode metadata (`description`, examples)
- Better mode CLI UX (`show`, `copy`, templates)
- Optional mode testing/preview command

---

## Testing / Validation Considerations (for implementation later)

1. Mode selection remains stable with postprocess off
2. Status/help output clearly explains inactive mode prompt when postprocess is off
3. `code` mode defaults do not regress existing tmux-first workflows
4. `short` / `long` configs continue to work during migration period
5. Postprocess-on behavior improves for coding prompts without overcorrection regressions
6. Budget auto-sizing behaves predictably across transcript lengths

---

## Open Questions

1. Should `email` ship enabled by default, or only as a template/example file?
2. Should `postprocess=auto` exist in the first implementation, or land after mode cleanup?
3. Do modes own postprocess defaults/hints, or should that remain entirely in policy config?
4. How visible should budget policy be in the CLI for non-power users?
5. Do tmux and inline need separate mode overrides immediately, or can this be postponed while keeping a single current mode?

---

## Decision Snapshot (Current Draft)

- `tmux` vs `inline` are **flows**, not modes
- `mode` means **intent** (prompt-backed transformation)
- `short` / `long` are legacy names and should be phased out
- default mode should be `code`
- default postprocess policy should be `off`
- budget behavior should be separated from mode and auto-sized by transcript length when postprocess runs
- `email` is a better second example mode than `prose`

