# rtk

`rtk` is a token-filtering proxy for command-line tools. A *PreToolUse* hook rewrites Bash
commands through it transparently, so `git status` runs as `rtk git status` at no cost in tokens.

## Measured savings

Aggregate savings across 16,675 commands are 107.7M tokens, or 79.6% (`rtk gain`). That headline
is misleading. A single `curl` of a large remote file accounts for 92.3M of it — one command, 86%
of the total. Excluding that outlier leaves 15.4M tokens saved across everything else.

The per-command figures are the honest ones:

| Command | Calls | Saved | Rate |
|---|---|---|---|
| `rtk read` | 2,121 | 9.8M | 12.7% |
| `rtk grep` | 1,087 | 2.4M | 17.4% |
| `rtk git diff` | 140 | 113.7K | 31.2% |

Savings concentrate in *grep* and test output, where filtering discards repetitive matches. Reads
of ordinary source files gain little, because there is not much to strip.

## Meta commands

These bypass the filter and are always run as `rtk` directly:

```bash
rtk gain              # Token savings analytics
rtk gain --history    # Command usage history with savings
rtk discover          # Analyse history for missed opportunities
rtk proxy <cmd>       # Run a command raw, without filtering
```

`rtk proxy` takes a command and its arguments, not a shell string. Pipes and redirections are
handed to the wrapped binary as literal arguments and will fail.

## Verification

```bash
rtk --version         # Expect: rtk 0.42.4 or later
which rtk
```

A name collision exists: reachingforthejack/rtk (Rust Type Kit) installs a binary of the same
name. If `rtk gain` reports an unknown subcommand, the wrong tool is on `PATH`.

The filter earns its place on search-heavy work. The 60–90% claim that once headed this file was
never measured on this machine.
