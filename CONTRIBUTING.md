# Contributing

Thanks for contributing to Tmux Whisper, which is becoming Lowkey ([`ROADMAP.md`](ROADMAP.md)).

## Scope and Direction

- Lowkey, the menu-bar app, is the product. The CLI is its back end and is being retired step by step, so new user-facing features belong in Lowkey.
- CLI changes should serve Lowkey, file transcription, or the phase 1 ports (`docs/plans/LOWKEY_RENAME_ROADMAP.md`). Changes to the JSON contracts in `docs/CLI_CONTRACTS.md` are additive only, unless Lowkey changes with them and the app contract number goes up on both sides.
- Keep changes minimal and production-oriented. Pure logic goes in `KhulumaCore` (no AppKit) with tests; the `Khuluma` target stays a thin shell.

## Development Setup

```bash
git clone https://github.com/ricardo-nth/tmux-whisper.git
cd tmux-whisper
./tests/ci.sh
./install.sh --force
tools/make-signing-identity.sh   # once
tools/build-lowkey-app.sh
```

## Branching and PRs

- Create feature branches from `main`.
- Keep one coherent task per branch.
- Include rationale and risk in the PR description.
- Name the affected areas: `lowkey`, `cli`, `daemon`, `transcribe`.
- Note removals and contract changes in `CHANGELOG.md`.

## Validation Requirements

Before opening or merging a PR:

```bash
./tests/ci.sh
cd tmux-whisperd && swift test
```

If `swift test` reports "TestingMacros not found", run `swift build --build-tests` until it says "Build complete", then `swift test --skip-build`.

**Cleanup changes** must keep the bash and Swift pipelines in step. Regenerate the fixtures with `tests/gen-cleanup-fixtures.sh`, and check that `CleanupParityTests` passes.

**Runtime changes** also need a real-use check:

```bash
./install.sh --force
tools/build-lowkey-app.sh      # waits for a take in progress, then relaunches Lowkey
tmux-whisper doctor
tools/lowkey-report.sh         # after a few real takes
```

## Release Policy

- `main` is stable/releasable.
- Homebrew tap is updated from stable tags only.
- Do not ship personal machine-specific config defaults.

## Security and Privacy

- Never commit API keys, tokens, or private credentials.
- Keep defaults portable (`config/config.toml`, `config/vocab`).
- Do not hardcode user-specific paths or local secrets.
- Logs, usage and stats never record dictated text. Transcripts live in history, and briefly in Lowkey's pending spool until history has them.
