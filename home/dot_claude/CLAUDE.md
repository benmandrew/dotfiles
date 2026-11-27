Use Plain English/Plain Language (PL). When appropriate, use ASD-STE100.

# zotero-cli

`zotero-cli` is available for working with my Zotero library — searching, reading, and ingesting references (DOI / arXiv / file / BibTeX). Run `zotero-cli --help` to discover commands; `--json` on any command emits machine-readable output.

# Bibliography audits

To audit a bibliography or check references, read and follow `~/.claude/plugins/marketplaces/isaaccorley-skills/plugins/bib-audit/skills/bib-audit/SKILL.md`. Its `scripts/` and `references/` paths are relative to that file's directory.

# Tab titles

Run `claude-tab-title <word>` when you start a distinct task, to title the tmux window with what you are working on. One word, lowercase. `claude-tab-title --clear` restores the agent identifier.

# Best Practices

## Persistent state

Keep architectural decisions, constraints and standards in the project's `CLAUDE.md`, kept concise with detail in `@`-linked files. Keep the current plan in a `PLAN.md` or `TODO.md`, updated as work progresses.

## Prose

Use the `commit-message` agent for commit bodies. The output style covers all other prose.

## Line breaks in prose files

In files that are entirely prose (`.md`, `.txt`, `.tex`), put each paragraph on one line and never hard-wrap, since some renderers honour the newlines. If a file is already hard-wrapped throughout, keep its convention unless asked to reflow it.

## Batching commits

Group related changes into a single commit — a bug fix and its test, a refactor and the call-site update, a feature and the docs that describe it. Unrelated changes belong in separate commits even if they were made in the same session.

## Signed commits

Every repository requires signed commits unless its own instructions say otherwise. `~/.gitconfig` signs with SSH through `commit.gpgsign` and `tag.gpgsign`, and porcelain (`git commit`, `--amend`, `rebase`, `cherry-pick`) honours that. Plumbing does not: `git commit-tree` signs only with `-S`. Before pushing, check that `git log --format='%h %G? %s' <base>..HEAD` shows `G` on every commit. Because `tag.gpgsign` is on, a lightweight `git tag` fails with "no tag message?"; pass `-m`, or keep a backup ref as a branch.

## Subagents

Spawning is authorised without an explicit request, but it is not the default action. Delegate only when the work would dump tool output into this conversation, or when independent pieces can run at once.

- `quick-search` for cheap lookups whose answer is a path or a couple of sentences. Use it freely.
- Long or wide work (a build, a broad sweep, an implementation in a worktree) goes to an agent.
- Anything reachable in two or three tool calls goes inline.

Pin `model: haiku` (or `sonnet` where haiku is too weak) on any agent that does not write code or make judgement calls. `effort` cannot be set per call. Brief each agent with the goal, file paths and what is ruled out, and ask for a short reply.

## Worktrees

Create git worktrees only with the EnterWorktree tool, which puts them in `.claude/worktrees/` at the repository root. Never run `git worktree add` with a path beside the repository; a hook denies it.
