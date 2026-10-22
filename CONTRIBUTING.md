# Contributing

Thanks for contributing to Khuluma. Current product work is in [`LOG.md`](LOG.md).

## Scope and Direction

- Khuluma, the menu-bar app, is the product. The CLI is its back end and is being retired step by step, so new user-facing features belong in Khuluma.
- CLI changes should serve Khuluma, file transcription, or the phase 1 ports (`LOG.md`). Changes to the JSON contracts in `docs/CLI_CONTRACTS.md` are additive only, unless Khuluma changes with them and the app contract number goes up on both sides.
- `khuluma doctor --json` uses diagnostic schema 2 with neutral identity keys. v0.11.0 removes the old command/schema adapter and legacy environment aliases; app contract 3 and durable data formats remain unchanged. Use canonical interfaces in new callers and keep wrong-profile refusal and explicit recovery intact.
- Keep changes minimal and production-oriented. Pure logic goes in `KhulumaCore` (no AppKit) with tests; the `Khuluma` target stays a thin shell.

## Development Setup

```bash
git clone https://github.com/ricardo-nth/khuluma.git
cd khuluma
./tests/ci.sh
./install.sh --force
tools/make-signing-identity.sh   # once
tools/build-khuluma-app.sh
```

## Work tracking

Keep current tasks, priorities and decisions in `LOG.md`; completed public release notes belong in `CHANGELOG.md`. Routine work does not require a separate spec, PRD or issue. The old rename roadmap is retained as historical context in `docs/archive/KHULUMA_RENAME_ROADMAP.md`.

## Branching and PRs

- Create feature branches from `main`.
- Keep one coherent task per branch.
- Include rationale and risk in the PR description.
- Name the affected areas: `khuluma`, `cli`, `daemon`, `transcribe`.
- Note removals and contract changes in `CHANGELOG.md`.

## Validation Requirements

Choose validation for the behavior changed; these are the available CLI and Swift checks:

```bash
./tests/ci.sh
cd native && swift test
```

If `swift test` reports "TestingMacros not found", run `swift build --build-tests` until it says "Build complete", then `swift test --skip-build`.

**Cleanup changes** must keep the bash and Swift pipelines in step. Regenerate the fixtures with `tests/gen-cleanup-fixtures.sh`, and check that `CleanupParityTests` passes.

**Runtime changes** need a real-use check when installing or restarting the daily app is authorized. The commands below change the installed runtime; they are not required for every task or documentation edit:

```bash
./install.sh --force
tools/build-khuluma-app.sh      # waits for a take in progress, then relaunches Khuluma
khuluma doctor
tools/khuluma-report.sh         # after a few real takes
```

## Release Policy

- `main` is stable/releasable.
- Homebrew tap is updated from stable tags only.
- Do not ship personal machine-specific config defaults.

## Security and Privacy

- Never commit API keys, tokens, or private credentials.
- Keep defaults portable (`config/config.toml`, `config/vocab`).
- Do not hardcode user-specific paths or local secrets.
- Logs, usage and stats never record dictated text. Transcripts live in history, and briefly in Khuluma's pending spool until history has them.
