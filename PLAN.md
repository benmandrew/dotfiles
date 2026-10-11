# Port the installer from bash to Python

`scripts/install-common.sh` holds 4,385 lines and 143 functions, and 236 of those lines end in `|| return 1`. The port leaves `scripts/install.sh` as a small bash *bootstrap* and moves everything else into Python. It runs in stages, and no stage starts until the one before it has passed the gate below.

## Decisions

**Interpreter.** The bootstrap runs `/usr/bin/python3` where it exists and `python3` from `PATH` otherwise. The floor is Python 3.9, since the Xcode Command Line Tools (CLT) ship 3.9.6 and Ubuntu 22.04 ships 3.10. The code uses the standard library alone, so a fresh machine needs no package installed before the installer can run.

**No `PYTHONPATH`.** `scripts/install.py` puts its own directory on `sys.path`. An exported `PYTHONPATH` would reach every tool a step runs, uv and ansible-lint among them.

**Fetching stays with curl.** Python calls `curl` with the flags `download()` uses today. `urllib` has no retry with backoff, and the certificate store behind the CLT Python is not one this repository controls.

**Bash steps run one process each during the port.** `scripts/installer/legacy.py` runs a step that is still bash through `scripts/legacy-step.sh`, which sources the step library, calls one function and writes its final environment to a file. The runner adopts that environment, so a step that changes `PATH` (`install_homebrew`, `install_nix`, `install_uv`, `install_go`, `load_cargo_env`) still reaches the steps after it. The working directory and unexported shell variables do not carry over; no step depends on either.

**Bash steps run under `/bin/bash`.** That is bash 3.2 on macOS and 5.1 on Ubuntu 22.04. The old entry point used whichever `bash` came first on `PATH`.

**A pinned version has one home.** Every `*_VERSION` constant is in `scripts/pins.sh`, which the bash steps source and `scripts/installer/pins.py` parses. Each line is a plain `NAME_VERSION="value"`, so the two languages cannot read different values. The table that gives each pin its repository is Python alone, since only `make pins` and the Python steps read it.

**A ported step keeps its name and its log lines.** `plan.py` lists steps by name and takes the Python one where it exists. The step prints what its bash function printed, so the gate can compare two runs line by line.

**`verify-install.sh` and `lint-templates.sh` stay bash.** They are 365 and 160 lines, and neither shares code with the installer.

## Behaviour changes

Each of these is deliberate. Anything else that differs from the bash installer is a bug in the port.

- A `require_cmd` that fails inside a step fails that step. It used to end the whole run with "The run stopped inside a step".
- A step that dies under `set -u` or calls `exit` is reported as a failed step, with its log, and the run carries on.
- The CLT install moves into the bootstrap, ahead of the sudo password prompt, because Python needs the tools. The sudo timestamp no longer ages while the install dialog is open.
- `install-linux.sh` and `install-macos-arm64.sh` are step libraries. Run directly, each hands over to `install.sh`.
- `--help` works, and an unknown argument exits 2 with a usage line (argparse), where bash exited 1.
- `install_cargo_extras` tries all five tools when one needs a `cargo` that is missing. In bash the `require_cmd` ended the step at the first such tool.
- A tool counts as present only where its file on `PATH` is executable. Bash's `command -v` also answered for a file without the execute bit, where no executable copy came after it.
- `install_fzf` fails as soon as its `git clone` fails. Bash went on to run the install script the clone had not delivered, and failed there.
- `install_nix` fails when it cannot write `trusted-users` to `/etc/nix/nix.conf`. Bash logged the line and went on, leaving a Nix that asks before it uses a flake's cache.
- On SIGTERM the runner ends the bash step it is waiting on and dies of the signal at once. Bash held the signal until the step's current command had finished. A command the step started may still be running after the runner has gone.
- `install_obsidian` reads the cask version from Homebrew's JSON in Python. Without `jq`, bash read no version and never adopted an Obsidian.app already in `/Applications`.
- The Obsidian version lookup fails with "no latestVersion in desktop-releases.json" unless the listing spells the key `"latestVersion": "..."`. Given another spelling, bash took `{` for the version and failed at the download.
- `install_zathura` reads the tap's trust state from Homebrew's JSON in Python. Without `jq`, bash trusted the tap again on every run.
- `install_latex` checks the installer's SHA-512 with `hashlib`, where bash called `sha512sum`, and unpacks it in the step's scratch directory, which is removed when the step ends.

