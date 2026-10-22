# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for issue operations from inside this clone.

## Conventions

- Create an issue with `gh issue create --title "..." --body "..."`.
- Read an issue with `gh issue view <number> --comments`.
- List issues with `gh issue list --state open --json number,title,body,labels,comments`.
- Comment on an issue with `gh issue comment <number> --body "..."`.
- Apply or remove labels with `gh issue edit <number> --add-label "..."` and `gh issue edit <number> --remove-label "..."`.
- Close an issue with `gh issue close <number> --comment "..."`.

Infer the repository from `git remote -v`; `gh` does this automatically when run inside this clone.

## Publishing

When a skill says to publish to the issue tracker, create a GitHub issue.
