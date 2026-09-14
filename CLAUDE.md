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

- **Neovim config** — `home/dot_config/nvim/`; `home/dot_vimrc` is for vim only. Plugin setup lives in each lazy.nvim spec, loaded on a key, command or event. `.config/nvim/after` stays in `home/.chezmoiremove`, since nvim sources any leftover file there. Completion is Neovim 0.12's built-in; language server protocol (LSP) items need the `o` flag in `'complete'`, and `autotrigger` stays off, since beside `'autocomplete'` it doubles requests. `lazy-lock.json` is managed, so a plugin update trips chezmoi's "has changed" prompt.
- **Install scripts** — `scripts/`; see `scripts/CLAUDE.md`.
  - Versions are `*_VERSION` constants in one block, resolved by `pinned_tag <pin> <repo>`; `make pins` compares them with upstream. WezTerm alone takes the rolling `nightly` tag, upstream cutting no releases.
  - `download_verified` checks SHA-256 where upstream publishes a manifest. No `curl | sh`: installers download through `download()` and run from disk.
  - gitleaks runs in `make lint-secrets`, the pre-commit hook (`gitleaks git --staged`) and CI's `make lint-secrets-history` from a `fetch-depth: 0` checkout. The history scan stays out of `make lint`, since a shallow clone passes without looking. Every call passes `--redact`.
- **Nix and direnv** — macOS updates strip the Nix block from `/etc/zshrc`, so `home/dot_zprofile.tmpl` sources `nix-daemon.sh` or `~/.nix-profile/etc/profile.d/nix.sh` ahead of Homebrew; without it nix-direnv's `use flake` gets `/bin/bash` 3.2 and fails. `source_nix_profile` in `scripts/install-common.sh` unsets `__ETC_PROFILE_NIX_SOURCED` first and never sources `/etc/bashrc`, which kills the installer under `set -u`. `scripts/verify-install.sh` and `home/run_after_check-login-path.sh` both probe login-shell bash with `env -i ... zsh -lc`, duplicated because a target has no source directory; the deployed one runs after every apply, the change it watches happening in `/etc`, and always exits 0.
- **Template linting** — `scripts/lint-templates.sh` (`make lint-templates`, and the pre-commit hook when a `.tmpl` is staged) renders each template with `chezmoi --source . execute-template` and lints the output. `--source .` is required, or `home/.chezmoidata.yaml` is skipped and renders silently lose blocks. The `make lint-zsh` strip pass stays, since a render covers only this machine's OS branch.
- **Tmux** — `home/dot_tmux.conf.tmpl`, Hacktober theme, kept in sync with WezTerm's. `status-right` forks once a tick, into `.config/tmux/status.sh`, which tests `[ -r /proc/stat ]` rather than forking `uname`. `tmux-sensible` is inlined; tpm stays for resurrect and continuum, its `run` line guarded by `if-shell`. `base-index` and `pane-base-index` are 1 to match WezTerm's tabs. `terminal-features` carries `hyperlinks`, without which tmux strips Operating System Command (OSC) 8 links.
- **claude-aware panes** — both terminals walk a pane's process subtree for a session in `~/.claude*/sessions/<pid>.json` and read its `cwd` and agent name. Every reader globs `~/.claude*` so the work profile counts: `wezterm.lua`, `home/dot_claude/executable_wezterm-notify.sh`, and `claude-pane-session` and `claude-tab-title` in `home/dot_local/bin/`. The newest `statusUpdatedAt` wins, and pruning checks every profile. `~/.claude/tab-titles` and `~/.claude/tab-bells` stay single, a pid being machine-wide.
  - `claude-tab-title <word>` writes its override to a file of its own, since Claude Code rewrites the session JSON constantly.
  - tmux polls `claude-pane-session` per window per tick, so `status-left` rebuilds a shared cache once a tick and window lookups only read it. Keep forks off the per-window path; only the `status` fields call `date`. `status-current` is a separate field because the script cannot see which window is current, and `#{=24:...}` matches `TAB_TITLE_MAX_WIDTH`.
- **Zsh** — `home/dot_zshrc.tmpl`. Order is `~/.fzf.zsh`, fzf-tab (so it owns `^I`), `fzf-git.sh`, atuin, and zsh-autosuggestions last.
  - fzf-tab needs `zstyle ':completion:*' menu no`, and `-i` in its `fzf-flags` overrides fzf's *smart-case*. `_make_target_recipe` reads recipes with awk, since `make -n` runs `$(shell ...)` per keystroke.
  - `${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions` is prepended to `fpath` before `compinit`, so generated functions such as `_delta` beat system ones like `_sccs`.
  - `install_zsh_completions` runs last in both platform scripts, since it calls each binary; it skips tools with system-wide completion and deletes `.zcompdump` and `.zcompdump.zwc` afterwards.
  - `~/.zprofile` and `~/.zshenv` are managed. `LS_COLORS` is a literal, the block running before `PATH` is set. `GLOB_DOTS` stays unset, so `rm *` cannot take `.git`.
