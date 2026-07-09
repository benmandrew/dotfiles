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

```bash
rtk gain              # Show token savings analytics
rtk gain --history    # Show command usage history with savings
rtk discover          # Analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
```

Note: measured savings are ~37% overall (`rtk gain`), concentrated in grep/test output.
