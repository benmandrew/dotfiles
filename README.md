## Bootstrap

A new machine takes two commands. The install script below puts chezmoi and every other tool in place, and then chezmoi clones this repository into `~/.local/share/chezmoi` and applies it.

```bash
$ ./scripts/install.sh
$ chezmoi init --apply git@github.com:benmandrew/dotfiles.git
```

The GNOME scripts need a desktop session to write to. Applied over Secure Shell (SSH) to a desktop nobody is logged in to, they fail on purpose, and the next `chezmoi apply` from the desktop runs them.

A few steps hold secrets or accounts, so chezmoi leaves them to be done by hand. Shell history syncs through *atuin*, which needs an account and then the history already on the machine:

```bash
$ atuin register    # or `atuin login` on every machine after the first
$ atuin import auto
```

The encryption key lands in `~/.local/share/atuin/key`, which chezmoi does not manage. Back it up in a password manager, since history synced under a lost key cannot be read back.

The work Claude Code profile in `~/.claude-work` shares agents, commands and skills with `~/.claude` through symlinks, but it keeps its own plugins. Install them once per machine:

```bash
$ CLAUDE_CONFIG_DIR=~/.claude-work claude plugin marketplace add isaaccorley/skills
$ CLAUDE_CONFIG_DIR=~/.claude-work claude plugin install bib-audit@isaaccorley-skills --scope user
$ CLAUDE_CONFIG_DIR=~/.claude-work claude plugin install clangd-lsp@claude-plugins-official --scope user
$ CLAUDE_CONFIG_DIR=~/.claude-work claude plugin install pyright-lsp@claude-plugins-official --scope user
$ CLAUDE_CONFIG_DIR=~/.claude-work claude plugin install lua-lsp@claude-plugins-official --scope user
```

The default profile gets the same plugins from `run_onchange_install-claude-plugins.sh` on every apply. The work profile has no such script yet.

## Dependencies

The install script bootstraps all required tools for a given platform. It auto-detects the OS and architecture and delegates to the appropriate platform script.

```bash
$ ./scripts/install.sh
```

### Optional tools

Most tools are installed on every machine. A few only make sense where you actually sit in front of the machine, rather than ssh into it — currently the Obsidian desktop app, which is what provides the `obsidian` CLI, and alongside it obsync and the 15-minute vault sync it schedules. Those are prompted for on first install, and the answer is remembered in `~/.config/dotfiles/optional-tools.conf` so later runs stay non-interactive.

```bash
$ ./scripts/install.sh --all-optional          # take everything, no prompts
$ ./scripts/install.sh --no-optional           # take nothing, no prompts
$ ./scripts/install.sh --reconfigure-optional  # ask again
```

Without a terminal to prompt on, optional tools are skipped and no answer is recorded, so an unattended run never silently opts a machine out for good.

### Supported platforms

These are the platforms with a tested install script. Running `install.sh` on anything else will exit with an error.

| OS | Architecture | Distro |
|---|---|---|
| macOS | ARM64 | — |
| Linux | x86\_64 | Ubuntu |
| Linux | ARM64 | Debian |


## Dev dependencies

```bash
$ make deps
```

Alternatively, if you have [Nix](https://nixos.org) installed (`scripts/install-common.sh` installs it and enables flakes via `install_nix`), `flake.nix` provides a devShell with all formatters and linters used by `make fmt`/`make lint`:

```bash
$ nix develop
```

`chezmoi apply` deploys `~/.config/nix/nix.conf` (enabling flakes and setting `min-free`/`max-free` so the store auto-collects garbage instead of growing unbounded). If you installed Nix some other way and haven't run `chezmoi apply`, add at least this once:

```
experimental-features = nix-command flakes
```

[direnv](https://direnv.net) is installed by the same install script (`install_direnv`) and hooked into zsh, so the devShell loads automatically on `cd` via the checked-in `.envrc` — just run `direnv allow` once per machine. [nix-direnv](https://github.com/nix-community/nix-direnv) is also installed (`install_nix_direnv`) to cache the devShell so re-entering a directory is fast instead of re-evaluating the flake each time. On macOS this also installs a modern `bash` via Nix, since nix-direnv requires bash >= 4.4 and macOS ships 3.2.
