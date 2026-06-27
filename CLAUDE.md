# Chezmoi Dotfiles

Personal dotfiles managed with [chezmoi](https://chezmoi.io) for cross-platform (macOS ARM64, Ubuntu, Debian ARM64) portability.

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
│   ├── install-ubuntu-x86_64.sh
│   ├── install-macos-arm64.sh
│   ├── install-debian-arm64.sh
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

# Apply dotfiles locally
chezmoi apply

# Preview changes before applying
chezmoi diff
```

## CI

GitHub Actions (`.github/workflows/ci.yml`):
1. **lint** — runs `make fmt-ci` then `make lint`
2. **install** (after lint) — runs `scripts/install-ubuntu-x86_64.sh` then `scripts/verify-install.sh`

## Install Scripts

All scripts are idempotent — each step checks whether the tool is already present and skips if so. Pass `--upgrade` to upgrade already-installed tools to their latest versions instead of skipping them.

### `scripts/install-ubuntu-x86_64.sh`

Requires: `sudo`, `apt`, `dpkg`, `ssh-keygen`.

1. `apt install` — `git curl build-essential zsh tmux entr`
2. Node.js LTS via NodeSource setup script (skipped if `node ≥ 20` present)
3. Neovim — downloads official Linux x86_64 binary to `/opt/nvim-linux-x86_64/`
4. All common tools (see below)

### `scripts/install-debian-arm64.sh`

Requires: `sudo`, `apt`, `dpkg`, `ssh-keygen`.

1. `apt install` — `git curl build-essential zsh tmux entr`
2. Node.js LTS via NodeSource setup script (skipped if `node ≥ 20` present)
3. Neovim — downloads official Linux ARM64 binary to `/opt/nvim-linux-arm64/`
4. All common tools (see below)

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
| `install_pyright` | `pyright` via `npm install -g` |
| `install_lua_ls` | `lua-language-server` via `brew` (macOS) or GitHub releases binary (Linux) |
| `install_eza` | `eza` via `cargo install` |
| `install_fd` | `fd` via `cargo install fd-find` |
| `install_bat` | `bat` via `cargo install` |
| `install_gh` | GitHub CLI — `brew install gh` (macOS) or official apt repo (Linux) |
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
| `install_tmux_plugins` | tpm to `~/.tmux/plugins/tpm`; catppuccin theme to `~/.config/tmux/plugins/catppuccin` |
| `install_wezterm` | WezTerm — `brew install --cask` (macOS), `.deb` from GitHub releases (Linux x86_64); skipped on ARM64 |

MCP servers are registered at user scope (`-s user`) and are idempotent (checked via `claude mcp list`). `mcp-manim` and `mcp-latex` require Docker.

### `scripts/verify-install.sh`

Checks that all expected commands and directories exist after installation. Run after an install script to confirm nothing is missing. Exits non-zero if any check fails.

Checks: `git curl zsh tmux entr rustup cargo rust-analyzer clangd cmake pyright eza fd zoxide fzf claude rtk node npm uv uvx ccusage starship nvim`, plus dirs `~/.local/share/zinit/zinit.git`, `~/.tmux/plugins/tpm`, `~/.config/tmux/plugins/catppuccin`.

## Key Areas

- **Neovim config** — `home/dot_config/nvim/` — Lua, uses Lazy.nvim; LSP for bash, rust, ocaml, lua
- **Claude Code config** — `home/dot_claude/` — settings, MCP docs (RTK.md, TOKEN_TOOLS.md)
- **Shell** — `home/dot_zshrc.tmpl` — zinit, zoxide, fzf, starship, auto-attach tmux
- **Tmux** — `home/dot_tmux.conf.tmpl` — prefix C-a, catppuccin-mocha theme, OS-specific clipboard
- **Git** — `home/dot_gitconfig.tmpl` and `home/dot_config/git/` — SSH signing, aliases
