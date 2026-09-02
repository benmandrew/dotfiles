# Dotfiles audit — remediation plan

Audit run 2 September 2026 across shell, editor, terminal, git and provisioning. Full report with measurements: https://claude.ai/code/artifact/50a7d944-8a0d-48b7-8e8f-b8c4515d48ae

Measured on this machine (macOS 25.5.0 arm64, nvim 0.12.5, tmux 3.7c, zsh 5.9): warm shell start 56.2 ms ± 2.7, cold 357 ms, per-prompt 25–30 ms, nvim start 51.6 ms, tmux status tick ~50 forks per 5 s.

The shell and terminal layers are heavily worked and hold up. The editor config has drifted: `scripts/install-common.sh` has 94 commits, no nvim file has more than five, last touched 27 July.

## Status

Applied 2 September 2026, uncommitted. `make lint` and `make fmt-ci` pass; every template renders and every rendered zsh file parses. Nothing has been installed on this machine — the tool entries below add functions to `scripts/`, which run on the next `--upgrade`, and no install function was executed. **`chezmoi apply` has not been run**, so the live config is still the old one; `chezmoi diff` shows 27 files.

Still open, and both minor: `_zoxide` completion, and the `_copilot` orphan in `~/.local/share/zsh/site-functions` (a machine artefact rather than a repo change). One item was reversed on review — `GLOB_DOTS` is deliberately left unset, since it would make `rm *` take `.git` with it.

One finding was added during the work rather than during the audit, and is the most consequential of the git items: see the `core.pager` entry below.

## Fix first

- [x] **1. `~/.zprofile` and `~/.zshenv` are unmanaged.** They hold `brew shellenv`, `~/.elan/bin` and `. ~/.cargo/env`. `chezmoi managed` lists `.zshrc` alone, while `home/dot_zshrc.tmpl:105` hardcodes `HOMEBREW_BASE=/opt/homebrew/opt` and `home/dot_fzf.zsh.tmpl:3-6` sources from it. A fresh Mac provisioned from the install scripts comes up with no Homebrew on `PATH`. Add `dot_zprofile.tmpl` and `dot_zshenv.tmpl`.
- [x] **2. Neovim has no completion.** `nvim-cmp` and `LuaSnip` are declared at `home/dot_config/nvim/lua/benmandrew/lazy.lua:40-42` but `cmp.setup()` is never called; the only reference is `cmp_nvim_lsp` for capabilities at `after/plugin/lsp.lua:23`. `vim.o.autocomplete` is false and `vim.lsp.completion.enable()` is never called either. Every LSP server is told the client supports snippet-capable completion and nothing consumes the results.
- [x] **3. tmux CPU/RAM readouts fail on macOS.** `home/dot_config/tmux/executable_cpu.sh:2` reads `/proc/stat` and `ram.sh:2` reads `/proc/meminfo`; both are called unconditionally at `home/dot_tmux.conf.tmpl:95`. `wezterm.lua:488-544` already has correct `ps`/`vm_stat`/`sysctl` implementations to port.
- [x] **4. `tmux-sensible` has never been installed.** `install_tmux_plugins` at `scripts/install-common.sh:1641` clones tpm but never runs `install_plugins`; `~/.tmux/plugins/` holds `tpm` alone. So `history-limit` is still tmux's default 2000 lines, and `aggressive-resize`, `display-time` and `status-keys` are unset.
- [x] **5. `ai-commit-msg` runs model output unconfirmed.** `home/dot_local/bin/executable_ai-commit-msg:19` sets `interpreter.auto_run = True`, so open-interpreter executes whatever the Qwen endpoint emits in the current directory, for a script that only prints a commit message. Also hardcodes a Tailscale IP with no override (`:23`) and gives `interpreter.chat` no timeout (`:53`).
- [x] **6. `pull.rebase` is on without `rebase.autoStash`.** `home/dot_gitconfig.tmpl:5` — every `git pull` on a dirty tree aborts, across 3,006 commits and 281 rebases of recorded history.
- [x] **7. Neovim diagnostics are invisible.** `vim.diagnostic.config()` is never called; on 0.11+ `virtual_text` defaults to false, so errors show as a sign and underline with no message until `gl`.
- [x] **8. A `.pyc` is tracked and deployed.** `home/dot_local/bin/__pycache__/executable_ai-commit-msgcpython-314.pyc`, added in `bfb5d0c`. `git check-ignore` exits 1 — root `.gitignore` covers only `.claude/` and `.direnv/`. It is CPython 3.14 bytecode for a script pinned `>=3.10,<3.13`, and chezmoi copies it to every machine.
- [x] **9. `ocamllsp` enabled, binary absent.** `after/plugin/lsp.lua:34` enables it; `~/.opam/default/bin` has neither `ocaml-lsp-server` nor `ocamlformat`, against ~2,600 `dune` and ~2,850 `opam` invocations. `clangd` is the inverse — installed on both platforms, missing from the `vim.lsp.enable` list, against 2,406 `cmake` invocations.