## The gate

A stage passes when all four hold. Record the result in the log at the bottom.

1. `nix develop --command make fmt-ci lint test-py` passes, and `make test-py PYTHON=/Library/Developer/CommandLineTools/usr/bin/python3` passes on macOS, which runs the tests on 3.9.6.
2. `make test-container` passes: a fresh Ubuntu 22.04 container runs `install.sh --no-optional` and then `verify-install.sh`. Compare the failed steps and the verify output with the same run on the previous stage's commit. The two lists must match.
3. On a provisioned Mac, `./scripts/install.sh` from a terminal exits 0 with every step skipping, and `./scripts/verify-install.sh` reports what it reported before. This needs the sudo password, so an agent session cannot run it. The session can run the same steps with `SudoSession.start_keepalive` replaced by a function that does nothing, and compare the output with the previous commit run the same way.
4. The `install` job in continuous integration (CI) passes on the pull request. It runs Linux x86_64, and the weekly schedule runs it cold.

## Stages

### Stage 1: runner and bootstrap

Python takes over everything around the steps. Every step stays bash.

- [x] `scripts/installer/`: `cli.py` (arguments), `console.py` (`log`, `err`), `runner.py` (`quiet`, `run_step`, `check_failed`, terminal restore, step logs, signals), `sudo.py` (askpass helper, keepalive), `optional.py` (optional tools), `legacy.py` (bash steps), `plan.py` (the two step lists).
- [x] `scripts/install.sh` becomes the bootstrap: platform check, CLT on macOS, `python3` through apt on Linux, then `exec`.
- [x] `scripts/legacy-step.sh` added. The runner functions, the traps and both `main` functions are deleted from bash.
- [x] Tooling: `ruff` and `mypy` in the flake, `lint-py`, `test-py` and `test-container` in the Makefile, Python arms in the pre-commit hook, CI path filters and cache key.
- [x] `scripts/CLAUDE.md` and the root `CLAUDE.md` describe the new layout.
- [ ] Gate: items 1, 2 and 4 pass, and item 3 without sudo. Item 3 from a terminal is owed. See the log.

### Stage 2: shared helpers and the first release-binary steps

The functions every step calls move to Python with unit tests, and seven steps move with them. Helpers alone would have deleted nothing from bash and left no step to prove them on, so this stage takes batch A from stage 3. The bash copy of a helper stays until the last bash step that calls it has gone.

- [x] `fetch.py`: `download`, `sha256_file`, `verify_sha256`, `download_verified`.
- [x] `github.py`: `api_token`, `failure_reason`, `latest_tag`, `asset_sha256`, `download_verified`, with the standard `json` module in place of `grep` and `awk`.
- [x] `pins.py` and `scripts/pins.sh`: the pins as a data file, `pinned_tag`, and the report behind `make pins`. `print_pin_updates` is deleted from bash, and the pin hashes in `ci.yml` read `pins.sh`.
- [x] `tools.py`: `require_runs`, `note_shadowed`, `version_gte`, `sudo`, `install_binary`. `brew.py`: `formula`.
- [x] The step context: `run()` raising on a non-zero exit, `capture()`, `succeeds()`, a temporary directory per step, and a `Host` a test can set.
- [x] `release.py`: download a release asset, unpack it, find a binary by name.
- [x] Batch A: `install_gitleaks`, `install_glow` and `install_ripgrep_all` from one table, and `install_moor`, `install_treehouse`, `install_lua_ls` and `install_cmake` as functions. Their bash functions are deleted.
- [x] Gate: items 1, 2 and 4 pass, and item 3 without sudo. See the log.

### Stage 3: the remaining release-binary steps

Port in batches, deleting each bash function as its batch passes the gate. `retry_once`, `cpu_count`, `safe_git`, `ensure_user_owns` and `npm_install_g` move with the first step that calls them.

