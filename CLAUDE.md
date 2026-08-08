# Chezmoi Dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) for cross-platform (macOS ARM64, Linux x86_64/ARM64) portability.

The chezmoi root is `home/` (see `.chezmoiroot`), so everything under it is relative to `~` on the target system.

## Templating

**Change detection (run_onchange scripts):**
```
# tmux-conf-hash: {{ include "dot_tmux.conf.tmpl" | sha256sum }}
```
Including a hash of a dependency in the script header causes chezmoi to re-run it when that file changes.

## Key Areas

- **Neovim config** — `home/dot_config/nvim/` — `home/dot_vimrc` is for real vim only; nvim never reads it.
- **Install scripts** — `scripts/` — see `scripts/CLAUDE.md` for the per-function breakdown
- **Tmux** — `home/dot_tmux.conf.tmpl` — Hacktober theme, kept in sync with WezTerm's
- **claude-aware cwd inheritance** — new tabs/panes open in the directory claude is *actually* working in, not the shell's. Claude Code registers live sessions in `~/.claude/sessions/<pid>.json` with their internal `cwd`, which diverges from the pane's once claude chdir()s (entering a worktree, say) while the shell sits suspended and never re-emits OSC 7. WezTerm resolves this in-process (`claude_cwd` in `wezterm.lua`, walking `get_foreground_process_info`); tmux shells out to `home/dot_local/bin/executable_claude-pane-cwd`, which walks the pane's process subtree for a registered session. Both fall back to the old pane-cwd behaviour when no claude session is found.
- **VS Code** — `home/{Library/Application Support,dot_config}/Code/User/modify_settings.json.tmpl`, both one-liners including `.chezmoitemplates/vscode-settings-modify.sh.tmpl`; managed keys live in `.chezmoitemplates/vscode-settings.json.tmpl` (strict JSON, no trailing commas). It is a **`modify_` script, not a plain file**, because VS Code rewrites `settings.json` itself whenever a setting is toggled or a prompt is dismissed — managing it as a file made every such write trip chezmoi's "has changed since chezmoi last wrote it" prompt. The script receives the live file on stdin, strips JSONC comments/trailing commas, and `jq`-merges the managed keys over the top, so chezmoi owns a subset of keys and VS Code keeps the rest.
