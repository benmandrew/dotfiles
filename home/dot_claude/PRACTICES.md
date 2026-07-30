# Claude Code workflow practices (for the human, not the agent)

These are practices to apply yourself when driving Claude Code. They are deliberately
*not* @-included from CLAUDE.md — the agent can't act on them, so they'd only burn
context budget every session.

## Small, focused sessions

One session per logical unit of work — "implement the auth middleware," then a new
conversation for "wire up the auth routes." Sessions that stay well within the context
window maintain coherence and avoid compaction mid-task.

This only works well alongside CLAUDE.md and PLAN.md. Without them, splitting sessions
means repeatedly re-establishing context that was already paid for. The practices are
interdependent.

## Proactive /compact

Run `/compact` yourself before auto-compaction triggers. Include explicit instructions
about what to preserve:

```
/compact preserve the current implementation plan and all file paths discussed
```

Self-triggered compaction gives control over the summary; auto-compaction does not.

## rtk meta commands

See `~/.claude/RTK.md` for the command list and the measured savings breakdown. The short version:
`rtk gain` reports 79.6%, but a single outlier `curl` carries 92.3M of the 107.7M saved. Everyday
filtering runs 12–17% on reads and greps, so treat rtk as a search-heavy-workload optimisation
rather than a blanket win.
