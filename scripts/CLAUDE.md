# Install Scripts

`install.sh` bootstraps the Python runner in `installer/`; every step is a function in `installer/steps/`, and `verify-install.sh` checks the result. `lint-templates.sh` sits here so the `scripts/*.sh` lint glob covers it.

## Python

The installer must run on Python 3.9 (the Xcode Command Line Tools ship 3.9.6) with the standard library alone, so a fresh machine needs nothing installed first. Never export `PYTHONPATH`, which would reach every tool a step runs. mypy checks against 3.10 at the oldest, so test the floor with `make test-py PYTHON=/Library/Developer/CommandLineTools/usr/bin/python3`.

## Steps

Steps are *idempotent*: they skip a tool already present and upgrade only under `--upgrade`. Steps share one environment, `context.env`, so a step that changes `PATH` changes it for every later step. A failing step fails alone unless it has `fatal=True`. `install_homebrew` is the only interactive step; the Command Line Tools install lives in `install.sh` because `/usr/bin/python3` is a stub without them. `install_zsh_completions` runs last, since it invokes each installed binary. Keep `[install]` log lines stable, since tests assert them. A comment that gives a fix its reason moves with the code.

**Prove the binary runs.** Every path that installs or upgrades an executable ends with `tools.require_runs`, since an installer's exit status says nothing about what it left behind: `claude update` once exited 0 and left an npm stub in place of the native binary. The probe makes no network calls, opens no GUI and writes nothing.

**Download through the helper.** Every fetch goes through `fetch.download`, or a verified variant where upstream or GitHub publishes a digest; a comment notes where none exists. `--retry-all-errors` stays off, since it retries a 404 through the whole backoff. Vendor installers run from a downloaded file, never `curl | sh`. Extract with `release.unpack`, which uses `tar -xf`, never `-xzf`.

**Pin versions.** Tags in `pins.sh` are spelled exactly as upstream publishes them, one `NAME_VERSION="value"` line each with no expansion and no trailing comment, since `installer/pins.py` parses the file. `BTOP_VERSION` holds at 1.4.4, since later releases need GNU Compiler Collection (GCC) 14 and jammy ships GCC 11. Obsidian on Linux uses `desktop_version`, since the newest release can be Android-only.

**Pin the system toolchain.** Source builds use `SYSTEM_PATH` and the `/usr/bin` compilers, since the direnv devShell's nix gcc wrapper cannot see `/usr/include`.

**Take cargo tools prebuilt.** Fall back to `cargo install --locked` only where upstream publishes no binary; `--locked` stops eza's `palette` pin breaking. Prefer *musl*, since gnu builds need a newer glibc than Ubuntu 22.04 ships. A copy in `~/.cargo/bin` counts as absent, as `verify-install.sh` searches there first.

**Write exact guards.** Match the version number, never a field, since `btop` and `atuin` pad theirs and tags carry a `v`; a mismatch reinstalls on every `--upgrade`. Guard every artefact a step installs, not only its binary.

**Keep apt non-interactive.** `DEBIAN_FRONTEND=noninteractive` stays set, since a debconf dialog inside a held step is invisible. Call `apt-get`, never `apt`, which lacks a stable command-line interface.

**Sudo.** The askpass helper and keepalive start before `install_homebrew`, whose installer runs `sudo -k` on exit unless sudo is already active. Homebrew resets the sudo timestamp on every invocation, which is why the helper exists. Leave `-A` off a sudo call that must never prompt.

**Optional tools.** `OptionalTools.enabled` asks once and never infers. Test for a terminal by opening `/dev/tty`, since the device node is readable without one.

## Per-tool constraints

- `install_git` runs after the two fatal steps; the git-core personal package archive (PPA) key must match `GIT_CORE_PPA_FINGERPRINT`.
- tmux needs 3.4 for the `hyperlinks` terminal feature; Neovim needs 0.12 for built-in completion.
- `install_login_shell` reads the shell from `getent passwd` or `dscl`, never `$SHELL`, which stays stale until the next login. It skips an account missing from `/etc/passwd`, which chsh cannot change.
- nix settings belong in `home/dot_config/nix/nix.conf`; `enable_nix_flakes` is only a fallback for a machine that has not run `chezmoi apply`. `configure_nix_trusted_user` is required, since the daemon silently ignores restricted settings from untrusted users.
- `install_nix_direnv` downloads `direnvrc` directly, since `nix profile install` took 18 seconds in CI to place that one file. Upstream attaches no file to a release, so `DIRENVRC_SHA256` moves with `NIX_DIRENV_VERSION`. The step sets `NIX_DIRENV_FALLBACK_NIX`, which the nixpkgs build had patched in.
- `install_opam` is optional, since compiling OCaml for the default switch took 396 to 595 seconds on a CI runner.
- `install_gh_stack` and `install_gh_stack_skill` pass without an authenticated gh, which nothing here provides. The skill takes `--scope user`, since the default writes into the current repository. `gh skill` is a preview command and the likeliest to break.
- On Linux ARM64, Obsidian's `chrome-sandbox` must be setuid root, which Electron requires.
- Obsidian config stays out of chezmoi, since Obsidian and obsync rewrite it. The vault clone stays manual, its address exposing an otherwise proxied origin. macOS schedules obsync by LaunchAgent, since its cron lacks Full Disk Access and Homebrew.
- Never install the `font-iosevka-slab` cask: it is a 495 MB collection, and WezTerm took 2 s to find its font in it on every zoom. Take the unhinted Iosevka packages. Libertinus downloads unverified, as no digest exists for it. Fonts come from upstream, never from the site's woff2 files.
- Iosevka Term comes from the release zip, since Homebrew has only its Nerd Font build, under another family name. `MEMBERS` in `steps/terminal_font.py` must include the faces Ghostty's `font-style` keys name.
- Ghostty on Linux is the classic snap, the one source that builds for jammy; Ubuntu packages it from 26.04, and the community debs start there too.
- The zathura tap needs `brew trust` under Homebrew 6, as does `Noah4ever/tap` in the `deps` Make target. `zathurarc` relies on SyncTeX, so `--with-synctex` goes on install and upgrade. `_link_pdf_plugin` runs every time, since zathura scans only `$(brew --prefix zathura)/lib/zathura`. Poppler keeps one renderer on both platforms.
- `install_latex` on Linux installs upstream TeX Live, since apt holds it at the distro's year. It fetches `install-tl` and its SHA-512 from one resolved mirror, since `mirror.ctan.org` otherwise serves the pair from different mirrors. The old year is deleted only after the new one runs.
- `install_doom_emacs` takes Linux's Emacs from the nix profile, since jammy's apt holds 27.1 and Doom needs 29.1. It runs `bin/doom` with `EMACS` set, since an older Emacs can come first on `PATH`. No probe calls `bin/doom`, which writes a log on every run.
- No step registers Model Context Protocol (MCP) servers.

## `verify-install.sh`

Every `check_cmd` needs a probe that exits 0 with no side effects, GUI or network, since a stub on `PATH` passes `command -v`; `--no-probe` needs a comment saying why. Anything the installer may legitimately skip needs a warning check here, or a correctly provisioned machine fails.