- [x] Batch B, the cargo tools, in `steps/cargo_tools.py`: one table for 17 tools, with `install_eza`, `install_fd`, `install_bat`, `install_ripgrep`, `install_git_delta`, `install_hyperfine`, `install_zoxide`, `install_sccache`, `install_difftastic`, `install_cargo_nextest`, `install_typst`, `install_git_absorb` and `install_cargo_extras` built on it. Gate: items 1, 2 and 4 pass, and item 3 without sudo. See the log.
- [ ] Batch C: `install_atuin`, `install_elan`, `install_nerd_font`, `install_neovim_if_missing` and `install_go`, one module each in `installer/steps/`. Their bash functions are deleted. Gate: items 1, 2 and 4 pass, and item 3 without sudo. See the log.
- [x] Gate after each batch.

### Stage 4: package-manager and clone steps

- [x] Homebrew and apt helpers: `install_brew_formulae_if_missing`, `install_apt_packages_if_missing`, and the steps that only call a package manager (`install_jq`, `install_zstd`, `install_gh`, `install_clangd`, `install_node`).
- [x] npm globals: `install_pyright`, `install_bash_ls`, `install_ccusage`.
- [x] Git clones: `install_zinit`, `install_fzf`, `install_fzf_tab`, `install_fzf_git`, `install_zsh_autosuggestions`, `install_tmux_plugins`.
- [x] Vendor installers run from disk: `install_rust`, `install_rust_analyzer`, `install_uv`, `install_starship`, `install_direnv`, `install_nix_direnv`, `install_claude_code`, `install_rtk`, `install_tailscale`, `install_ansible_lint`.
- [x] Gate: items 1, 2 and 4 pass, and item 3 without sudo. See the log.

### Stage 5: one-off steps

One step per change, each with its own gate, because each holds fixes that no other step shares.

- [x] `install_nix`, `enable_nix_flakes`, `configure_nix_trusted_user`, `source_nix_profile`.
- [x] `install_homebrew`, `install_login_shell`, `install_git`, `install_perf`, `install_inotify_limits`, `install_vscode_unattended_upgrades`.
- [x] `install_tmux_from_source`, `install_btop`.
- [x] `install_opam`, `install_ocaml_tools`. The opam cache key in `ci.yml` reads these function bodies with `sed` and must move with them.
- [x] `install_wezterm`, `set_default_terminal_wezterm`.
- [x] `install_gh_stack`, `install_gh_stack_skill`.
- [x] `install_obsidian`, `install_obsync` and the cron and launchd schedulers.
- [x] `install_zathura`, `install_latex`, `install_docker`.
- [ ] `install_zsh_completions`.

### Stage 6: remove the bash

- [ ] Delete `install-common.sh`, `install-linux.sh`, `install-macos-arm64.sh`, `legacy-step.sh` and `installer/legacy.py`.
- [ ] Rewrite `scripts/CLAUDE.md` around the Python step rules, and drop the `|| return 1` rule.
- [ ] Update the `ci.yml` path filter and cache keys, `_typos.toml` comments and the `Makefile` globs.
- [ ] Gate, with a cold CI run.

## Log

### Stage 1, 10 October 2026

`install-common.sh` went from 4,385 lines to 3,989. The Python runner is 1,145 lines in nine files, with 626 lines of tests.

