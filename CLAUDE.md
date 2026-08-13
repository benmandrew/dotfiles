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
- **claude-aware panes** — `~/.claude/sessions/<pid>.json` records each live session's `cwd` and its agent identifier (`counter-fe`, the name `gwt` lists). Both terminals walk the pane's process subtree for a registered session and read the two off it, falling back to their old behaviour when there is none.
  - *cwd* — new tabs/panes open where claude is *actually* working, not where the shell is. The two diverge once claude chdir()s (entering a worktree, say) while the shell sits suspended and never re-emits OSC 7.
  - *name* — tabs and windows are titled by agent, since `#{pane_current_command}` is `claude` for all of them alike. `wezterm-notify.sh` uses it for bell titles too, matching by `sessionId`.
  - WezTerm does this in-process (`claude_session` in `wezterm.lua`). tmux shells out to `home/dot_local/bin/executable_claude-pane-session`, which the status line polls per window every tick — so `status-left` rebuilds a shared cache once per tick and the per-window lookups only read it.
- **Zsh completion** — `home/dot_zshrc.tmpl`. [fzf-tab](https://github.com/Aloxaf/fzf-tab) (cloned to `~/.local/share/fzf-tab` by `install_fzf_tab`) renders the completion menu as an fzf picker with per-context preview panes. Three things it depends on: `zstyle ':completion:*' menu no` (zsh's own menu would fire alongside it), `zstyle ':completion:*:descriptions' format` (its group headers come from that label), and being sourced after `~/.fzf.zsh` so it owns the `^I` binding. Make-target previews come from `_make_target_recipe`, which reads the recipe out of the makefile with awk — `make -n` would evaluate `$(shell ...)` on every keystroke.
- **VS Code** — `home/{Library/Application Support,dot_config}/Code/User/modify_settings.json.tmpl`, both one-liners including `.chezmoitemplates/vscode-settings-modify.sh.tmpl`; managed keys live in `.chezmoitemplates/vscode-settings.json.tmpl` (strict JSON, no trailing commas). It is a **`modify_` script, not a plain file**, because VS Code rewrites `settings.json` itself whenever a setting is toggled or a prompt is dismissed — managing it as a file made every such write trip chezmoi's "has changed since chezmoi last wrote it" prompt. The script receives the live file on stdin, strips JSONC comments/trailing commas, and `jq`-merges the managed keys over the top, so chezmoi owns a subset of keys and VS Code keeps the rest.
