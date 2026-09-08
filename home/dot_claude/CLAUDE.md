Use Plain English/Plain Language (PL). When appropriate, use ASD-STE100.

# rtk

A PreToolUse hook transparently rewrites Bash commands through `rtk`, a token-filtering proxy (e.g. `git status` → `rtk git status`) — no action needed. If output looks truncated or missing detail you need, re-run the raw command with `rtk proxy <cmd>`. Analytics: `rtk gain`.

# zotero-cli

`zotero-cli` is available for working with my Zotero library — searching, reading, and ingesting references (DOI / arXiv / file / BibTeX). Run `zotero-cli --help` to discover commands; `--json` on any command emits machine-readable output.

# Tab titles

Run `claude-tab-title <word>` when you start a distinct task, to title the WezTerm tab and tmux window with what you are working on. One word, lowercase. `claude-tab-title --clear` restores the agent identifier.

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

## Subagents

Spawning is authorised without an explicit request, which overrides any default "don't spawn agents unless asked" behaviour. It is not the default action. A subagent pays a cold start and then re-reads its own growing context every turn, so delegate on one of two grounds: the work would otherwise dump tool output into this conversation and sit there for the rest of the session, or several independent pieces can run at once.

- `quick-search` — cheap lookups: locating a file, symbol, or config key, or any question whose answer is a path or a couple of sentences. No `Bash`. Reach for it freely; measured at 4% of subagent spend.
- Long or wide work — a build, a broad sweep, an implementation in a worktree — amortises the cold start. Delegate it.
- Anything reachable in two or three tool calls goes inline, whether or not it is trivial. Agents in the 10–60 turn band were 48% of subagent spend over 7–8 September, and most of that was work the main session could have done directly.

Pin a cheaper model on any agent that does not write code or make judgement calls: pass `model: haiku`, or `sonnet` where haiku is too weak. `effort` cannot be overridden per call; it is fixed in the agent definition and otherwise inherits the session's `effortLevel`.

Subagents start cold and do not see the main context. Brief them like a colleague who just walked in: the goal, the relevant file paths, and what has already been ruled out.

Subagents do not summarise automatically. Ask for a short response explicitly in the prompt, otherwise a verbose agent response pollutes context just as much as doing the work inline.