- **Gate 1: passed.** `nix develop --command make fmt-ci lint test-py` passes, with 56 tests. `make test-py PYTHON=/Library/Developer/CommandLineTools/usr/bin/python3` passes on Python 3.9.6.
- **Gate 2: passed.** Both installers ran side by side with `--no-optional` in fresh Ubuntu 22.04 arm64 containers, `main` at `227f824` against this branch. Each took 880 seconds and printed 253 lines, and the logs are the same after the first two lines, where the old dispatcher named the platform and the bootstrap installs `python3`. Both exit 1 with the same three failed steps, and `verify-install.sh` reports 68 passed and 3 failed in both. The three are the baseline for later stages: `install_nix` and `install_nix_direnv` fail because the container has no systemd, and `install_rtk` fails because its arm64 binary needs glibc 2.39 where Ubuntu 22.04 ships 2.35.
- **Gate 3: passed without sudo, owed with it.** With the sudo authentication replaced as the gate describes, `--no-optional` ran all 55 macOS steps and exited 0. The old installer at `227f824`, run the same way straight after, printed the same 66 lines; it took 8.1 seconds and the new one 8.8. The step order in `plan.py` was also compared with both bash `main` functions before they were deleted: 72 items on Linux and 65 on macOS, identical in order, arguments, descriptions and which steps are fatal. Still owed: one run from a terminal, which covers the password prompt, the askpass helper, the keepalive thread and the five optional tools.
- **Gate 4: passed, on a warm cache.** Pull request 4, run 38060789112 on commit `49c9073`: `lint` and `install` passed on GitHub's `ubuntu-latest` runner, the install step in 75 seconds. It restored a 1,070 MB cache through a restore key, so 64 lines were skips and 15 reported real work, among them the apt packages, Nix, fzf, the GitHub CLI, Tailscale, clangd and elan. Its 162 `[install]` and verify lines match the last install run on `main` (`cd06b38`, run 37508327592) except for the opam lines, where the run on `main` had missed the opam cache. No cold run has happened: the weekly schedule runs on `main` alone.
- An interrupted run was checked by hand: SIGINT and SIGTERM during a bash step each end the run with the matching signal status and name the step's log.

Stage 2 started without the terminal run for gate 3, which is still owed.

### Stage 2, 10 October 2026

`install-common.sh` went from 3,989 lines to 3,393, and from 123 functions to 115. The Python installer is 2,173 lines in 19 files, with 1,453 lines of tests.

- **Gate 1: passed.** `nix develop --command make fmt-ci lint test-py` passes, with 111 tests. `make test-py PYTHON=/Library/Developer/CommandLineTools/usr/bin/python3` passes on Python 3.9.6. The step tests run each port against a fake `curl`, `brew`, `go` and `sudo`, and cover both platforms' branches on one machine.
- **Gate 2: passed.** Both installers ran side by side with `--no-optional` in fresh Ubuntu 22.04 arm64 containers, `b1ed1a5` against this stage. Each took 1,248 seconds and printed 251 lines, and the two logs are the same once the temporary directory names are replaced. Both exit 1 with the three baseline failures, and `verify-install.sh` reports 68 passed and 3 failed in both. All seven ported steps installed for real here: cmake through its installer and `sudo`, moor through `go install`, the other five from release assets.
- **Gate 3: passed without sudo.** `--no-optional` on this Mac printed the same 66 lines as `b1ed1a5` run the same way. All seven ported steps skip here, so this run covers their guards alone. The terminal run is still owed from stage 1.
- **Gate 4: passed, on a warm cache.** Run 38068886975 on commit `1bb0d6f`: `lint` and `install` passed, the install job in 140 seconds. Its 163 `[install]` and verify lines match run 38066631156 on `b1ed1a5`. The pin hash reads the same lines from their new file, so its value did not change and the run restored a 1,232 MB cache through a restore key. All seven ported steps skipped, so on x86_64 this run covers their guards alone.
- No gate ran an x86_64 install of the ported steps. As a substitute, a script built every release URL from the steps' own tables for Linux x86_64, Linux aarch64 and macOS arm64, and asked GitHub for the headers of each: all 74 exist, the cargo tools of batch B included.
- `make pins` prints the same 32 lines from Python as `print_pin_updates` printed from `b1ed1a5`.

Three things differ from the bash steps, all on failure paths. `install_gitleaks`, `install_glow` and `install_treehouse` find their binary by name inside the tarball, as `install_ripgrep_all` always did, and report "No gitleaks binary inside ..." where `install` used to fail on a fixed path. A binary is copied beside its target and renamed over it, so an interrupted copy leaves the old one. `lua-language-server`'s link is replaced the same way.

`install_typst` was listed in batch A by mistake. It calls `install_cargo_tool`, so it moves with batch B.

### Stage 3, batch B, 10 October 2026

`install-common.sh` went from 3,393 lines to 3,066, and from 115 functions to 95. The Python installer is 2,608 lines in 20 files, with 1,700 lines of tests. Twenty steps are now Python.

