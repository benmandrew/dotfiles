# Token-Saving MCP Tools

## token-savior-recall

**Usage**: Code navigation MCP server (97% token savings via symbol-level indexing)

Indexes the codebase by functions, classes, and imports so Claude can look up symbols directly instead of reading whole files. Remembers decisions and conventions across sessions.

```bash
pip3 show token-savior-recall   # Verify installed
claude mcp list | grep token-savior  # Verify registered
```

Set `WORKSPACE_ROOTS` env var to index specific project directories.

---

## token-optimizer-mcp

**Usage**: MCP server for caching, compression, and tool management (95%+ reduction)

Runs on-demand via npx — no binary to maintain. Caches tool responses and compresses context automatically.

```bash
claude mcp list | grep token-optimizer  # Verify registered
```

---

## ccusage

**Usage**: Token usage analytics CLI + MCP server

CLI tool for analyzing Claude Code token usage from local JSONL logs. Also exposes an MCP server so Claude can query usage data directly.

```bash
ccusage             # Show usage summary
ccusage --daily     # Daily breakdown
claude mcp list | grep ccusage  # Verify MCP registered
```
