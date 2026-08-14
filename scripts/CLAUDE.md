# Install Scripts

How `scripts/` is organised. Loaded when working with files under this directory.

All scripts are idempotent — each step checks whether the tool is already present and skips if so. Pass `--upgrade` to upgrade already-installed tools to their latest versions instead of skipping them.

## Optional tools

Almost everything here is installed unconditionally, on the assumption that every machine wants it. A few tools are not like that — they only earn their place on a machine that is actually sat in front of, and are noise on a box that only ever gets ssh'd into. Those go through `optional_enabled`, which asks once and remembers.

Answers live in `~/.config/dotfiles/optional-tools.conf` (respecting `XDG_CONFIG_HOME`) as `name=yes|no`, one per line. Because the answer is recorded, later runs — including `--upgrade` — stay fully non-interactive, so the prompt does not become a tax on every install.

The split is deliberately *not* inferred. Hostnames churn, and the existing `DISPLAY`/`WAYLAND_DISPLAY` headless check only catches the Linux GUI case — it says nothing on macOS, and nothing about a desktop Linux box that is still only used as a server. Asking is the honest version.

| Flag | Effect |
|---|---|
| `--all-optional` | install every optional tool, no prompting (does not touch the state file) |
| `--no-optional` | skip every optional tool, no prompting (does not touch the state file) |
| `--reconfigure-optional` | re-ask every optional tool, overwriting the recorded answers |

With no flag and no recorded answer, the user is prompted; the default on a bare `<enter>` is no. The prompt reads from `/dev/tty` rather than stdin, since the platform scripts are routinely piped. When there is no terminal at all (CI, a provisioning run), the tool is skipped and **no answer is recorded**, so a later interactive run still gets to ask. Note that `[[ -r /dev/tty ]]` is not a usable interactivity test — the device node reads as readable even with no controlling terminal attached, where actually opening it fails — hence the `{ : </dev/tty; }` open attempt.

Add an optional tool with `run_optional_step <key> <description> <install_fn>` in both platform scripts.

## Sudo

Both platform scripts call `start_sudo_keepalive` (in `install-common.sh`) as their first privileged action, so the password is asked for exactly once. A full install — especially `--upgrade`, which rebuilds tmux and re-fetches every toolchain — runs far longer than sudo's credential cache (15 min by default), so without this the later steps each re-prompt. It authenticates with `sudo -v`, then backgrounds a loop refreshing the timestamp with `sudo -n true` every 50s, torn down by an `EXIT` trap. The loop is additionally bounded by `kill -0 $$` so no refresher survives a `SIGKILL`ed install, and breaks rather than blocking if `sudo -n` fails (`timestamp_timeout=0`), degrading to per-step prompts. Skipped entirely when already root.

Uses no bash 4+ features, so it is safe under the bash 3.2 macOS ships. Ordering matters on macOS: the Homebrew installer arms a `trap '/usr/bin/sudo -k' EXIT` that would wipe the cached timestamp, but only when guarded by `! sudo -n -v` — i.e. only if sudo was not already active — so `start_sudo_keepalive` must run before `install_homebrew`. It cannot suppress GUI escalation, which is a separate mechanism from sudo's timestamp: the `xcode-select --install` dialog and any cask using Authorization Services or a system-extension approval still prompt.

## `scripts/install-linux.sh`

Supports x86_64 and aarch64 — arch is detected at runtime. Two steps that are not what they look like:

- `perf` (`linux-tools-generic`) — best-effort; skipped with a warning (not a failure) if the exact-version kernel-tools package isn't available, which is common on cloud/CI kernels
- `install_inotify_limits` — writes a sysctl drop-in (`/etc/sysctl.d/60-inotify-watches.conf`) raising `fs.inotify.max_user_watches`/`max_user_instances`, so VS Code's file watcher doesn't hit "Unable to watch for file changes" on large workspaces

## `scripts/install-common.sh`

Shared functions called by both platform scripts. Only the ones with a non-obvious install path are listed — read the file for the rest:

| Function | What it installs |
|---|---|
| `install_cmake` | cmake >= 4.3.2 — prebuilt binary from GitHub releases (Linux x86_64/ARM64), or `brew install/upgrade cmake` (macOS) |
| `install_nix` | Nix package manager — official multi-user (`--daemon`) installer from nixos.org; powers `flake.nix` devShells. `enable_nix_flakes` appends the flakes line as an immediate-post-install fallback; `home/dot_config/nix/nix.conf` (flakes + `min-free`/`max-free` auto-GC) is the source of truth once `chezmoi apply` has run. `configure_nix_trusted_user` adds the installing user to `trusted-users` in `/etc/nix/nix.conf` (via `sudo`, restarting the daemon) since the multi-user daemon otherwise silently ignores those restricted settings from untrusted users |
| `install_direnv` | `direnv` binary via official install script to `~/.local/bin`; hooked into zsh via `_cache_eval direnv hook zsh` |
| `install_nix_direnv` | `nix-direnv` via `nix profile install`, wired into `~/.config/direnv/direnvrc`, for cached devShell loading; installs `install_modern_bash` first |
| `install_modern_bash` | macOS only — installs bash >= 4.4 via `nix profile install nixpkgs#bash`, since nix-direnv requires it and macOS ships bash 3.2 |
| `install_go` | Go toolchain — downloads latest stable from `go.dev/dl`; upgrades system Go if < 1.21 (needed for `GOTOOLCHAIN=auto`); Linux only (macOS uses brew as needed) |
| `install_moor` | `moor` pager (formerly `moar`) — `brew install moor` (macOS); Linux x86_64: official release binary from GitHub; Linux arm64: `GOTOOLCHAIN=auto go install` (no official arm64 binary) |
| `install_treehouse` | `treehouse` git-worktree pool manager — official release tarball from GitHub extracted to `~/.local/bin` (all platforms: darwin/linux x amd64/arm64; no brew formula) |
| `install_btop` | `btop` resource monitor (modern `top`/`htop` alternative) — `brew install btop` (macOS) or **built from source** into `~/.local/bin` (Linux), version-pinned. Source build because neither packaged option shows GPU metrics: apt jammy/universe is stuck at 1.2.3 (GPU monitoring arrived in 1.3.0), and the upstream release binaries are `STATIC=true`, which btop's Makefile treats as force-disabling `GPU_SUPPORT` since the NVIDIA/AMD backends dlopen their vendor libraries. A stock source build defaults `GPU_SUPPORT=true` on linux/x86_64 and resolves `libnvidia-ml.so` at runtime, so no CUDA toolkit is needed to build. Pinned at 1.4.4 because 1.4.5+ needs GCC 14 (`std::ranges::to`) and jammy ships GCC 11 — bump when the oldest target distro catches up. `make` is invoked with a pruned `PATH` and explicit `CXX=/usr/bin/g++`, since a nix-populated PATH mixes nix binutils/glibc into the link and fails on `__isoc23_*`. Also `apt purge`es any packaged btop, which would otherwise shadow `~/.local/bin` on PATH, and copies themes to `~/.config/btop/themes` to replace the `/usr/share/btop/themes` the purge removes |
| `install_zstd` | Zstandard CLI + headers — `brew install zstd` (macOS) or apt `zstd libzstd-dev` (Linux). The Linux guard checks `dpkg -s libzstd-dev` as well as `command -v zstd`, since Ubuntu images often ship the CLI alone and a `command -v` check would skip the headers forever |
| `install_ccusage` | `ccusage` CLI via `npm install -g` (no MCP registration) |
| `install_atuin` | `atuin` shell-history database and sync client — `brew install atuin` (macOS), or the official release tarball from GitHub extracted to `~/.local/bin` (Linux x86_64/ARM64, both `*-unknown-linux-gnu`). Two quirks in the Linux version check: the leading `v` is stripped from the release tag before comparing, since `atuin --version` reports a bare `18.19.0` against a `v18.19.0` tag; and the version is read from field 2 rather than `$NF`, since that output is `atuin 18.19.0 ()` — a trailing empty git-hash field that `$NF` would return instead of the version, making every `--upgrade` re-download a current build. Shell wiring is in `home/dot_zshrc.tmpl`, settings in `home/dot_config/atuin/private_config.toml`; only `atuin register`/`atuin login` against that server is left to do by hand |
| `install_gh_stack` | `github/gh-stack`, the official GitHub gh CLI extension for stacked branches and pull requests (`gh stack init/add/push/submit/rebase/sync/merge/view` plus the navigation commands) — `gh extension install github/gh-stack` on macOS and Linux alike, `gh extension upgrade gh-stack` under `--upgrade`. The already-installed check greps `gh extension list` for `github/gh-stack`, matching the source repo rather than the extension name, so a same-named extension from a different owner is replaced rather than mistaken for this one |
| `install_gh_stack_skill` | the *agent skill* that ships inside that same repo, at `skills/gh-stack/` — `gh skill install github/gh-stack gh-stack --agent claude-code --scope user --force`, or `gh skill update gh-stack --all` under `--upgrade` (`--all` means "do not prompt" here, not "every skill"; it still targets only the named skill). Detected with `gh skill list --agent claude-code --scope user --json skillName --jq '.[].skillName'` grepped for an exact `gh-stack` |
| `install_wezterm` | WezTerm — `brew install --cask` (macOS), `.deb` from GitHub releases (Linux x86_64); skipped on ARM64 |
| `install_nerd_font` | CodeNewRoman Nerd Font — `brew install --cask font-code-new-roman-nerd-font` (macOS) or GitHub releases zip extracted to `~/.local/share/fonts/` (Linux); skipped on headless Linux |
| `install_obsidian` | **Optional** (key `obsidian`) — Obsidian desktop app. `brew install --cask obsidian` (macOS), `obsidian_<ver>_amd64.deb` from GitHub releases (Linux x86_64), or the `obsidian-<ver>-arm64.tar.gz` unpacked to `~/.local/share/obsidian` (Linux ARM64, since upstream ships no ARM64 `.deb`); skipped on headless Linux |
| `install_zathura` | **Optional** (key `zathura`) — zathura PDF viewer. `brew install zathura --with-synctex` plus `zathura-pdf-poppler` from the `homebrew-zathura/zathura` tap (macOS), or `apt install zathura zathura-pdf-poppler` (Linux); skipped on headless Linux. Config lives at `home/dot_config/zathura/zathurarc` |

