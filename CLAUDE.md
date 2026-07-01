# Chezmoi Dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) for cross-platform (macOS ARM64, Linux x86_64/ARM64) portability.

## Structure

```
chezmoi/
├── home/                    # chezmoi root (see .chezmoiroot)
│   ├── dot_zshrc.tmpl
│   ├── dot_tmux.conf.tmpl
│   ├── dot_gitconfig.tmpl
│   ├── dot_fzf.zsh.tmpl
│   ├── run_onchange_reload_tmux.sh.tmpl
│   ├── dot_claude/          # → ~/.claude/ (Claude Code config)
│   └── dot_config/          # → ~/.config/
│       ├── git/
│       ├── nvim/
│       └── starship.toml
├── scripts/
│   ├── install.sh           # Dispatcher: detects OS/arch, calls platform script
│   ├── install-linux.sh     # Linux (x86_64 + ARM64)
│   ├── install-macos-arm64.sh
│   ├── install-common.sh    # Shared install logic for all platforms
│   └── verify-install.sh
└── Makefile
```

## File Naming

| Chezmoi name | Deployed as |
|---|---|
| `dot_foo` | `.foo` |
| `dot_foo.tmpl` | `.foo` (after template evaluation) |
| `run_onchange_*.sh.tmpl` | run once on change |

All files under `home/` are relative to `~` on the target system.

## Templating

Files with `.tmpl` extension use Go template syntax. The main variable is `.chezmoi`.

**OS branching:**
```
{{ if eq .chezmoi.os "darwin" }}
  # macOS
{{ else if eq .chezmoi.os "linux" }}
  # Linux
{{ end }}
```

**Variables:**
- `.chezmoi.os` — `"darwin"` or `"linux"`
- `.chezmoi.homeDir` — absolute path to home directory

**Change detection (run_onchange scripts):**
```
# tmux-conf-hash: {{ include "dot_tmux.conf.tmpl" | sha256sum }}
```
Including a hash of a dependency in the script header causes chezmoi to re-run it when that file changes.

## Commands

```bash
# Format and lint
make fmt          # Run stylua + shfmt (auto-fix)
make fmt-ci       # Check-only (used in CI)
make lint         # shellcheck + luacheck

# Dev shell (Nix, optional alternative to `make deps`)
nix develop       # drops into a shell with stylua, shfmt, shellcheck, luacheck, etc.

# Apply dotfiles locally
chezmoi apply

# Preview changes before applying
chezmoi diff
```

## CI

GitHub Actions (`.github/workflows/ci.yml`):
1. **changes** — `dorny/paths-filter` detects whether `scripts/install-common.sh`, `scripts/install-linux.sh`, or `scripts/verify-install.sh` changed
2. **lint** — installs Nix (`cachix/install-nix-action`), then runs `make fmt-ci` and `make lint` inside `nix develop`
3. **install** (after lint; skipped unless `changes` detected an install script diff) — runs `scripts/install-linux.sh` then `scripts/verify-install.sh`

## Install Scripts

All scripts are idempotent — each step checks whether the tool is already present and skips if so. Pass `--upgrade` to upgrade already-installed tools to their latest versions instead of skipping them.

### `scripts/install-linux.sh`

Requires: `sudo`, `apt`, `dpkg`, `ssh-keygen`. Supports x86_64 and aarch64 — arch is detected at runtime.

1. `apt install` — `git curl build-essential zsh entr linux-tools-generic` plus tmux build deps
2. tmux built from source
3. Node.js LTS via NodeSource setup script (skipped if `node ≥ 20` present)
4. Neovim — downloads official Linux binary to `/opt/nvim-linux-<arch>/`
5. All common tools (see below)

### `scripts/install-macos-arm64.sh`

Requires: ARM64 macOS, `sudo`, `curl`, `ssh-keygen`.

1. Xcode Command Line Tools (waits for GUI installation to finish)
2. Homebrew
3. `brew install` — `git zsh tmux node entr`
4. Neovim via Homebrew
5. All common tools (see below)

### `scripts/install-common.sh`

Shared functions called by both platform scripts, in order:

| Function | What it installs |
|---|---|
| `install_zinit` | zinit plugin manager to `~/.local/share/zinit/zinit.git` |
| `install_rust` | Rust toolchain via rustup |
| `install_rust_analyzer` | `rust-analyzer` via `rustup component add` |
| `install_clangd` | `clangd` via apt (Linux) or `brew install llvm` (macOS) |
| `install_cmake` | cmake >= 4.3.2 — prebuilt binary from GitHub releases (Linux x86_64/ARM64), or `brew install/upgrade cmake` (macOS) |
| `install_nix` | Nix package manager — official multi-user (`--daemon`) installer from nixos.org; powers `flake.nix` devShells |
| `install_direnv` | `direnv` binary via official install script to `~/.local/bin`; hooked into zsh via `_cache_eval direnv hook zsh` |
| `install_nix_direnv` | `nix-direnv` via `nix profile install`, wired into `~/.config/direnv/direnvrc`, for cached devShell loading; installs `install_modern_bash` first |
| `install_modern_bash` | macOS only — installs bash >= 4.4 via `nix profile install nixpkgs#bash`, since nix-direnv requires it and macOS ships bash 3.2 |
| `install_pyright` | `pyright` via `npm install -g` |
| `install_lua_ls` | `lua-language-server` via `brew` (macOS) or GitHub releases binary (Linux) |
| `install_opam` | `opam` (OCaml package manager) via `brew` (macOS) or GitHub releases binary (Linux) |
| `install_eza` | `eza` via `cargo install` |
| `install_fd` | `fd` via `cargo install fd-find` |
| `install_bat` | `bat` via `cargo install` |
| `install_gh` | GitHub CLI — `brew install gh` (macOS) or official apt repo (Linux) |
| `install_tailscale` | Tailscale — `brew install --cask tailscale` (macOS) or official install script (Linux) |
| `install_mullvad` | Mullvad VPN — `brew install --cask mullvadvpn` (macOS) or official apt repo (Linux) |
| `install_zoxide` | `zoxide` via install script |
| `install_fzf` | fzf cloned to `~/.fzf`, binary-only install |
| `install_claude_code` | Claude Code CLI |
| `install_rtk` | rtk token-optimization proxy |
| `install_uv` | uv Python package manager |
| `install_token_savior` | MCP server — registered via `claude mcp add` using `uvx` |
| `install_token_optimizer_mcp` | MCP server — registered via `claude mcp add` using `npx` |
| `install_ccusage` | `ccusage` CLI (`npm install -g`) + MCP server registration |
| `install_mcp_manim` | MCP server — clones gist, builds Docker image, registers |
| `install_mcp_latex` | MCP server — clones gist, builds Docker image, registers |
| `install_git_mcp` | MCP server — registers `npx mcp-remote` pointing to gitmcp.io |
| `install_starship` | Starship prompt via install script |
| `install_tmux_plugins` | tpm to `~/.tmux/plugins/tpm` |
| `install_wezterm` | WezTerm — `brew install --cask` (macOS), `.deb` from GitHub releases (Linux x86_64); skipped on ARM64 |
| `install_nerd_font` | CodeNewRoman Nerd Font — `brew install --cask font-code-new-roman-nerd-font` (macOS) or GitHub releases zip extracted to `~/.local/share/fonts/` (Linux); skipped on headless Linux |

MCP servers are registered at user scope (`-s user`) and are idempotent (checked via `claude mcp list`). `mcp-manim` and `mcp-latex` require Docker.

### `scripts/verify-install.sh`

Checks that all expected commands and directories exist after installation. Run after an install script to confirm nothing is missing. Exits non-zero if any check fails.

Checks: `git curl zsh tmux entr rustup cargo rust-analyzer clangd cmake nix direnv pyright lua-language-server opam eza fd zoxide fzf claude rtk node npm uv uvx ccusage starship nvim`, plus dirs `~/.local/share/zinit/zinit.git`, `~/.tmux/plugins/tpm`. On non-headless machines, also checks WezTerm and the CodeNewRoman Nerd Font (cask on macOS, `~/.local/share/fonts/CodeNewRomanNerdFont` dir on Linux).

## Key Areas

- **Neovim config** — `home/dot_config/nvim/` — Lua, uses Lazy.nvim; LSP for bash, rust, ocaml, lua
- **Claude Code config** — `home/dot_claude/` — settings, MCP docs (RTK.md, TOKEN_TOOLS.md)
- **Shell** — `home/dot_zshrc.tmpl` — zinit, zoxide, fzf, starship, auto-attach tmux
- **Tmux** — `home/dot_tmux.conf.tmpl` — prefix C-a, Hacktober theme (matches WezTerm), OS-specific clipboard
- **Git** — `home/dot_gitconfig.tmpl` and `home/dot_config/git/` — SSH signing, aliases
