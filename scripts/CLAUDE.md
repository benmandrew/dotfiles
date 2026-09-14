# Install Scripts

`install.sh` runs `install-linux.sh` (x86_64 and aarch64) or `install-macos-arm64.sh`, which call steps from `install-common.sh`; `verify-install.sh` checks the result. `lint-templates.sh` backs `make lint-templates` and sits here so the `scripts/*.sh` lint glob covers it.

## Running steps

Steps are *idempotent*, skipping a tool already present; `--upgrade` upgrades it instead, and `--verbose` streams output live. The scripts avoid bash 4 features, since macOS runs them under bash 3.2.

`run_step install_foo` calls `quiet`, which holds the step's stdout and stderr in a log and prints its tail and path on failure; `check_failed` lists every failed step at the end and exits 1. Both streams are held because installers draw progress on stderr. `log` and `err` write to file descriptor 3, duplicated from stderr before any redirect. `quiet` also closes stdin and restores the terminal's line settings, since a step that dies in raw mode breaks the shell.

Linux calls `install_apt_packages_if_missing` and `install_perf` through bare `quiet`, so their failure aborts under errexit. Prompting steps cannot use `quiet`, so `install_xcode_clt` and `install_homebrew` are called directly. `install_zsh_completions` runs last, since it invokes each installed binary.

## Writing a step

**Return failures.** errexit is off inside a step, because `quiet` runs it left of `||`, so a step reports its last command's status. Every command whose failure should fail the step needs `|| return 1` unless it is last, `safe_git` fetches on `--upgrade` paths included.

**Prove the binary runs.** An installer's exit status says nothing about what it left behind: `claude update` once exited 0 over an npm install, leaving the package's stub in place of the native binary. So every path that installs or upgrades an executable ends with `require_runs <cmd> [probe]`, by absolute path where the step knows it, and the probe prints and exits with no network, GUI or writes. Vendor self-updaters, which fetch outside `download()`, run under `retry_once`. A fixed-path install calls `note_shadowed`, which names a copy earlier on `PATH` without deleting it.

**Download through the helper.** Every fetch uses `download <url> <dest>`, or `download_verified <url> <dest> <manifest_url>` where upstream publishes a SHA-256 manifest (a comment notes where none exists), and every call site ends `|| return 1`. `download` sets `-f --proto '=https' --tlsv1.2`, and it and `github_api_curl` apply `_CURL_RETRY_OPTS`; `--retry-all-errors` stays off, since it retries a 404 through the whole backoff. Vendor installers run from a downloaded file, never `curl | sh`. Extract with `tar -xf`, never `-xzf`, so a `.tar.zst` needs no change.

**Pin versions.** Tags live in the `*_VERSION` block of `install-common.sh`, spelled exactly as upstream publishes them, and resolve through `pinned_tag <pin> <repo>`, which returns the newest tag under `--upgrade`. `make pins` shows which pins to bump by hand. `BTOP_VERSION` holds at 1.4.4, since later releases need GNU Compiler Collection (GCC) 14 and jammy ships GCC 11. WezTerm has no pin, upstream tagging no releases, and Obsidian on Linux uses `obsidian_desktop_version`, since the newest release can be Android-only.

**Pin the system toolchain.** `install_btop` and `install_tmux_from_source` build through `env PATH=/usr/local/bin:/usr/bin:/bin` with `CXX=/usr/bin/g++` and `CC=/usr/bin/gcc` respectively, because direnv's flake devShell puts a nix gcc wrapper first that cannot see `/usr/include`.

**Take cargo tools prebuilt.** `install_cargo_tool` fetches release binaries into `~/.local/bin` using the asset names and *target triples* in `_rust_tool_spec`, falling back to `cargo install --locked` only where upstream publishes nothing; `--locked` stops eza's `palette` pin breaking. *musl* beats gnu wherever both exist, as in `install_atuin`, since gnu builds need a newer glibc than Ubuntu 22.04 ships. A copy in `~/.cargo/bin` counts as absent and is deleted, as `verify-install.sh` searches there first.

**Write exact guards.** Match the version number rather than a field, since `btop` and `atuin` pad theirs and tags carry a `v`; a mismatch reinstalls on every `--upgrade`, and a failing `--version` counts as absent. Guard every artefact, as `install_zstd` tests `dpkg -s libzstd-dev` beside `command -v zstd`.

**Keep apt non-interactive.** `install-linux.sh` exports `DEBIAN_FRONTEND=noninteractive`, since a debconf dialog inside `quiet` is invisible, and calls `apt-get`, never `apt`, which lacks a stable command-line interface (CLI).

