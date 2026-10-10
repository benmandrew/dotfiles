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
- On SIGTERM the runner ends the bash step it is waiting on and dies of the signal at once. Bash held the signal until the step's current command had finished. A command the step started may still be running after the runner has gone.

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
- [ ] Gate. See the log.

### Stage 3: the remaining release-binary steps

Port in batches, deleting each bash function as its batch passes the gate. `retry_once`, `cpu_count`, `safe_git`, `ensure_user_owns` and `npm_install_g` move with the first step that calls them.

- [ ] Batch B, the cargo tools, `install_typst` among them: `_rust_tool_spec`, `_install_rust_tool_binary`, `install_cargo_tool` and the steps built on them (`install_eza`, `install_fd`, `install_bat`, `install_ripgrep`, `install_git_delta`, `install_hyperfine`, `install_zoxide`, `install_sccache`, `install_difftastic`, `install_git_absorb`, `install_cargo_nextest`, `install_cargo_extras`).
- [ ] Batch C: `install_atuin`, `install_elan`, `install_nerd_font`, `install_neovim_if_missing`, `install_go`.
- [ ] Gate after each batch.

### Stage 4: package-manager and clone steps

- [ ] Homebrew and apt helpers: `install_brew_formulae_if_missing`, `install_apt_packages_if_missing`, and the steps that only call a package manager (`install_jq`, `install_zstd`, `install_gh`, `install_clangd`, `install_node`).
- [ ] npm globals: `install_pyright`, `install_bash_ls`, `install_ccusage`.
- [ ] Git clones: `install_zinit`, `install_fzf`, `install_fzf_tab`, `install_fzf_git`, `install_zsh_autosuggestions`, `install_tmux_plugins`.
- [ ] Vendor installers run from disk: `install_rust`, `install_rust_analyzer`, `install_uv`, `install_starship`, `install_direnv`, `install_nix_direnv`, `install_claude_code`, `install_rtk`, `install_tailscale`, `install_ansible_lint`.
- [ ] Gate.

### Stage 5: one-off steps

One step per change, each with its own gate, because each holds fixes that no other step shares.

- [ ] `install_nix`, `enable_nix_flakes`, `configure_nix_trusted_user`, `source_nix_profile`.
- [ ] `install_homebrew`, `install_login_shell`, `install_git`, `install_perf`, `install_inotify_limits`, `install_vscode_unattended_upgrades`.
- [ ] `install_tmux_from_source`, `install_btop`.
- [ ] `install_opam`, `install_ocaml_tools`. The opam cache key in `ci.yml` reads these function bodies with `sed` and must move with them.
- [ ] `install_wezterm`, `set_default_terminal_wezterm`.
- [ ] `install_gh_stack`, `install_gh_stack_skill`.
- [ ] `install_obsidian`, `install_obsync` and the cron and launchd schedulers.
- [ ] `install_zathura`, `install_latex`, `install_docker`.
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
- **Gate 2: running.**
- **Gate 3: passed without sudo.** `--no-optional` on this Mac printed the same 66 lines as `b1ed1a5` run the same way. All seven ported steps skip here, so this run covers their guards alone. The terminal run is still owed from stage 1.
- **Gate 4: waiting on the push.** The pin hash in `ci.yml` now reads `scripts/pins.sh`, so no cache key matches and the install runs cold.
- `make pins` prints the same 32 lines from Python as `print_pin_updates` printed from `b1ed1a5`.

Three things differ from the bash steps, all on failure paths. `install_gitleaks`, `install_glow` and `install_treehouse` find their binary by name inside the tarball, as `install_ripgrep_all` always did, and report "No gitleaks binary inside ..." where `install` used to fail on a fixed path. A binary is copied beside its target and renamed over it, so an interrupted copy leaves the old one. `lua-language-server`'s link is replaced the same way.

`install_typst` was listed in batch A by mistake. It calls `install_cargo_tool`, so it moves with batch B.

The port carries one risk that no gate removes: each of the 55 commits to `scripts/` since 10 July encodes a fix found on a real machine, and a fix that loses its comment in translation loses its reason. Every stage should move the comment with the code.