## Shell — `home/dot_zshrc.tmpl`

- [x] `LS_COLORS` is empty at runtime, so the `zstyle list-colors` at `:62` is a no-op and the completion menu is uncoloured. Nothing runs `dircolors` or eza's exporter.
- [x] The ssh-agent block at `:91-94` forks an unreaped `ssh-agent` plus a recursive `grep -slR` of `~/.ssh` on every new terminal, on any machine without an inherited `SSH_AUTH_SOCK`. Inert on macOS.
- [x] `_cache_eval` at `:325-340` keys on `$1` plus binary path and mtime, ignoring its own arguments — editing `zoxide init zsh --cmd cd` or atuin's flags leaves the stale cache indefinitely. Hash `"$@"` into the stamp.
- [x] `$HOME/.cargo/bin` is absent from the macOS PATH block at `:114-120` though present in the Linux one at `:144`. It arrives via `~/.zshenv` at PATH position 57 of 65, behind `/opt/homebrew/bin` — the shadowing the comment at `:109-113` exists to prevent.
- [x] Four `setopt` lines, no `unsetopt`. Absent and verified off: `HIST_IGNORE_SPACE`, `HIST_IGNORE_ALL_DUPS`, `HIST_REDUCE_BLANKS`, `HIST_VERIFY`, `AUTO_CD`, `AUTO_PUSHD`, `PUSHD_IGNORE_DUPS`, `EXTENDED_GLOB`, `GLOB_DOTS`, `NO_CASE_GLOB`.
- [x] `BEEP` is on (set by `/etc/zshrc`, never unset) so every ambiguous completion beeps; `FLOW_CONTROL` is on so `^S` freezes the terminal.
- [x] `HIST_IGNORE_SPACE` matters more than usual: `HISTFILE` is documented as the offline fallback, so a leading-space command atuin's `secrets_filter` would drop still lands in the 1.5 MB `~/.zsh_history`.
- [x] No `edit-command-line` — no autoload, no `zle -N`, no bindkey, so `^X^E` is unavailable.
- [x] Home/End/Delete unbound in the repo; `^[[3~` is not bound to `delete-char`. `/etc/zshrc`'s terminfo bindings run before `bindkey -e` at `:289`, so relying on them is fragile.
- [x] Git aliases at `:257-268` are read-only verbs — no commit, push, pull, branch or checkout. `unalias gl` at `:281` removes a name nothing redefines. No `ll`/`la`, `mkcd`, or `..`/`...`.
- [x] `_zoxide` completion. The finding as written was partly wrong, and investigating it narrowed the real gap. `cd` completion was never missing: `zoxide init zsh` ends with `compdef __zoxide_z_complete cd`, guarded on `compdef` existing, and `compinit` runs at `:54`/`:57` well before the init at `:522`, so it registers. Verified live (`_comps[cd] = __zoxide_z_complete`) and in a pty — `cd Doc<TAB>` completes to `cd Documents/` through `_cd -/`, and the trailing-space path opens zoxide's fzf picker. Completion for the `zoxide` command itself was also present on macOS, because Homebrew links `_zoxide` into its site-functions. The genuine gap is Linux, where `install_cargo_tool` drops a bare binary into `~/.local/bin` with no package manager to link anything, and zoxide 0.9.9 has no `completions` subcommand for `install_zsh_completions` to call. Its release tarball ships `completions/_zoxide`, so `_install_rust_tool_binary` now installs a `_<cmd>` found in the archive it has already extracted, skipping where `_zsh_completion_installed` finds a system-wide copy so the package manager keeps ownership. `fd` picks its own shipped completion up the same way.
- [ ] `_copilot` sits in `~/.local/share/zsh/site-functions` as an orphan — nothing in the repo references it. A machine artefact rather than a repo change, so `rm` is the whole fix.
- [ ] `cdi` has no completion at all (`_comps[cdi]` is unset). Upstream's init deliberately registers only `cd`, so this is a deviation to choose rather than a bug to fix.
- [x] No guards on `eza` (`:242`), `moor` (`:198`) or brew's fzf files (`home/dot_fzf.zsh.tmpl:5-6`) — on a fresh box `ls` and `man` are both broken.
- [x] `INTERACTIVE_COMMENTS` is on only because atuin's init sets it; a machine without atuin loses it silently.
- [x] Cold `compinit` rebuild is 357 ms — regenerate to a temp dump in the background and `mv` into place.
- [x] `home/dot_fzf.zsh.tmpl:12` forks fzf on every Linux shell start (~7 ms), the one tool init not routed through `_cache_eval`.
- [x] `home/dot_config/starship.toml:9` sets `command_timeout = 2000`, so one hung probe stalls the prompt two seconds. `directory` alone is 10 ms of the 17.9 ms prompt.
- [x] `_osc7_cwd` at `:161-171` forks `$(printf …)` once per non-ASCII character in `$PWD`.
- [x] `home/dot_zshrc.tmpl:404` `{{ end }}` lacks the leading dash, leaving a stray blank line in the rendered output.