**Sudo.** Both platform scripts call `start_sudo_askpass` then `start_sudo_keepalive` first; on macOS they must precede `install_homebrew`, whose installer runs `sudo -k` on exit unless sudo is already active. Homebrew resets the sudo timestamp on every invocation, so the *askpass helper* reads the password once and exports `SUDO_ASKPASS`, which brew honours. The `sudo` function adds `-A`; use `command sudo` where `-A` is wrong, as in the keepalive's `sudo -n true`, whose failures are ignored. `DOTFILES_NO_ASKPASS=1` disables the helper, and `HOMEBREW_NO_ASK=1` stops `brew upgrade` asking.

## Optional tools

Tools only useful on a machine someone sits at go through `run_optional_step <key> <description> <install_fn>` in both platform scripts. `optional_enabled` asks once, never infers, and records `name=yes|no` in `~/.config/dotfiles/optional-tools.conf` (respecting `XDG_CONFIG_HOME`). `--all-optional` and `--no-optional` decide without touching the file; `--reconfigure-optional` re-asks. The prompt reads `/dev/tty` and defaults to no; with no terminal the tool is skipped unrecorded. Test the terminal with `{ : </dev/tty; }`, since `[[ -r /dev/tty ]]` passes without one.

## Per-tool constraints

- `install_git` runs first on Linux, fitting the git-core personal package archive (PPA) build on Ubuntu below `GIT_MIN_VERSION`; its key must match `GIT_CORE_PPA_FINGERPRINT`.
- `install_perf` warns rather than fails without an exact-version kernel-tools package.
- `enable_nix_flakes` is only a fallback for a machine that has not run `chezmoi apply`; `home/dot_config/nix/nix.conf` is where nix settings belong.
- `configure_nix_trusted_user` adds the user to `trusted-users`, since the daemon silently ignores restricted settings from anyone else.
- `install_btop` purges packaged btop, which shadows `~/.local/bin`.
- `install_gh_stack` and `install_gh_stack_skill` need an authenticated gh, which nothing here provides; if `gh_authenticated` fails they warn and return 0. The skill takes `--scope user`, since the default writes into the current repository. `gh skill` is a preview command and the likeliest to break.
- `install_obsidian` installs the app, since the Obsidian CLI ships inside it and registers only by a settings toggle (`print_obsidian_cli_hint`). Linux ARM64 links the launcher as `~/.local/bin/obsidian-app`, leaving `obsidian` to the CLI, and makes `chrome-sandbox` setuid root, which Electron requires.
- Obsidian config lives in the vault's own `.obsidian/`; nothing there or in `~/.config/obsidian/` goes into chezmoi, since Obsidian and obsync rewrite it. The vault clone stays manual, its address exposing an otherwise proxied origin, so `ensure_obsidian_vault` only checks for `~/projects/obsidian-vault` with the `personal` remote `obsync.sh` hardcodes. macOS schedules by LaunchAgent, its cron lacking Full Disk Access and Homebrew; `schedule_obsync_launchd` calls `remove_obsync_cron` only after `launchctl bootstrap` succeeds, and `obsync_cron_stripped` keeps a machine to one schedule.
- zathura on macOS comes from the `homebrew-zathura/zathura` tap, which Homebrew 6 refuses per formula until trusted, so `install_zathura` checks `brew trust --json v1`; `Noah4ever/tap` in the `deps` Make target needs the same. `--with-synctex` goes on install and upgrade, since `zathurarc` relies on SyncTeX. `zathura-pdf-poppler` has its own guard, and `link_zathura_pdf_plugin` runs every time, zathura scanning only `$(brew --prefix zathura)/lib/zathura`. Poppler is chosen over the recommended mupdf so both platforms share one renderer.
- No step registers Model Context Protocol (MCP) servers.

## `scripts/verify-install.sh`

`check_cmd`, `check_dir` and `check_file` fail the run. `check_cmd <name> [probe]` also runs the command from `/`, with `--version` by default, since a stub on `PATH` passes `command -v`; a new call needs a probe that exits 0 with no side effects, GUI or network, and `--no-probe` takes a comment saying why. `check_cmd_optional` warns, for `perf`, `obsidian` and `zathura`, as does `check_optional`, a label plus command for the gh-stack extension and skill. `check_bash_version` requires bash 4.4 from a login shell via `env -i ... zsh -lc`, as direnv sees it. Plugins come from every `set -g @plugin` line in `~/.tmux.conf`, and `wezterm` and the Nerd Font are skipped on headless Linux.

Anything the installer may legitimately skip needs a warning check here, or a correctly provisioned machine fails.