- **Gate 1: passed.** `nix develop --command make fmt-ci lint test-py` passes, with 128 tests, and so does the run on Python 3.9.6.
- **Gate 2: passed.** `1bb0d6f` against this batch, side by side with `--no-optional` in fresh Ubuntu 22.04 arm64 containers. The old run took 1,178 seconds and the new one 1,169. Each printed 251 lines, the same once the temporary directory names are replaced, with the three baseline failures and 68 passed, 3 failed from `verify-install.sh`. Twelve of the thirteen steps ran, `install_typst` being optional. Nine tools came as release binaries, and `git-absorb`, `cargo-fuzz` and `cross` were built by `cargo install`, upstream publishing no aarch64 asset for them.
- **Gate 3: passed without sudo.** The same 66 lines as `1bb0d6f` on this Mac, every step skipping.
- **Gate 4: passed, on a warm cache.** Run 38070838460 on commit `4591e77`: `lint` and `install` passed, the install job in 135 seconds. Its 163 `[install]` and verify lines match run 38068886975 on `1bb0d6f`, and every ported step skipped.

Gates 2 to 4 leave the macOS and x86_64 install paths of a ported step unrun, since a provisioned Mac and a warm CI cache both skip. So this batch added a check that runs the named steps for real into an empty `HOME`, with the system's `PATH` alone, once from `1bb0d6f` and once from this batch, and compares the output and a SHA-256 of every file left behind.

- On this Mac, 12 steps: the 11 that need no `cargo` print the same lines, and the 12 binaries and one zsh completion that both runs install have the same hashes. `install_cargo_extras` differs as the behaviour changes above describe: with no `cargo`, bash stopped at `cargo-fuzz`, and Python went on to install `cargo-llvm-cov` and `samply`.
- In an x86_64 Ubuntu 22.04 container, 19 steps, the six from stage 2 that need no `sudo` included: 1,292 lines each, with one difference, a log file that `lua-language-server` writes when it runs. `cross --version` fails there in both, since `cross` needs a `cargo` the bare container lacks.

### Stage 3, batch C, 10 October 2026

`install-common.sh` went from 3,066 lines to 2,693. `download_verified_github` and `github_asset_sha256` went with the five steps, Neovim having been their last bash caller. The Python installer is 3,051 lines in 25 files, and twenty-five steps are now Python. `retry_once` and `require_command` are in `tools.py`; the bash `retry_once` stays for the bash steps that still call it.

- **Gate 1: passed.** `nix develop --command make fmt-ci lint test-py` passes, with 164 tests, and so does the run on Python 3.9.6.
- **Gate 2: passed.** `b3f0273` against this batch, side by side with `--no-optional` in fresh Ubuntu 22.04 arm64 containers. Each took 2,854 seconds, slower than batch B's 1,169 because the other checks ran on the same machine. The 169 lines of the install are the same in the same order, with the three baseline failures, and both verify runs end 68 passed, 3 failed. The verify output holds the same lines with `[ok] go` two lines apart: `[FAIL]` lines go to stderr, and Docker merges the two streams in no fixed order. The batch B run printed the order this batch printed, from the code that is this run's baseline. atuin, Go, elan and Neovim installed, and the font skipped, the container having no display.
- **Gate 3: passed without sudo.** The same 66 lines as `b3f0273` on this Mac, every step skipping.
- **Gate 4: passed, on a cold cache, at the second run.** Run 38089391495 on `8859681` failed in `lint`: two tests in `test_go.py` found the runner's own `/usr/bin/go` on the `PATH` the step tests used, and the install job was skipped. `854e7fa` takes `/usr/bin` off that `PATH`. Run 38090371590 on it passed, the install job in 457 seconds and verify ending 74 passed, 0 failed. It ran cold, as expected: `NEOVIM_MIN_VERSION` left `install-linux.sh` for `steps/neovim.py`, and CI builds the cache key's pin hash from every `_VERSION=` line in that file. Its 166 lines differ from run 38070838460 only where a step installed in place of skipping, and in three completion lines that an install prints.

The real-install check from batch B, once from `b3f0273` and once from this batch:

- On this Mac, `install_elan`: the same 11 lines, and the 9 files under `~/.elan` have the same hashes. The other three macOS steps go through Homebrew, which an empty `PATH` hides.
- In an x86_64 Ubuntu 22.04 container with `DISPLAY` set, `install_atuin`, `install_elan` and `install_nerd_font`: 28 lines each, with no difference.
- `install_go` and `install_neovim_if_missing` write outside `HOME`, so each version ran as root in an x86_64 container of its own. Both left the same 19,583 entries under `/usr/local/go` and `/opt`, compared by type, size, mode and owner. Two telemetry counter files differ, which `go version` writes on every run.

All 90 release URLs the ported steps build exist, the 16 this batch adds included.

### Stage 4, 10 October 2026

Twenty-six steps moved, in eight modules: `packages.py`, `gh.py`, `node.py`, `clones.py`, `rust.py`, `vendor.py`, `nix.py` and `ansible_lint.py`. `install-common.sh` went from 2,693 lines to 1,980 and from 90 functions to 61, `install-linux.sh` from 242 lines to 166, and `install-macos-arm64.sh` from 80 to 38. The Python installer is 3,974 lines in 34 files, with 3,115 lines of tests, and fifty-one steps are now Python.

A plan's arguments reach a Python step as `context.args`, and `_step` in `plan.py` applies `fatal` and `interactive` to a ported step. `DEBIAN_FRONTEND=noninteractive` is `LINUX.env` in the plan, bash having exported it from a file the Python steps never source. `apt.py` is new, and `tools.py` gained `announce`, `run_downloaded`, `npm_install_g`, `safe_git`, `ensure_user_owns`, `sudo_write` and `load_cargo_env`. The bash `safe_git` and `ensure_user_owns` stay for the Obsidian steps.

- **Gate 1: passed.** `nix develop --command make fmt-ci lint test-py` passes, with 239 tests, and so does the run on Python 3.9.6.
- **Gate 2: passed.** `8859681` against this stage, side by side with `--no-optional` in fresh Ubuntu 22.04 arm64 containers. The old run took 1,186 seconds and the new one 1,196. Each printed 252 lines, the same once the temporary directory names are replaced, with the three baseline failures and 68 passed, 3 failed from `verify-install.sh`. Two of the three baseline failures, `install_nix_direnv` and `install_rtk`, are now Python steps, and each fails with the lines its bash version printed.
- **Gate 3: passed without sudo.** The same 66 lines as `8859681` on this Mac, every step skipping.
- **Gate 4: passed, on a warm cache.** Run 38092111832 on `ef141f3`: `lint` and `install` passed, the install job in 130 seconds. Its 163 `[install]` and verify lines match run 38070838460, the last warm run, and verify ends 74 passed, 0 failed. Every step skipped, so CI has not yet run an install path of this stage; the cold run that closes stage 6 will.

A second reader compared the 26 ports with the bash at `8859681`, function by function, and found no difference in log lines, commands, probes or environment. It found two edge cases, both fixed before the commit: a dangling `/usr/local/bin/starship` symlink counted as a stale binary, and `ensure_user_owns` looked the user up by name, which fails for an account outside the password database. `chown` now takes the numbers. The same reading produced the first of the two behaviour changes this stage adds above.

The real-install check from batch B was not repeated for this stage. Most of these steps call `apt`, `brew`, `npm` or a vendor's installer, and the container run of gate 2 installs through every Linux one of them.

### Stage 5, 10 October 2026

Each group below is one commit. Gate 2 compares a fresh Ubuntu 22.04 arm64 container run of the group, with `--no-optional`, against the run of the commit before it, and gate 3 compares the macOS run without sudo against the 66 lines of `8859681`.