## Editor — `home/dot_config/nvim/`

- [x] LuaSnip is dead weight: no `from_vscode.lazy_load()`, no `friendly-snippets`, no expand keymap, ~10 ms of a 51.6 ms startup (20%).
- [x] `o.undofile` unset while undotree is installed, so history dies with the session.
- [x] `expandtab`/`shiftwidth`/`tabstop` unset in `lua/benmandrew/init.lua`, so defaults are hard tabs at width 8 and editing this repo's own 4-space Lua inserts tabs.
- [x] `ignorecase`/`smartcase` unset; `signcolumn=auto` shifts text horizontally on every edit with gitsigns attached; `updatetime` at the 4000 ms default lags `current_line_blame` four seconds. Also unset: `scrolloff`, `splitright`, `splitbelow`, `cursorline`.
- [x] `clipboard=unnamedplus` at `init.lua:11` with no black-hole maps — every `d`, `c` and `x` clobbers the system clipboard, and pasting over a visual selection destroys the pasted text.
- [x] `after/plugin/` defeats lazy-loading: nine files `require()` their plugin at startup. The one genuine lazy spec (which-key on `VeryLazy`) is negated by `after/plugin/which-key.lua:1` — the profile shows it loading at t=42 ms. diffview, undotree, fugitive, telescope and harpoon need never load at startup.
- [x] Catppuccin is set up twice — `lazy.lua:27-30` and `after/plugin/colors.lua:7-8`. The second costs 1.4 ms and re-runs every highlight group.
- [x] `gi` and `gr` clobber Vim builtins at `after/plugin/lsp.lua:7,9`. Neovim 0.11 ships `gri`/`grr`/`grn`/`gra`/`gO` for this. `]d`/`[d` use the deprecated `goto_prev`/`goto_next`, replaced by `vim.diagnostic.jump({count=1})`.
- [x] gitsigns hijacks `]c`/`[c` unconditionally at `after/plugin/gitsigns.lua:12-17` — should check `vim.wo.diff` and fall through. `<C-e>` for harpoon overrides scroll-down-one-line.
- [x] which-key omits every LSP mapping (`gd`, `gr`, `gi`, `go`, `gs`, `gl`) and `<F2>`/`<F3>`/`<F4>` — the maps most needing a reminder.
- [x] Telescope pinned to `tag = "0.1.6"` at `lazy.lua:20`, commit `6312868` dated 25 December 2023.
- [x] `vim.loop` at `lazy.lua:4` is deprecated; `lsp/lua_ls.lua:4` already uses `vim.uv`.
- [x] `lazy-lock.json` is not managed by chezmoi, so plugin versions drift per machine.
- [x] Formatting absent — `conform.nvim` added, wiring the `stylua` and `shfmt` the flake already provides (`shfmt` with `-ci`, matching `make fmt`). `telescope-fzf-native` added with `build = "make"`, a `cond` on `make` existing and a `pcall` around `load_extension`, so it degrades where the build has not run.
- [ ] Deliberately not added, since none fixes a finding and the ask was to fix rather than expand the plugin set: `nvim-lint`, a statusline, surround, autopairs, treesitter textobjects, session management.