- **Shell autosuggestions** — cloned by `install_zsh_autosuggestions`. It loads last, wrapping every zsh line editor (ZLE) widget present, and after `atuin init zsh`, whose `ZSH_AUTOSUGGEST_STRATEGY` nothing overrides.
- **Shell history** — atuin, installed by `install_atuin`, replaces syncing `~/.zsh_history`, which conflicts in git on every append.
  - Config is `home/dot_config/atuin/private_config.toml` (0600 for `extra_headers`). The public Tailscale `sync_address` is deliberate. The `host` column is `{ type = "host", width = 5 }`.
  - `atuin init zsh` follows `~/.fzf.zsh` so it wins `^R`, with `--disable-up-arrow` and `--disable-ai`.
  - Manual: `atuin register`/`atuin login` and `atuin import auto`. `~/.local/share/atuin/key` is unmanaged; back it up in a password manager.
  - `ATUIN_HOST_NAME` comes from `atuin.hostnames` in `home/.chezmoidata.yaml`, keyed on `.chezmoi.hostname` as the machine reports it, names four characters or fewer. Earlier records keep the old hostname.
  - `HISTFILE` and `SHARE_HISTORY` stay set, as the offline fallback.
- **Git pager** — `core.pager` must sit under `[core]` in `dot_gitconfig.tmpl`; below `[diff "prose"]` git reads it as `diff.prose.pager` and ignores it.
- **Merge conflict style** — `dot_gitconfig.tmpl` renders `merge.conflictStyle` as `zdiff3` on git 2.35 or newer and `diff3` otherwise, since older git treats `zdiff3` as fatal.
- **Prose diffs** — `home/dot_local/bin/executable_git-prose-split` is the `diff=prose` textconv, applied by `home/dot_config/git/attributes`. No `cachetextconv`, whose blob-keyed cache goes stale when the splitter changes. It passes files through `cat` under VS Code (`VSCODE_GIT_IPC_HANDLE` or `VSCODE_GIT_ASKPASS_NODE`), whose gutter diff uses textconv.
- **Box tables** — `home/dot_local/bin/executable_unbox` turns box-drawing tables into markdown pipe tables. Box characters are matched as alternations of literal strings, never bracket expressions, since one-true-awk is byte-oriented.
- **Claude Code settings** — `home/dot_claude/modify_private_settings.json.tmpl` includes `.chezmoitemplates/claude-settings-modify.sh.tmpl`; managed keys live in `.chezmoitemplates/claude-settings.json.tmpl`. It is a `modify_` script because Claude Code rewrites and reorders the file. chezmoi owns `permissions`, `hooks`, `statusLine`, `env`, `enabledPlugins`, `extraKnownMarketplaces`, `attribution`, `includeCoAuthoredBy` and `skipDangerousModePermissionPrompt`. `model`, `theme`, `outputStyle` and `effortLevel` are seeded only into an empty file, and `feedbackDrafts` is left alone. The prefix is `modify_private_`; `private_modify_` silently leaves the file unmanaged.
- **Compaction and status carry-over** — `autoCompactWindow` is 300000 in the settings template, set as a setting because `CLAUDE_CODE_AUTO_COMPACT_WINDOW` locks `/config` out. `PostCompact` runs `home/dot_claude/executable_compact-status-write.sh`, saving `compact_summary` to `~/.claude/compact-status/<slug>.md`; `SessionStart` on `clear` alone runs `executable_compact-status-read.sh`. Summaries stay outside repos so gitleaks never scans them.
- **Two Claude accounts** — `alias cc-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'`, single-quoted so `$HOME` expands at run time. `home/dot_claude-work/` holds relative `symlink_` entries to `../.claude/<name>` for `agents`, `commands`, `skills`, `output-styles`, `CLAUDE.md`, `VOICE.md`, `PRACTICES.md` and `RTK.md`. Credentials, `settings.json`, `projects/`, `history.jsonl` and `sessions/` stay per profile; `sessions/` is never linked, being mode 0700 with a `.key` per session. The work `settings.json` is `home/dot_claude-work/modify_private_settings.json.tmpl`, including the same shared script. The work profile needs its own `claude plugin install`, and macOS keychain separation between profiles is untested.
- **VS Code** — `home/{Library/Application Support,dot_config}/Code/User/modify_settings.json.tmpl` includes `.chezmoitemplates/vscode-settings-modify.sh.tmpl`; managed keys live in `.chezmoitemplates/vscode-settings.json.tmpl`. It is a `modify_` script because VS Code rewrites `settings.json` itself, and it strips JSON with comments (JSONC) before `jq` merges the managed keys over the top.

Each rule above says what to preserve; the commit that introduced it records why.