- **Nix.** `install_nix` and its three helpers are in `steps/nix.py`. `installer/shell.py` is new: `shell.source` runs a script in bash and takes the environment it leaves, which is how the Nix profile reaches later steps. Gate 1 passed with 248 tests, in the nix shell and on Python 3.9.6. Gate 2 passed: 252 lines, the same as stage 4's, in 931 seconds. `install_nix` is one of the three baseline failures in a container, and the Python step fails there with the lines bash printed. Gate 3 passed.
- **System.** `install_git` is in `steps/git.py`, and `install_homebrew`, `install_login_shell`, `install_perf`, `install_inotify_limits` and `install_vscode_unattended_upgrades` in `steps/system.py`. `install_homebrew` sources `brew shellenv` through `shell.source`. `install-linux.sh` is down to 40 lines and `install-common.sh` to 1,805. Gate 1 passed with 270 tests, in the nix shell and on Python 3.9.6. Gate 2 passed: the same 252 lines, in 941 seconds. Gate 3 passed.
- **Builds.** `install_tmux_from_source` and `install_btop` are in `steps/builds.py`, with the `SYSTEM_PATH` both builds run under. `context.run` and `context.call` take a `cwd`, and `cpu_count` moves to `tools.py`. `install-common.sh` is down to 1,621 lines. Gate 1 passed with 281 tests, in the nix shell and on Python 3.9.6. Gate 2 passed: the same 252 lines, in 1,596 seconds beside two other container runs. Gate 3 passed.
- **opam.** `install_opam` and `install_ocaml_tools` are in `steps/opam.py`, and `install_ocaml_tools` stays a function `install_opam` calls. The opam cache key in `ci.yml` hashes that module where it read two bash function bodies with `sed`, so the first CI run after this commit builds the switch again. `install-common.sh` is down to 1,371 lines. Gate 1 passed with 290 tests, in the nix shell and on Python 3.9.6. Gate 2 passed: the same 252 lines, in 1,641 seconds beside two other container runs. Gate 3 passed.
- **WezTerm.** `install_wezterm` and `set_default_terminal_wezterm` are in `steps/wezterm.py`. The nightly `.deb` comes through `release.download` with its `.sha256` manifest, and the default-terminal step reads `update-alternatives --query`. `install-common.sh` is down to 1,298 lines. Gate 1 passed with 301 tests, in the nix shell and on Python 3.9.6. Gate 2 passed: the same 252 lines, in 1,625 seconds beside two other container runs. Gate 3 passed.
- **gh-stack.** `install_gh_stack` and `install_gh_stack_skill` join `install_gh` in `steps/gh.py`, with `_authenticated` in place of `gh_authenticated`. Their upgrade commands run under `tools.retry_once`. `install-common.sh` is down to 1,242 lines. Gate 1 passed with 305 tests, in the nix shell and on Python 3.9.6. Gate 2 passed at the second attempt: the same 252 lines, in 1,262 seconds beside one other container run. The first attempt ran this group and the three after it beside a TeX Live install, five containers at once, and Docker ran out of disk, so those four logs were thrown away. Gate 3 passed.
- **Obsidian.** `install_obsidian`, `install_obsync` and both schedulers are in `steps/obsidian.py`, under the one registered step `install_obsidian_stack`. `safe_git`, `ensure_user_owns` and the `OBSYNC_*` constants leave bash with them, and `install-common.sh` is down to 791 lines. Gate 1 passed with 332 tests, in the nix shell and on Python 3.9.6. Gate 2 passed: the same 252 lines, in 1,289 seconds beside one other container run. That run was of the draft tree, which differs from this commit only by the `xcrun` fake in `test_opam.py`. A `--no-optional` run never reaches this step, so gate 2 shows only that the rest still works. Gate 3 passed.
- **zathura, LaTeX, Docker.** Each has a module of its own: `steps/zathura.py`, `steps/latex.py` and `steps/docker.py`. `fetch.resolve` is new, for the mirror that `mirror.ctan.org` redirects to, and `key_fingerprints` moves from `steps/git.py` to `apt.py` for Docker to share. `install-common.sh` is down to 312 lines and holds one step, so its `UPGRADE` carries a shellcheck note: no step there reads it, and `test_legacy.py` still checks that it arrives. Gate 1 passed with 366 tests, in the nix shell and on Python 3.9.6. Gate 2 passed on this tree: the same 252 lines, in 865 seconds beside one other container run. Gate 3 passed.

The port carries one risk that no gate removes: each of the 55 commits to `scripts/` since 10 July encodes a fix found on a real machine, and a fix that loses its comment in translation loses its reason. Every stage should move the comment with the code.
