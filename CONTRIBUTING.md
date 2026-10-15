# Contributing

Thanks for contributing to Tmux Whisper.

## Scope and Direction

- Tmux Whisper is tmux-first.
- Inline mode and desktop integrations are important, but secondary to core tmux reliability.
- Keep changes minimal and production-oriented.

## Development Setup

```bash
git clone https://github.com/ricardo-nth/tmux-whisper.git
cd tmux-whisper
./tests/ci.sh
./install.sh --force
```

## Branching and PRs

- Create feature branches from `main`.
- Keep one coherent task per branch.
- Include rationale and risk in PR description.
- Reference affected flows explicitly (`lowkey`, `transcribe`, `tmux`, `inline`).

## Validation Requirements

Before opening/merging a PR:

```bash
./tests/ci.sh
```

If behavior changes in runtime flows, also test locally:

```bash
./install.sh --force
tmux-whisper debug
tmux-whisper doctor
```

## Release Policy

- `main` is stable/releasable.
- Homebrew tap is updated from stable tags only.
- Do not ship personal machine-specific config defaults.

## Security and Privacy

- Never commit API keys, tokens, or private credentials.
- Keep defaults portable (`config/config.toml`, `config/vocab`).
- Do not hardcode user-specific paths or local secrets.