## Terminal — `home/dot_tmux.conf.tmpl`, `home/dot_config/wezterm/wezterm.lua`

- [x] Status tick is ~50 forks per 5 s at five windows: one `refresh` (40 ms), three system scripts, two per window (14.8 ms each). `cpu.sh` is 228 ms wall, almost all a blocking `sleep 0.2`. Fold cpu/ram/uptime into one script emitting a preformatted string.
- [x] `status-interval 5` at `:94` against WezTerm's 1 s TTL, so busy-to-idle lags up to five seconds. Drop to 1 only after the fork cost above is fixed.
- [x] `:8` appends `RGB:extkeys` but not `hyperlinks`, and tmux's built-in `xterm*` set omits it — so OSC 8 links from delta, eza and gh are stripped inside tmux, defeating `wezterm.lua:978-1007`.
- [x] `base-index`, `pane-base-index` and `renumber-windows` unset. tmux `#I` starts at 0 while `wezterm.lua:381` renders `tab_index + 1`, so `C-a 1` lands on the second window.
- [x] Three prefix bindings shadowed with no replacement: `:33` `bind s` kills the session picker, `:38` `bind l` kills `last-window`, `:39` `bind x` removes the kill-pane confirmation.
- [x] `home/run_onchange_reload_tmux.sh.tmpl:29` sends `source ~/.zshrc` + Enter to every zsh pane, including one with a half-typed command. Prefix with `C-u`.
- [x] No session persistence (resurrect/continuum) though tmux auto-starts on every SSH host at `dot_zshrc.tmpl:459-465`. No `display-popup` bindings.
- [x] `home/dot_local/bin/executable_claude-pane-session:27-29` falls back to `/tmp/claude-pane-session.tsv`, not per-user despite its comment; the sticky bit makes `mv -f` fail against another user's file. Add `.$(id -u)`.
- [x] `:204` forks `find` per window per tick for a cache-freshness check that `status-left`'s refresh already covers.
- [x] `:48` uses `ps -axo`, mixing UNIX `-a` with BSD `x`; `ps -eo` is the POSIX spelling for both.
- [x] `executable_git-wt:177-178` pads with awk `length()` (bytes, not display width) and `:114` truncates with `substr(who,1,23)`, which can split a UTF-8 sequence.
- [x] WezTerm renders an `active_workspace` chip at `:653-659` with no `SwitchToWorkspace`, `ShowLauncher` or prompt bound — it can only read `default`.
- [x] No `TogglePaneZoomState` and no leader resize table in WezTerm, breaking the leader symmetry with tmux's `prefix z`.
- [x] WezTerm unset: `unicode_version` (defaults to 9, and the tab bar uses Nerd Font MDI glyphs), `warn_about_missing_glyphs`, `check_for_updates`, `harfbuzz_features`, `quick_select_patterns`, `max_fps`, `ReloadConfiguration` binding.

## Git — `home/dot_gitconfig.tmpl`

- [x] **`git diff` never went through delta.** Found while applying the fixes above, missed by every audit pass. The `pager = delta --paging=never | moor` line sat below the `[diff "prose"]` header, so git read it as `diff.prose.pager` — a diff driver takes `textconv`, `cachetextconv`, `binary`, `command`, `xfuncname` and `wordRegex`, and no `pager`. `core.pager` was therefore unset and git fell back to `$PAGER` from `dot_zshrc.tmpl:196`, rendering `git diff`, `git log -p` and `git show` through bare moor. `[delta] navigate` and `line-numbers` had never applied to any of them. `git add -p` was unaffected, since `interactive.diffFilter` is a top-level key. Verified before the fix with `git config --get core.pager` (exit 1) and `git var GIT_PAGER` (`moor --wrap --tab-size=4 --quit-if-one-screen`); verified after by rendering the template and re-reading `core.pager`.

