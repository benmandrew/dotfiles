# Install Scripts

How `scripts/` is organised. Loaded when working with files under this directory.

All scripts are idempotent — each step checks whether the tool is already present and skips if so. Pass `--upgrade` to upgrade already-installed tools to their latest versions instead of skipping them.

## Sudo

Both platform scripts call `start_sudo_keepalive` (in `install-common.sh`) as their first privileged action, so the password is asked for exactly once. A full install — especially `--upgrade`, which rebuilds tmux and re-fetches every toolchain — runs far longer than sudo's credential cache (15 min by default), so without this the later steps each re-prompt. It authenticates with `sudo -v`, then backgrounds a loop refreshing the timestamp with `sudo -n true` every 50s, torn down by an `EXIT` trap. The loop is additionally bounded by `kill -0 $$` so no refresher survives a `SIGKILL`ed install, and breaks rather than blocking if `sudo -n` fails (`timestamp_timeout=0`), degrading to per-step prompts. Skipped entirely when already root.

Uses no bash 4+ features, so it is safe under the bash 3.2 macOS ships. Ordering matters on macOS: the Homebrew installer arms a `trap '/usr/bin/sudo -k' EXIT` that would wipe the cached timestamp, but only when guarded by `! sudo -n -v` — i.e. only if sudo was not already active — so `start_sudo_keepalive` must run before `install_homebrew`. It cannot suppress GUI escalation, which is a separate mechanism from sudo's timestamp: the `xcode-select --install` dialog and any cask using Authorization Services or a system-extension approval still prompt.

## `scripts/install-linux.sh`

Requires: `sudo`, `apt`, `dpkg`, `ssh-keygen`. Supports x86_64 and aarch64 — arch is detected at runtime.

1. `apt install` — `git curl build-essential zsh entr` plus tmux build deps
2. `perf` (`linux-tools-generic`) — best-effort; skipped with a warning (not a failure) if the exact-version kernel-tools package isn't available, which is common on cloud/CI kernels
3. `install_inotify_limits` — writes a sysctl drop-in (`/etc/sysctl.d/60-inotify-watches.conf`) raising `fs.inotify.max_user_watches`/`max_user_instances`, so VS Code's file watcher doesn't hit "Unable to watch for file changes" on large workspaces
4. tmux built from source
5. Node.js LTS via NodeSource setup script (skipped if `node ≥ 20` present)
6. Neovim — downloads official Linux binary to `/opt/nvim-linux-<arch>/`
7. All common tools (see below)

## `scripts/install-macos-arm64.sh`

Requires: ARM64 macOS, `sudo`, `curl`, `ssh-keygen`.

1. Xcode Command Line Tools (waits for GUI installation to finish)
2. Homebrew
3. `brew install` — `git zsh tmux node entr`
4. Neovim via Homebrew
5. All common tools (see below)

## `scripts/install-common.sh`

Shared functions called by both platform scripts, in order:

| Function | What it installs |
|---|---|
| `install_zinit` | zinit plugin manager to `~/.local/share/zinit/zinit.git` |
| `install_rust` | Rust toolchain via rustup |
| `install_rust_analyzer` | `rust-analyzer` via `rustup component add` |
| `install_clangd` | `clangd` via apt (Linux) or `brew install llvm` (macOS) |
| `install_cmake` | cmake >= 4.3.2 — prebuilt binary from GitHub releases (Linux x86_64/ARM64), or `brew install/upgrade cmake` (macOS) |
| `install_nix` | Nix package manager — official multi-user (`--daemon`) installer from nixos.org; powers `flake.nix` devShells. `enable_nix_flakes` appends the flakes line as an immediate-post-install fallback; `home/dot_config/nix/nix.conf` (flakes + `min-free`/`max-free` auto-GC) is the source of truth once `chezmoi apply` has run. `configure_nix_trusted_user` adds the installing user to `trusted-users` in `/etc/nix/nix.conf` (via `sudo`, restarting the daemon) since the multi-user daemon otherwise silently ignores those restricted settings from untrusted users |
| `install_direnv` | `direnv` binary via official install script to `~/.local/bin`; hooked into zsh via `_cache_eval direnv hook zsh` |
| `install_nix_direnv` | `nix-direnv` via `nix profile install`, wired into `~/.config/direnv/direnvrc`, for cached devShell loading; installs `install_modern_bash` first |
| `install_modern_bash` | macOS only — installs bash >= 4.4 via `nix profile install nixpkgs#bash`, since nix-direnv requires it and macOS ships bash 3.2 |
| `install_pyright` | `pyright` via `npm install -g` |
| `install_lua_ls` | `lua-language-server` via `brew` (macOS) or GitHub releases binary (Linux) |
| `install_opam` | `opam` (OCaml package manager) via `brew` (macOS) or GitHub releases binary (Linux) |
| `install_go` | Go toolchain — downloads latest stable from `go.dev/dl`; upgrades system Go if < 1.21 (needed for `GOTOOLCHAIN=auto`); Linux only (macOS uses brew as needed) |
| `install_moor` | `moor` pager (formerly `moar`) — `brew install moor` (macOS); Linux x86_64: official release binary from GitHub; Linux arm64: `GOTOOLCHAIN=auto go install` (no official arm64 binary) |
| `install_glow` | `glow` markdown renderer — `brew install glow` (macOS) or official release tarball from GitHub extracted to `~/.local/bin` (Linux x86_64/arm64) |
| `install_treehouse` | `treehouse` git-worktree pool manager — official release tarball from GitHub extracted to `~/.local/bin` (all platforms: darwin/linux x amd64/arm64; no brew formula) |
| `install_eza` | `eza` via `cargo install` |
| `install_fd` | `fd` via `cargo install fd-find` |
| `install_bat` | `bat` via `cargo install` |
| `install_btop` | `btop` resource monitor (modern `top`/`htop` alternative) — `brew install btop` (macOS) or apt (Linux) |
| `install_ripgrep` | `rg` via `cargo install ripgrep` |
| `install_git_delta` | `delta` via `cargo install git-delta` |
| `install_jq` | `jq` — `brew install jq` (macOS) or apt (Linux) |
| `install_zstd` | Zstandard CLI + headers — `brew install zstd` (macOS) or apt `zstd libzstd-dev` (Linux). The Linux guard checks `dpkg -s libzstd-dev` as well as `command -v zstd`, since Ubuntu images often ship the CLI alone and a `command -v` check would skip the headers forever |
| `install_hyperfine` | `hyperfine` via `cargo install` |
| `install_gh` | GitHub CLI — `brew install gh` (macOS) or official apt repo (Linux) |
| `install_tailscale` | Tailscale — `brew install --cask tailscale` (macOS) or official install script (Linux) |
| `install_zoxide` | `zoxide` via install script |
| `install_fzf` | fzf cloned to `~/.fzf`, binary-only install |
| `install_claude_code` | Claude Code CLI |
| `install_rtk` | rtk token-optimization proxy |
| `install_uv` | uv Python package manager |
| `install_ccusage` | `ccusage` CLI via `npm install -g` (no MCP registration) |
| `install_starship` | Starship prompt via install script |
| `install_tmux_plugins` | tpm to `~/.tmux/plugins/tpm` |
| `install_wezterm` | WezTerm — `brew install --cask` (macOS), `.deb` from GitHub releases (Linux x86_64); skipped on ARM64 |
| `install_nerd_font` | CodeNewRoman Nerd Font — `brew install --cask font-code-new-roman-nerd-font` (macOS) or GitHub releases zip extracted to `~/.local/share/fonts/` (Linux); skipped on headless Linux |

No install step registers MCP servers — that is left to `claude mcp add` by hand.

Release archives are extracted with `tar -xf`, never `-xzf`: tar picks the decompressor from the archive's magic bytes, so an upstream that switches from `.tar.gz` to `.tar.zst` needs no script change. GNU tar shells out to the `zstd` binary to do it, which `install_zstd` guarantees is present.

## `scripts/verify-install.sh`

Checks that all expected commands and directories exist after installation. Run after an install script to confirm nothing is missing. Exits non-zero if any check fails.

Checks: `git curl zsh tmux entr rustup cargo rust-analyzer clangd cmake nix direnv pyright lua-language-server opam moor glow treehouse eza fd bat btop rg jq zstd delta hyperfine zoxide fzf claude rtk node npm uv uvx ccusage starship nvim`, plus dirs `~/.local/share/zinit/zinit.git`, `~/.tmux/plugins/tpm`. On non-headless machines, also checks WezTerm and the CodeNewRoman Nerd Font (cask on macOS, `~/.local/share/fonts/CodeNewRomanNerdFont` dir on Linux).