No install step registers MCP servers — that is left to `claude mcp add` by hand.

### Both gh-stack steps need an authenticated gh

`install_gh_stack` and `install_gh_stack_skill` both hit the GitHub API — one to resolve the extension's release, the other to read the skill's contents — so both need a gh that has already logged in. Nothing in these scripts authenticates it. `gh auth login` is interactive and cannot be automated, so on a freshly provisioned box the credential is simply absent. The shared guard is `gh_authenticated`; when it fails, each step logs a warning and returns rather than failing the run, and the next install after the user has authenticated picks both up.

The skill goes in at *user scope*. `gh skill install` defaults to `--scope project`, which would install it into whichever repository the install script happened to run from; user scope puts it at `~/.claude/skills/gh-stack`, so it applies everywhere. That path is not managed by chezmoi — nothing under `home/dot_claude/` claims `skills/` — so the install script writing it and `chezmoi apply` cannot conflict.

`gh skill` is a preview command. gh labels it "in preview and subject to change without notice", which makes this the step most likely to break on a future gh upgrade: a release that renames or drops these flags takes the skill step down with it, while the extension step keeps working.

### The Obsidian CLI is not separately installable

`install_obsidian` installs the **desktop app**, not the CLI, because the thing advertised at [obsidian.md/cli](https://obsidian.md/cli) is not a standalone binary. It ships inside the app (1.12.7+) and is registered by a GUI toggle — Settings → General → *Command line interface* — which copies the binary to `~/.local/bin/obsidian` on Linux, or symlinks `/usr/local/bin/obsidian` on macOS (needing admin). There is no documented non-interactive registration, so the script installs the app and prints the remaining manual step via `print_obsidian_cli_hint`.

The CLI also requires the app to be **running** — the first command launches it if it is not. That is what makes this a dev-machine tool rather than a server one, and why it is gated behind a prompt.

On Linux ARM64 the unpacked launcher is symlinked to `~/.local/bin/obsidian-app`, deliberately *not* `obsidian`: that name belongs to the CLI that registration installs, and clobbering it would break the CLI. The same branch also `chown root:root` + `chmod 4755`es the bundled `chrome-sandbox`, since Electron refuses to start without a setuid sandbox helper — the `.deb` does this itself, an unpacked tarball cannot. It is best-effort, and logs a `--no-sandbox` hint if it fails.

For syncing a vault from a server with no desktop app, upstream publishes a separate npm package, `obsidian-headless` (binary `ob`, Node >= 22, proprietary). It is Sync-only, not the CLI, and is not installed here.

### zathura on macOS needs a tap, a plugin, and a symlink

There is no zathura in homebrew-core, so `install_zathura` taps [`homebrew-zathura/zathura`](https://github.com/homebrew-zathura/homebrew-zathura) and builds from source. Three things about that tap do not follow the usual formula:

- **The tap has to be trusted.** Homebrew 6 refuses to load formulae from an unofficial tap until `brew trust` records it. The refusal is a per-formula error, *not* a failed `brew tap`, so a step that only checks the tap walks straight past it and reports a clean install having built nothing — which is exactly what happened the first time this ran. `install_zathura` checks `brew trust --json v1` and trusts the tap once. The same gate applies to `Noah4ever/tap` in the `deps` Make target.
- **`--with-synctex` is not optional here.** The formula declares `synctex` as an `:optional` dependency, so a plain `brew install zathura` produces a build with no SyncTeX. The managed `zathurarc` is mostly *about* SyncTeX inverse search, so the option is always passed. `brew upgrade` reuses the options a formula was installed with, and the flag is appended on the upgrade path too, which repairs a build made before this step existed.
- **A backend plugin is mandatory.** zathura renders nothing on its own; each document format is a separate formula. `zathura-pdf-poppler` is installed and guarded separately from zathura itself, so an interrupted first run cannot leave a viewer with no backend.
- **The plugin has to be linked by hand.** Its formula installs `libpdf-poppler.dylib` into its own keg, but zathura only scans `$(brew --prefix zathura)/lib/zathura`. `link_zathura_pdf_plugin` creates that directory and symlinks the dylib in, and runs on every path including the already-installed one, so a plugin that was installed but never linked gets fixed on the next run.

The tap also publishes a `convert-into-app.sh` that builds an `/Applications/Zathura.app` wrapper. It is not run — it is a `curl | sh` that needs re-running after every plugin change, and the command-line viewer is enough for inverse search — so `print_zathura_app_hint` just points at it.

Linux needs none of this: Debian and Ubuntu package zathura with SyncTeX already built in, and `zathura-pdf-poppler` is a plain apt package that lands in the right place.

### Why poppler and not mupdf

The tap recommends `zathura-pdf-mupdf`, and mupdf *is* the faster renderer — but only in ratio. Measured with hyperfine on a 6-page typst paper (text, display math, tables), rendering identical 1241×1754 rasters:

| workload | mupdf | poppler | gap |
|---|---|---|---|
| 1 page @150 DPI | 24.3 ms | 30.2 ms | 5.9 ms |
| 1 page @300 DPI | 26.9 ms | 42.2 ms | 15.3 ms |
| 6 pages @150 DPI | 37.6 ms | 102.3 ms | 64.7 ms |

Watch mode re-renders the *visible page*, so the first row is the case that matters; the 2.7× only appears when rendering a whole document at once, which zathura never does. Most of each figure is process startup and parse — 4× the pixels costs mupdf just +2.6 ms — so true rasterisation is roughly 1 ms against 4 ms. For scale, `typst compile` on the same document is **92 ms ± 2.5**, its jitter alone comparable to the entire backend difference.

So poppler costs ~3 ms per re-render and saves 71 MB of mupdf (plus `mujs` and `gumbo-parser`, orphaned once mupdf goes), reuses the poppler most machines already have, and puts both platforms on one renderer instead of two sets of rendering quirks.

The macOS build is cheaper than "builds from source" suggests. Nothing in the dependency closure compiles — `girara` resolves to the **homebrew/core** formula, which is bottled and shadows the tap's copy — so only the tap's own small meson projects build.

Timings on an M1 with `gtk+3` already present. The full run was measured against the *mupdf* backend before the switch: **6m43s wall-clock, of which 34s was compilation** (`synctex` 4s, `zathura` 19s, `zathura-pdf-mupdf` 11s), the rest Homebrew overhead and bottle downloads with `mupdf` alone at ~170s. Dropping mupdf removes that download; `zathura-pdf-poppler` was separately measured at **61s** with zathura already built. A clean poppler install end-to-end was never timed from scratch, so treat "a few minutes" as the honest figure rather than either number.

Both figures hold only while `arm64_*` bottles exist for the running macOS. On a just-released version, a bottle-less dependency falls back to source — which is the case that turns minutes into an hour.

Release archives are extracted with `tar -xf`, never `-xzf`: tar picks the decompressor from the archive's magic bytes, so an upstream that switches from `.tar.gz` to `.tar.zst` needs no script change. GNU tar shells out to the `zstd` binary to do it, which `install_zstd` guarantees is present.

## `scripts/verify-install.sh`

Checks that all expected commands and directories exist after installation. Run after an install script to confirm nothing is missing. Exits non-zero if any check fails.

`obsidian` and `zathura` are checked with `check_cmd_optional`, so they warn rather than fail. Both are optional per machine. `obsidian` additionally only exists after the app's manual GUI registration step, and `zathura` is skipped outright on headless Linux — a hard check would fail on a correctly-installed machine in either case.

The gh-stack extension and skill go through `check_optional`, which takes a label plus a command instead of a binary name, since neither of them puts anything on PATH. Both warn for the same reason as above: the install skips them whenever gh is unauthenticated, so a hard check would fail on a machine that is set up correctly and merely has not run `gh auth login`.