- [x] Absent: `rebase.updateRefs` (the repo installs `gh-stack`; without it a base rebase strands every stacked branch), `rerere.enabled`, `merge.conflictstyle=zdiff3`, `push.autoSetupRemote`, `fetch.prune`/`pruneTags`, `diff.algorithm=histogram`, `diff.colorMoved`, `commit.verbose`, `branch.sort=-committerdate`, `tag.sort=-version:refname`, `column.ui`, `help.autocorrect`, `push.followTags`.
- [x] `protocol.file.allow = always` at `:15-16` globally re-enables the transport git disabled in 2.38.1 for CVE-2022-39253. No consumer found in this repo. **Decide before changing — may serve a workflow outside this repo.**
- [x] `branch.sort` absent while the `bv` alias at `:13` hand-rolls exactly it, so plain `git branch` disagrees with the alias.
- [x] `core.attributesFile` at `:24` points at git's own XDG default and is redundant. `core.excludesfile` uses the non-default `.gitignore_global` where `~/.config/git/ignore` needs no config.
- [x] `home/dot_config/git/dot_gitignore_global` holds only `.DS_Store` — no `__pycache__/`, `*.pyc`, `.venv/`, `node_modules/`.
- [x] `home/dot_config/git/dot_gitmessage:10-11` has trailing whitespace.

## Provisioning — `scripts/`, `Makefile`, CI

- [x] No integrity verification anywhere: zero checksum or signature checks across ~15 tarballs and eight vendor installers. The download path itself is sound — there is no `curl | sh`; every installer fetches to a temp file through `download()`, which sets `-f --proto '=https' --tlsv1.2`, then executes from disk.
- [x] `github_api_curl:425-431` omits the TLS flags `download()` applies, on exactly the calls that pick which version to install. `install_go:1992` runs a bare `curl` unchecked, yielding an empty version and a tarball named `.linux-amd64.tar.gz`.
- [x] Nothing version-pinned: no `*_VERSION=` constants, ten call sites resolve through `github_latest_tag`. That function never checks curl status (`:440`) — a rate limit yields an empty tag, guarded in `install_rust_tool:977-980` but not in `install_atuin:1259`, `install_cmake:867` or `install_wezterm:1711`.
- [x] `install_direnv:1403` runs `bash "${script_path}"` with no `|| return 1`, alone among the eight installers — a failed install reports success.
- [x] `install_go` guards its download but not the `tar` at `:2000`, after `sudo rm -rf /usr/local/go` has run. `install_lua_ls` leaves `tar -xf` unchecked at `:1876` and never `mkdir -p`s `~/.local/bin` before `ln -sf` at `:1877`, unlike its moor, glow and treehouse siblings.
- [x] `quiet` at `:57-75` saves and restores the tty per step but installs no `trap ... INT TERM`, so Ctrl-C skips the restore — the exact breakage the comment at `:43-48` says it prevents. `_STEP_LOG_DIR` has no EXIT trap.
- [x] `parse_args`'s `for arg in "$@"` loop variable at `:314` is not `local`.
- [x] `install_treehouse:2114` and `install_atuin:1259` hit the GitHub API before their `command -v` skip check.
- [x] `install_tmux_from_source:1623` uses GNU-only `nproc` with no OS guard, safe only because Linux alone calls it.
- [x] `scripts/install-macos-arm64.sh:13` discards `brew upgrade` failure with `|| true`, then only reinstalls entirely-missing formulae.
- [x] `scripts/verify-install.sh:5` builds a PATH omitting `/opt/homebrew/bin`, so every brew tool reports FAIL unless brew is already on the caller's PATH. It has drifted too — `go` installs on Linux and is never checked; nix-direnv unchecked.
- [x] `Makefile:62` `lint-sh` and `:26` `fmt` glob `scripts/*.sh` only, leaving twelve scripts unlinted and unformatted: the seven in `home/dot_local/bin/`, four tmux status scripts, and `wezterm-notify.sh`. Three of them lack `set -eu`.
- [x] `Makefile:66-68` `lint-ssh` writes a predictable `/tmp` path whose `rm -f` never runs when the linter fails.
- [x] `Makefile:47` `find … | xargs taplo lint` breaks on paths with spaces and runs argument-less with no TOML files. Use `-print0 | xargs -0 -r`.
- [x] `Makefile:16-21` `deps` is brew-only (fails on Linux) and duplicates `flake.nix`, already diverged — luacheck via luarocks here, `lua54Packages.luacheck` there. `flake.nix:37-48` ships no `make` while every entry point is `nix develop --command make`.
- [x] `.githooks/pre-commit` runs whole-tree `make fmt-ci` + `make lint` rather than staged files, and needs the nix devshell on PATH, so committing outside `nix develop` fails.
- [x] `.github/workflows/ci.yml` has no `permissions:` block (default token scope, passed into the install job at `:116`), no `concurrency:` group, no `timeout-minutes` on a job that saves a 1.1 GB cache and builds tmux from source. All actions float on major tags rather than SHAs.
- [x] `executable_git-wt:69-77` forks one `jq` per session file where `claude-pane-session:57` does a single `jq` over all of them.
- [x] `executable_git-rv:35` assumes remote URLs contain no spaces; one that does shifts the fields and mislabels fetch/push.
- [x] `executable_git-wt`, `executable_git-rv` and `executable_make-target-recipe` are mode `100644` in the index while the other three bin scripts are `100755`, so they cannot be run from the source tree.

