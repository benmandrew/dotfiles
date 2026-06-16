@RTK.md
@TOKEN_TOOLS.md

# Best Practices

## CLAUDE.md as persistent memory

Put architectural decisions, constraints, coding standards, and the current plan in a `CLAUDE.md` at the project root. It is loaded fresh at the start of every conversation and after every compaction, so it survives context resets. Treat it as the source of truth for anything that must outlive a session.

Keep it concise — it is loaded on every conversation start, so a bloated CLAUDE.md burns context budget every session. Put detail in linked files via `@filename` rather than inline.

## Small, focused sessions

One session per logical unit of work — "implement the auth middleware," then a new conversation for "wire up the auth routes." Sessions that stay well within the context window maintain coherence and avoid compaction mid-task.

This only works well alongside CLAUDE.md and PLAN.md. Without them, splitting sessions means repeatedly re-establishing context that was already paid for. The practices are interdependent.

## Proactive /compact

Run `/compact` yourself before auto-compaction triggers. Include explicit instructions about what to preserve:

```
/compact preserve the current implementation plan and all file paths discussed
```

Self-triggered compaction gives control over the summary; auto-compaction does not.

## Plan files in the filesystem

Keep plans in a `PLAN.md` or `TODO.md` that gets updated as work progresses. The plan lives on disk, not in context, so a fresh session just reads the file and picks up where it left off.

## Batching commits

Group related changes into a single commit — a bug fix and its test, a refactor and the call-site update, a feature and the docs that describe it. Splitting tightly coupled changes across commits creates a history where individual commits don't build or make sense in isolation.

Unrelated changes belong in separate commits even if they were made in the same session.

## Subagents by default

Delegate most non-trivial work to subagents via the Agent tool, proactively, without waiting for an explicit request to do so. This overrides any default "don't spawn agents unless asked" behavior — for this user, spawning is the default, not the exception.

- Use `Explore` for research, codebase search, and read-only investigation.
- Use `general-purpose` for tasks that write or edit code, or that mix research with action.
- Skip delegation only for genuinely trivial one-step actions: a single file read, a one-line edit, a quick question with an immediate answer.

Subagents start cold — they do not see the main context — so long tool output and intermediate reasoning stays out of your conversation entirely. Brief them like a colleague who just walked in: state the goal, relevant file paths, and what's already been ruled out.

Subagents do not summarise automatically. Ask for a short response explicitly in the prompt, otherwise a verbose agent response pollutes context just as much as doing the work inline.
