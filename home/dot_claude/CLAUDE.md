Use Plain English/Plain Language (PL). When appropriate, use ASD-STE100.

# rtk

A PreToolUse hook transparently rewrites Bash commands through `rtk`, a token-filtering proxy (e.g. `git status` → `rtk git status`) — no action needed. If output looks truncated or missing detail you need, re-run the raw command with `rtk proxy <cmd>`. Analytics: `rtk gain`.

# zotero-cli

`zotero-cli` is available for working with my Zotero library — searching, reading, and ingesting references (DOI / arXiv / file / BibTeX). Run `zotero-cli --help` to discover commands; `--json` on any command emits machine-readable output.

# Best Practices

## CLAUDE.md as persistent memory

Put architectural decisions, constraints, coding standards, and the current plan in a `CLAUDE.md` at the project root. It is loaded fresh at the start of every conversation and after every compaction, so it survives context resets. Treat it as the source of truth for anything that must outlive a session.

Keep it concise — it is loaded on every conversation start, so a bloated CLAUDE.md burns context budget every session. Put detail in linked files via `@filename` rather than inline.

## Writing prose

When a task calls for prose — PR descriptions, docs, READMEs, blog posts, comments beyond a line or two — delegate to the `voice` agent, which reads the spec itself. Use `commit-message` for commit bodies.

When writing prose inline instead, read `~/.claude/VOICE.md` first and follow it (it lives at that absolute path, not in the current working directory). It's a voice spec with two modes: **write-up** (first-person project narrative) and **explainer** (impersonal technical exposition). Pick the mode that fits, then apply its rules. Skip `~/.claude/VOICE.md` for pure-code work and short mechanical text.

## Line breaks in prose files

In files that are entirely prose (`.md`, `.txt`, `.tex`), put each paragraph on a single unbroken line. Never hard-wrap at a column width. Some markdown renderers honour those newlines and stop filling the page, so a wrapped paragraph renders with ragged early breaks. Blank lines still separate paragraphs as usual.

This governs the source layout only, and leaves the prose itself to `~/.claude/VOICE.md`. When editing a file that is already hard-wrapped throughout, keep its existing convention unless asked to reflow it.

## Plan files in the filesystem

Keep plans in a `PLAN.md` or `TODO.md` that gets updated as work progresses. The plan lives on disk, not in context, so a fresh session just reads the file and picks up where it left off.

## Batching commits

Group related changes into a single commit — a bug fix and its test, a refactor and the call-site update, a feature and the docs that describe it. Splitting tightly coupled changes across commits creates a history where individual commits don't build or make sense in isolation.

Unrelated changes belong in separate commits even if they were made in the same session.

## Subagents by default

Delegate most non-trivial work to subagents via the Agent tool, proactively, without waiting for an explicit request to do so. This overrides any default "don't spawn agents unless asked" behavior — for this user, spawning is the default, not the exception.

- `quick-search` — cheap lookups: locating a file, symbol, or config key, or any question whose answer is a path or a couple of sentences. No `Bash`.
- Skip delegation only for genuinely trivial one-step actions: a single file read, a one-line edit, a quick question with an immediate answer.

For read-only delegations that still need `Explore` or `general-purpose`, pin a cheaper model — pass `model: haiku`. Reserve the session model for agents that write code or make judgement calls. `effort` cannot be overridden per call; it is fixed in the agent definition and otherwise inherits the session's `effortLevel`.

Subagents start cold — they do not see the main context — so long tool output and intermediate reasoning stays out of your conversation entirely. Brief them like a colleague who just walked in: state the goal, relevant file paths, and what's already been ruled out.

Subagents do not summarise automatically. Ask for a short response explicitly in the prompt, otherwise a verbose agent response pollutes context just as much as doing the work inline.