## Tools worth adding

From recorded atuin command frequency, not from a list of popular tools.

- [x] `ocaml-lsp-server` + `ocamlformat` — 2,643 `dune`, 2,853 `opam`; the editor integration is enabled and dead. Add to `install_opam`.
- [x] `git-absorb` — 3,006 commits, 2,551 `git add`, 281 rebases, 209 stashes.
- [x] `cargo-nextest` — 160 `cargo test` against 360 `cargo clippy`, 418 `cargo run`. Ships release binaries, matching the `install_rust_tool` pattern from `cae20ec`.
- [x] `fzf-git.sh` — 13,437 git invocations on an already deep fzf investment. Same install shape as `install_fzf_tab`.
- [x] `gitleaks` — public repo, `core.hooksPath` already set, gitconfig carries a token-reading credential helper.
- [x] `ansible-lint` — 461 `ansible-playbook`, 96 `ansible-vault`, against an otherwise exhaustive lint matrix.
- [x] `sccache` — 2,406 `cmake`, 250 `cargo build`; one cache covers both.
- [x] `ripgrep-all` — heavy document stack (ocrmypdf, pandoc, typst, latexmk, zathura, Obsidian vault, bib-audit skill).
- [x] `difftastic` — as `git difftool -t difft`, not a delta replacement; delta is load-bearing for the prose textconv pipeline.
- [x] Bring `elan`/Lean and the `~/.cargo/bin` tools under chezmoi — lean, lake, alt-ergo, why3, isabelle_client, cargo-audit, cargo-fuzz, cargo-llvm-cov, cross, samply are all unmanaged, so a fresh machine loses the formal-methods layer.

## Installed and unused

Counted by typed command name, so a wrapper hides the real tool. `ls` is a function dispatching to eza at `home/dot_zshrc.tmpl:242` (with a tty check so pipes still work), which means all 2,972 `ls` invocations *were* eza — it is the most-used tool in this report, not an unused one.

What stands, with no wrapper in the config: `fd` 7 uses against `find` 180, and `rg` 3 against `grep` 31. Both are worth a wrapper or an alias on the same pattern as `ls`.

`uv` 3 against `pip` 181 is softer — `uv` is not a drop-in for every `pip` use, and much of that count is inside project venvs. `pipx` is redundant with `uv tool` though: aider already installs that way while open-interpreter sits in a pipx venv.

`brew leaves` carries ~130 formulae including `docker-machine` (archived 2021), `openssl@1.1` (EOL September 2023), and both `python@3.10` and `python@3.11`.
