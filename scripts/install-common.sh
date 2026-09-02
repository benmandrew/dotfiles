#!/bin/bash

UPGRADE=""
VERBOSE=""
_INSTALL_FAILED=false
_FAILED_STEPS=()

# fd 3 is the terminal, held aside so log and err still reach it from inside a
# step whose own output is being redirected to a file. Everything this script
# says for itself goes through those two functions and so writes to fd 3; a
# step's stdout and stderr both go to its log.
exec 3>&2

# A step's output is held in a file rather than printed as it goes. Live stderr
# is not the same as quiet stderr: curl writes its progress meter there, nix and
# the direnv installer narrate there, and apt's progress bar leaves the cursor
# mid-line, so the next [install] line starts wherever the bar ended. The log of
# a step that succeeds is deleted, and the tail of one that fails is printed
# where it failed, with the path to the whole thing.
_STEP_LOG_DIR=""
_STEP_LOG_LINES=50

# The terminal's line settings from before the running step, held here rather
# than in a local so the handlers below can put them back. Empty when no step
# is running.
_QUIET_TTY_STATE=""

_quiet_restore_tty() {
    if [[ -n "${_QUIET_TTY_STATE}" ]]; then
        stty "${_QUIET_TTY_STATE}" </dev/tty 2>/dev/null || true
        _QUIET_TTY_STATE=""
    fi
}

# One handler for everything this script has to undo, because a second
# `trap ... EXIT` replaces the first rather than adding to it.
_install_cleanup() {
    _quiet_restore_tty
    stop_sudo_helpers
    # rmdir, not rm -rf: the directory is empty once every step that passed has
    # had its log deleted, and a run with a failure keeps its logs.
    if [[ -n "${_STEP_LOG_DIR}" ]]; then
        rmdir "${_STEP_LOG_DIR}" 2>/dev/null || true
    fi
}

# Clean up, then re-raise, so an interrupted run still dies of the signal it was
# sent instead of carrying on to the next step.
_install_signal_exit() {
    local signal="$1"
    _install_cleanup
    trap - "${signal}" EXIT
    kill "-${signal}" "$$"
}

trap _install_cleanup EXIT
trap '_install_signal_exit INT' INT
trap '_install_signal_exit TERM' TERM

# Homebrew 6 has ask mode on by default, so `brew install` and `brew upgrade`
# stop for a [y/n] confirmation whenever the plan reaches past the packages
# named on the command line — a dependency bump, a cask's dependants. Nothing
# here answers those prompts, so an install left to run unattended stalls on the
# first one. HOMEBREW_NO_ASK is what turns the default back off; the equivalent
# per-command flags are --no-ask/--yes.
export HOMEBREW_NO_ASK=1

# Drop a command's stdout, keeping stderr. Package managers and build systems
# narrate their whole run on stdout, so an apt install, a brew upgrade and a
# make between them bury the one line that matters. All of them report failure
# on stderr, which passes through. Everything this script says for itself goes
# through log/err, which write to stderr for that reason, so a step's own
# progress survives the drop. --verbose puts stdout back for a step that has to
# be watched.
#
# Two guards come with holding a step's output, because a step that has lost the
# screen has not lost the terminal. Its stdin is /dev/null, so a program testing
# whether it is interactive decides it is not, and prints rather than prompting
# or drawing a TUI that nobody can see. And the terminal's line settings are
# saved before the step and restored after, so one that puts the tty in raw mode
# and dies before restoring it cannot leave the shell behind it unusable. An
# --upgrade run on 19 August 2026 did that: the shell it ran from was left at
# `-isig -opost`, so ^C and ^Z did nothing and every line of output started where
# the last one ended. Which step it was went unidentified, which is the argument
# for guarding all of them rather than the suspects. The restore hangs off the
# signal handlers as well as the end of the step, since Ctrl-C during a step
# would otherwise skip it and leave exactly that shell behind.
#
# Steps that must prompt therefore cannot go through here. The two that do —
# `install_xcode_clt` and `install_homebrew` — are called directly instead.
#
# Failure propagates: a bare `quiet foo` under errexit still aborts, since the
# status is returned unchanged, and `if ! quiet foo` suppresses errexit exactly
# as `if ! foo` did.
quiet() {
    if { : </dev/tty; } 2>/dev/null; then
        _QUIET_TTY_STATE="$(stty -g </dev/tty 2>/dev/null || true)"
    fi

    local status=0 log_file=""
    if [[ -n "${VERBOSE}" ]]; then
        "$@" </dev/null || status=$?
    else
        if [[ -z "${_STEP_LOG_DIR}" ]]; then
            _STEP_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install.XXXXXX")"
        fi
        log_file="${_STEP_LOG_DIR}/$1.log"
        "$@" </dev/null >"${log_file}" 2>&1 || status=$?
    fi

    _quiet_restore_tty

    if [[ -n "${log_file}" ]]; then
        if ((status == 0)); then
            rm -f "${log_file}"
        else
            err "Output of $1, last ${_STEP_LOG_LINES} lines (all of it: ${log_file}):"
            tail -n "${_STEP_LOG_LINES}" "${log_file}" >&3
        fi
    fi
    return "${status}"
}

run_step() {
    if ! quiet "$@"; then
        err "Step failed: $*"
        _INSTALL_FAILED=true
        _FAILED_STEPS+=("$*")
    fi
}

# Name the failed steps again at the end. A full install runs 60 steps on Linux
# and 55 on macOS, printing a screen or two of stderr past the one that broke, so
# the report at the point of failure has scrolled away by the time it ends.
check_failed() {
    # The log directory is removed by the EXIT handler, which gets an
    # interrupted run as well as this one.
    if [[ "${_INSTALL_FAILED}" == "true" ]]; then
        local count="${#_FAILED_STEPS[@]}" noun="steps"
        if ((count == 1)); then
            noun="step"
        fi
        err "${count} ${noun} failed:"
        local step
        for step in "${_FAILED_STEPS[@]}"; do
            printf "\033[1;31m[install]\033[0m   %s\n" "${step}" >&3
        done
        exit 1
    fi
}

log() {
    if [[ "$*" == *"skipping"* ]]; then
        printf "\033[1;33m[install]\033[0m %s\n" "$*" >&3
    elif [[ "$*" == *"pgrading"* ]]; then
        printf "\033[1;36m[install]\033[0m %s\n" "$*" >&3
    else
        printf "\033[1;32m[install]\033[0m %s\n" "$*" >&3
    fi
}

err() {
    printf "\033[1;31m[install]\033[0m ERROR: %s\n" "$*" >&3
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing required command: $1"
        exit 1
    fi
}

# Every fetch here goes to a third-party host that rate-limits, and one bad
# minute takes a whole step down — a GitHub codeload 429 is what prompted this.
# curl retries transient HTTP status on its own (408, 429 and the 5xx family,
# honouring Retry-After when the server sends one) with an exponential backoff
# from 1s, so five attempts span about 30s. --retry-connrefused adds the
# connection-level case, which a bare --retry ignores. Deliberately not
# --retry-all-errors: that retries a 404 too, so a release asset renamed
# upstream would burn the full backoff before reporting the obvious.
_CURL_RETRY_OPTS=(--retry 5 --retry-connrefused --retry-max-time 120)

# Fetch a URL to a path. Failure is reported and returned, never ignored:
# errexit does not apply inside a function called from run_step (bash disables
# it for the whole `if ! ...` condition), so a step whose download failed would
# otherwise carry on and unpack, build and install a file that is not there.
download() {
    local url="$1" dest="$2"
    if ! curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" "${url}" -o "${dest}"; then
        err "Download failed: ${url}"
        return 1
    fi
}

# sha256 of a file, from whichever tool the platform has: coreutils on Linux,
# shasum on macOS.
sha256_file() {
    local file="$1" out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "${file}")" || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "${file}")" || return 1
    else
        err "Neither sha256sum nor shasum is on PATH; cannot verify downloads"
        return 1
    fi
    # Both print `<hash>  <path>`.
    printf '%s\n' "${out%% *}"
}

# Check a downloaded file against a checksum manifest published beside it.
#
# The manifests disagree on layout. Some releases ship one line per asset
# (charmbracelet, kunchenguid and gitleaks call it checksums.txt, Kitware and
# ryanoasis SHA-256.txt), some a file per asset holding the hash and the name
# (BurntSushi, atuinsh, wez, nextest-rs), and mozilla ships the hash on its own
# with no name at all. atuinsh prefixes the name with `*`, BSD's binary marker.
# So the hash is the first field of the line naming the asset, falling back to
# the only field when the manifest names nothing.
#
# What this buys and what it does not: the manifest sits in the same release as
# the asset, so it cannot detect a release the publisher's own account was used
# to rewrite. It does catch a truncated or corrupted download, and an asset
# swapped underneath a tag pinned below — which is the failure the pins exist
# to make visible.
verify_sha256() {
    local file="$1" manifest_url="$2" asset="$3"
    local manifest expected actual
    manifest="$(mktemp)"
    if ! download "${manifest_url}" "${manifest}"; then
        rm -f "${manifest}"
        err "Could not fetch the checksum manifest for ${asset}"
        return 1
    fi
    # Matched on the whole name field rather than on a substring of the line,
    # because a manifest listing `<asset>.tar.gz` also lists
    # `<asset>.tar.gz.sbom.json` beside it and a substring match would take
    # whichever came first. The leading `*` is BSD's binary marker.
    expected="$(awk -v a="${asset}" \
        '{ n = $NF; sub(/^\*/, "", n); if (n == a) { print $1; exit } }' "${manifest}")"
    if [[ -z "${expected}" ]]; then
        expected="$(awk 'NF == 1 { print $1; exit }' "${manifest}")"
    fi
    rm -f "${manifest}"
    expected="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
        err "No sha256 for ${asset} in ${manifest_url}"
        return 1
    fi
    actual="$(sha256_file "${file}")" || return 1
    actual="$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${actual}" != "${expected}" ]]; then
        err "Checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
        return 1
    fi
}

# download, then verify. The name looked up in the manifest is the last path
# component of the download URL.
download_verified() {
    local url="$1" dest="$2" manifest_url="$3"
    download "${url}" "${dest}" || return 1
    verify_sha256 "${dest}" "${manifest_url}" "${url##*/}" || return 1
}

# nproc is coreutils and absent on macOS. Only Linux calls the two steps that
# build from source, but neither should depend on that staying true.
cpu_count() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.ncpu 2>/dev/null || echo 1
    else
        echo 1
    fi
}

# --- Pinned upstream versions ------------------------------------------------
#
# Ten steps used to resolve their tag through github_latest_tag on every run, so
# two machines provisioned months apart came up with different builds of every
# tool, and an upstream release that breaks something landed on whichever
# machine happened to be provisioned next. A normal run installs the versions
# below instead.
#
# --upgrade ignores the pins and takes whatever upstream calls latest, which is
# also how a pin gets bumped: `make pins` prints each constant beside the tag
# upstream publishes now, and the ones that differ are edited in here by hand.
# Pinning is also what makes the checksum verification above worth anything,
# since a floating tag has no fixed content to check against.
#
# Each value is the tag exactly as upstream publishes it -- some carry a leading
# `v`, some do not, and nextest-rs prefixes the crate name -- so the call sites
# strip what they need rather than the constants guessing.
ATUIN_VERSION="v18.21.0"
BAT_VERSION="v0.26.1"
CARGO_NEXTEST_VERSION="cargo-nextest-0.9.143"
CMAKE_VERSION="v4.4.3"
DELTA_VERSION="0.19.2"
DIFFTASTIC_VERSION="0.70.0"
ELAN_VERSION="v4.2.4"
EZA_VERSION="v0.23.5"
FD_VERSION="v10.5.0"
GIT_ABSORB_VERSION="0.9.0"
GITLEAKS_VERSION="v8.30.1"
GLOW_VERSION="v3.0.0"
GO_VERSION="go1.27.1"
HYPERFINE_VERSION="v1.20.0"
LUA_LS_VERSION="3.19.1"
MOOR_VERSION="v2.18.0"
NERD_FONTS_VERSION="v3.5.1"
OPAM_VERSION="2.5.2"
RIPGREP_ALL_VERSION="v0.10.10"
RIPGREP_VERSION="15.2.0"
SCCACHE_VERSION="v0.17.0"
TREEHOUSE_VERSION="v2.3.0"
ZOXIDE_VERSION="v0.10.0"

# btop is pinned for a reason of its own rather than for reproducibility: >=
# 1.4.5 uses std::ranges::to, which needs GCC 14, and jammy ships GCC 11. Bump
# it once the oldest target distro has a new enough compiler.
BTOP_VERSION="1.4.4"

# tmux is built from source, and the build is the slowest step in the run, so
# this deliberately lags upstream rather than tracking it.
TMUX_VERSION="3.6b"

# The pinned tag, or the newest tag upstream publishes under --upgrade.
pinned_tag() {
    local pin="$1" repo="$2"
    if [[ -n "${UPGRADE:-}" ]]; then
        github_latest_tag "${repo}"
        return
    fi
    printf '%s\n' "${pin}"
}

# Print each pin beside the tag upstream publishes now, for `make pins`. A line
# where the two differ is a pin that can be bumped. Writes to stdout: this is a
# report, not a step.
print_pin_updates() {
    local spec name repo pinned latest
    for spec in \
        "ATUIN_VERSION|atuinsh/atuin" \
        "BAT_VERSION|sharkdp/bat" \
        "BTOP_VERSION|aristocratos/btop" \
        "CARGO_NEXTEST_VERSION|nextest-rs/nextest" \
        "CMAKE_VERSION|Kitware/CMake" \
        "DELTA_VERSION|dandavison/delta" \
        "DIFFTASTIC_VERSION|Wilfred/difftastic" \
        "ELAN_VERSION|leanprover/elan" \
        "EZA_VERSION|eza-community/eza" \
        "FD_VERSION|sharkdp/fd" \
        "GIT_ABSORB_VERSION|tummychow/git-absorb" \
        "GITLEAKS_VERSION|gitleaks/gitleaks" \
        "GLOW_VERSION|charmbracelet/glow" \
        "HYPERFINE_VERSION|sharkdp/hyperfine" \
        "LUA_LS_VERSION|LuaLS/lua-language-server" \
        "MOOR_VERSION|walles/moor" \
        "NERD_FONTS_VERSION|ryanoasis/nerd-fonts" \
        "OPAM_VERSION|ocaml/opam" \
        "RIPGREP_ALL_VERSION|phiresky/ripgrep-all" \
        "RIPGREP_VERSION|BurntSushi/ripgrep" \
        "SCCACHE_VERSION|mozilla/sccache" \
        "TMUX_VERSION|tmux/tmux" \
        "TREEHOUSE_VERSION|kunchenguid/treehouse" \
        "ZOXIDE_VERSION|ajeetdsouza/zoxide"; do
        name="${spec%%|*}"
        repo="${spec#*|}"
        pinned="${!name}"
        latest="$(github_latest_tag "${repo}" 2>/dev/null)" || latest=""
        if [[ -z "${latest}" ]]; then
            printf '%-24s %-30s (upstream unreachable)\n' "${name}" "${pinned}"
        elif [[ "${pinned}" == "${latest}" ]]; then
            printf '%-24s %-30s up to date\n' "${name}" "${pinned}"
        else
            printf '%-24s %-30s -> %s\n' "${name}" "${pinned}" "${latest}"
        fi
    done
    # Go publishes its current release as plain text rather than as a GitHub tag.
    local go_out go_latest
    go_out="$(curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" \
        'https://go.dev/VERSION?m=text' 2>/dev/null)" || go_out=""
    go_latest="${go_out%%$'\n'*}"
    if [[ -z "${go_latest}" ]]; then
        printf '%-24s %-30s (upstream unreachable)\n' GO_VERSION "${GO_VERSION}"
    elif [[ "${go_latest}" == "${GO_VERSION}" ]]; then
        printf '%-24s %-30s up to date\n' GO_VERSION "${GO_VERSION}"
    else
        printf '%-24s %-30s -> %s\n' GO_VERSION "${GO_VERSION}" "${go_latest}"
    fi
}

# Homebrew 6 runs `sudo --reset-timestamp` as unconditional preamble on every
# brew invocation (Library/Homebrew/brew.sh), and sudo's default timestamp_type
# is `tty` — one record per terminal — so each brew command destroys the very
# record this script authenticated. A background refresher cannot repair that:
# `sudo -n true` is non-interactive by definition and the record is gone, not
# stale. That is why an --upgrade run asked for the password four times.
#
# An askpass helper is the way out. sudo runs it instead of prompting when given
# -A, and Homebrew opts in on its own — system_command.rb adds -A whenever
# SUDO_ASKPASS is set — so reading the password once up front covers both this
# script's sudo calls and the ones brew makes internally for pkg-based casks.
#
# The cost is that the password sits in a file for the length of the run. It
# goes in a mode-0700 directory under $TMPDIR (per-user on macOS) as a mode-0600
# file and is removed on EXIT, so it is readable only by this user, who could
# read it from their own keychain anyway. A run killed with SIGKILL leaves it
# behind. Set DOTFILES_NO_ASKPASS=1 to skip all of this and take the prompts.
_SUDO_ASKPASS_DIR=""

start_sudo_askpass() {
    if [[ -n "${DOTFILES_NO_ASKPASS:-}" ]]; then
        return 0
    fi
    # Already root: nothing to authenticate.
    if ((EUID == 0)); then
        return 0
    fi
    # Nothing to read a password on (CI, a piped provisioning run): leave sudo
    # to prompt or fail on its own terms rather than blocking on a dead tty.
    if ! { : </dev/tty; } 2>/dev/null; then
        return 0
    fi

    local password=""
    log "Reading the sudo password once, so brew's timestamp reset cannot force a re-prompt"
    IFS= read -r -s -p "[install] Password: " password </dev/tty
    printf '\n' >&3
    if [[ -z "${password}" ]]; then
        log "No password given; falling back to prompting per step"
        return 0
    fi

    # Verify now rather than let a typo surface halfway through the run as a
    # helper quietly feeding the wrong password to every step.
    if ! printf '%s\n' "${password}" | command sudo -S -v 2>/dev/null; then
        password=""
        err "sudo authentication failed"
        exit 1
    fi

    _SUDO_ASKPASS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-askpass.XXXXXX")"
    chmod 700 "${_SUDO_ASKPASS_DIR}"
    local secret="${_SUDO_ASKPASS_DIR}/secret"
    local helper="${_SUDO_ASKPASS_DIR}/askpass"
    # Create both empty and lock them down before the password goes near them.
    : >"${secret}"
    chmod 600 "${secret}"
    printf '%s\n' "${password}" >"${secret}"
    password=""
    # The password lives in the data file rather than inside the script text, so
    # no shell quoting has to survive a round trip through it. The path comes
    # from mktemp and contains nothing needing quoting.
    : >"${helper}"
    chmod 700 "${helper}"
    printf '#!/bin/sh\nexec cat %s\n' "${secret}" >"${helper}"
    export SUDO_ASKPASS="${helper}"
}

stop_sudo_askpass() {
    if [[ -n "${_SUDO_ASKPASS_DIR}" ]]; then
        rm -rf "${_SUDO_ASKPASS_DIR}"
        _SUDO_ASKPASS_DIR=""
    fi
    unset SUDO_ASKPASS
}

# Shadowing sudo for this script only. A function is not inherited by the
# subprocesses brew and the vendor installers run — brew adds -A itself, and the
# vendor scripts are handled by not needing sudo at all — so this only has to
# cover the call sites in this file, and covers them without each one having to
# know whether a helper is in play. `command sudo` where the flag would be wrong
# (the keepalive's -n, which must never prompt).
sudo() {
    if [[ -n "${SUDO_ASKPASS:-}" ]]; then
        command sudo -A "$@"
    else
        command sudo "$@"
    fi
}

# sudo caches credentials for a short window (15 minutes by default, less on
# some configs) and a full install — especially the --upgrade path, which
# rebuilds tmux and re-downloads every toolchain — comfortably outruns it, so
# the password gets asked for again at each later sudo step. Authenticate once
# up front and refresh the timestamp from the background for as long as the
# script runs, which covers every step whose only problem is outlasting the
# cache. With an askpass helper in place the refresher is belt and braces: a
# reset timestamp costs a silent helper call rather than a prompt.
_SUDO_KEEPALIVE_PID=""

start_sudo_keepalive() {
    # Already root: nothing to cache, and `sudo -v` would be pointless.
    if ((EUID == 0)); then
        return
    fi
    if [[ -n "${SUDO_ASKPASS:-}" ]]; then
        log "Requesting sudo access (refreshed in the background; the askpass helper covers brew's timestamp resets)"
    else
        log "Requesting sudo access (refreshed in the background; steps that follow a brew command may re-prompt)"
    fi
    if ! sudo -v; then
        err "sudo authentication failed"
        exit 1
    fi
    local parent=$$
    # `kill -0` bounds the loop to the lifetime of the install even if the EXIT
    # trap never fires (SIGKILL, say), so no stray refresher is left behind.
    # `sudo -n true` never prompts, so a refresh that fails costs nothing and is
    # ignored rather than ending the loop: after a brew command has wiped the
    # timestamp, or under a sudoers config with timestamp_timeout=0, the next
    # step that authenticates by hand hands the credential back and the loop
    # carries it forward again. Breaking here instead retired the refresher for
    # the whole run at the first brew command, which is most of an --upgrade.
    while kill -0 "${parent}" 2>/dev/null; do
        command sudo -n true 2>/dev/null || true
        sleep 50
    done &
    _SUDO_KEEPALIVE_PID=$!
    # Suppress a "Terminated" job notice if the script is ever run with job
    # control on (sourced from an interactive shell); a plain `bash install.sh`
    # never prints one. Best-effort: macOS ships bash 3.2, where `disown` may
    # only accept a %jobspec rather than a bare pid, so failure is ignored.
    disown "${_SUDO_KEEPALIVE_PID}" 2>/dev/null || true
}

stop_sudo_keepalive() {
    if [[ -n "${_SUDO_KEEPALIVE_PID}" ]]; then
        kill "${_SUDO_KEEPALIVE_PID}" 2>/dev/null || true
        _SUDO_KEEPALIVE_PID=""
    fi
}

stop_sudo_helpers() {
    stop_sudo_keepalive
    stop_sudo_askpass
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --upgrade) UPGRADE=true ;;
            --all-optional) OPTIONAL_MODE=all ;;
            --no-optional) OPTIONAL_MODE=none ;;
            --reconfigure-optional) OPTIONAL_RECONFIGURE=true ;;
            --verbose) VERBOSE=true ;;
            *)
                err "Unknown argument: ${arg}. Usage: $0 [--upgrade] [--all-optional|--no-optional] [--reconfigure-optional] [--verbose]"
                exit 1
                ;;
        esac
    done
}

# Optional tools: everything else here installs everywhere, but a few tools only
# make sense on a machine that is actually sat in front of (a GUI app, say) and
# are pure noise on a server that only ever gets ssh'd into. Rather than
# hardcoding that split — hostnames churn and a headless check only catches the
# Linux GUI case — ask once, then remember the answer in a state file so every
# later run, including --upgrade, stays non-interactive.
OPTIONAL_MODE=""
OPTIONAL_RECONFIGURE=""
OPTIONAL_STATE_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/dotfiles/optional-tools.conf"

# Answers are stored one per line as `name=yes|no`. Returns 0 if the tool should
# be installed. $1 is the key, $2 a one-line description shown in the prompt.
optional_enabled() {
    local name="$1" description="$2"

    case "${OPTIONAL_MODE}" in
        all) return 0 ;;
        none) return 1 ;;
        *) ;; # unset: fall through to the recorded answer, or ask for one
    esac

    local recorded=""
    if [[ -z "${OPTIONAL_RECONFIGURE}" ]] && [[ -f "${OPTIONAL_STATE_FILE}" ]]; then
        local line
        line="$(grep -m1 "^${name}=" "${OPTIONAL_STATE_FILE}" 2>/dev/null || true)"
        recorded="${line#*=}"
    fi

    if [[ -z "${recorded}" ]]; then
        # Prefer /dev/tty over stdin: the platform scripts are routinely piped
        # (`curl ... | bash`), which leaves stdin as the script text itself.
        # `-r /dev/tty` is not a usable test — the device node is readable even
        # with no controlling terminal attached, where opening it fails — so
        # actually try to open it.
        local tty_ok=false
        if { : </dev/tty; } 2>/dev/null; then
            tty_ok=true
        fi
        # Nothing to ask on (CI, a provisioning run, a detached shell): decline
        # rather than block on a read that can never be answered, and leave it
        # unrecorded so a later interactive run still gets to ask.
        if [[ "${tty_ok}" == false ]] && [[ ! -t 0 ]]; then
            log "${name}: optional and no terminal to prompt on; skipping"
            return 1
        fi
        local reply=""
        printf "\033[1;35m[install]\033[0m %s\n" "${description}" >&3
        if [[ "${tty_ok}" == true ]]; then
            read -r -p "[install] Install ${name}? [y/N] " reply </dev/tty
        else
            read -r -p "[install] Install ${name}? [y/N] " reply
        fi
        case "${reply}" in
            [Yy]*) recorded=yes ;;
            *) recorded=no ;;
        esac
        optional_record "${name}" "${recorded}"
    fi

    [[ "${recorded}" == "yes" ]]
}

optional_record() {
    local name="$1" answer="$2"
    mkdir -p "$(dirname "${OPTIONAL_STATE_FILE}")"
    local tmp
    tmp="$(mktemp)"
    if [[ -f "${OPTIONAL_STATE_FILE}" ]]; then
        grep -v "^${name}=" "${OPTIONAL_STATE_FILE}" >"${tmp}" 2>/dev/null || true
    fi
    printf '%s=%s\n' "${name}" "${answer}" >>"${tmp}"
    mv "${tmp}" "${OPTIONAL_STATE_FILE}"
    log "Recorded ${name}=${answer} in ${OPTIONAL_STATE_FILE}"
}

# Wrapper mirroring run_step for tools behind an optional_enabled gate.
run_optional_step() {
    local name="$1" description="$2"
    shift 2
    if optional_enabled "${name}" "${description}"; then
        run_step "$@"
    fi
}

# Pin npm's global prefix to ~/.local rather than trusting `npm prefix -g`.
# Homebrew's node points that at the versioned keg (Cellar/node/<version>), so
# globals installed there are orphaned by the next `brew upgrade node` while
# stale copies left in /opt/homebrew/lib/node_modules keep winning on PATH.
# ~/.local is version-independent and user-writable, so no sudo fallback either.
npm_install_g() {
    npm config set prefix "${HOME}/.local" >/dev/null
    npm install -g "$@"
}

# Wrapper around curl for GitHub API calls; adds auth header when GITHUB_TOKEN is set
# to avoid unauthenticated rate limits (60 req/hr) on shared CI runner IPs.
# Same TLS floor as download(): these calls decide which version gets installed,
# so a downgrade to plaintext or to an obsolete TLS version matters here at
# least as much as on the fetch that follows.
github_api_curl() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
    else
        curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" "$@"
    fi
}

github_latest_tag() {
    local repo="$1"
    local tmp
    tmp="$(mktemp)"
    # RETURN traps persist for the caller too until unset, so clear it here
    # or it would also fire (and re-delete an unrelated tmp) when the caller returns.
    trap 'rm -f "${tmp}"; trap - RETURN' RETURN
    # Checked here rather than at each call site: a rate-limited or unreachable
    # API returns an empty tag, which the callers then paste into an asset URL
    # and download a 404 page with. Three of the ten guarded it, seven did not.
    if ! github_api_curl "https://api.github.com/repos/${repo}/releases/latest" -o "${tmp}"; then
        err "GitHub API request failed for ${repo}"
        return 1
    fi
    local tag_line tag
    tag_line="$(grep -m1 '"tag_name"' "${tmp}" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
    if [[ -z "${tag}" ]]; then
        err "No release tag for ${repo} in the GitHub API response"
        return 1
    fi
    echo "${tag}"
}

version_gte() {
    local current="$1" required="$2"
    local cur_major cur_minor cur_patch req_major req_minor req_patch
    IFS=. read -r cur_major cur_minor cur_patch <<<"${current}"
    IFS=. read -r req_major req_minor req_patch <<<"${required}"
    cur_major="${cur_major:-0}"
    cur_minor="${cur_minor:-0}"
    cur_patch="${cur_patch:-0}"
    req_major="${req_major:-0}"
    req_minor="${req_minor:-0}"
    req_patch="${req_patch:-0}"
    if ((cur_major > req_major)); then return 0; fi
    if ((cur_major < req_major)); then return 1; fi
    if ((cur_minor > req_minor)); then return 0; fi
    if ((cur_minor < req_minor)); then return 1; fi
    ((cur_patch >= req_patch))
}

# safe_git/ensure_user_owns exist because upgrade paths for git-cloned tools
# (zinit, fzf, tpm) have hit repos owned by root — e.g. from an earlier sudo
# or CI run — which makes plain git refuse ("dubious ownership") or fail to write.
safe_git() {
    local dir="$1"
    shift
    git -c "safe.directory=${dir}" -C "${dir}" "$@"
}

ensure_user_owns() {
    local dir="$1"
    if [[ -d "${dir}" ]] && [[ ! -O "${dir}" ]]; then
        local user group
        user="$(id -un)"
        group="$(id -gn)"
        sudo chown -R "${user}:${group}" "${dir}"
    fi
}

load_cargo_env() {
    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi
}

install_zinit() {
    local zinit_home="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
    if [[ -d "${zinit_home}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "zinit already installed; skipping"
            return
        fi
        log "Upgrading zinit"
        ensure_user_owns "${zinit_home}"
        safe_git "${zinit_home}" fetch origin || return 1
        safe_git "${zinit_home}" reset --hard origin/main
        return
    fi
    log "Installing zinit"
    mkdir -p "$(dirname "${zinit_home}")"
    git clone https://github.com/zdharma-continuum/zinit.git "${zinit_home}"
}

install_fzf_tab() {
    local fzf_tab_home="${XDG_DATA_HOME:-${HOME}/.local/share}/fzf-tab"
    if [[ -d "${fzf_tab_home}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "fzf-tab already installed; skipping"
            return
        fi
        log "Upgrading fzf-tab"
        ensure_user_owns "${fzf_tab_home}"
        safe_git "${fzf_tab_home}" fetch origin || return 1
        safe_git "${fzf_tab_home}" reset --hard origin/master
        return
    fi
    log "Installing fzf-tab"
    mkdir -p "$(dirname "${fzf_tab_home}")"
    git clone --depth 1 https://github.com/Aloxaf/fzf-tab.git "${fzf_tab_home}"
}

install_zsh_autosuggestions() {
    local autosuggest_home="${XDG_DATA_HOME:-${HOME}/.local/share}/zsh-autosuggestions"
    if [[ -d "${autosuggest_home}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "zsh-autosuggestions already installed; skipping"
            return
        fi
        log "Upgrading zsh-autosuggestions"
        ensure_user_owns "${autosuggest_home}"
        safe_git "${autosuggest_home}" fetch origin || return 1
        safe_git "${autosuggest_home}" reset --hard origin/master
        return
    fi
    log "Installing zsh-autosuggestions"
    mkdir -p "$(dirname "${autosuggest_home}")"
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git "${autosuggest_home}"
}

# True when some package already put a completion function for $1 somewhere
# zsh looks by default. Homebrew links one for most of its formulae; the same
# tool installed from a release tarball on Linux comes with nothing.
_zsh_completion_installed() {
    local dir
    for dir in /opt/homebrew/share/zsh/site-functions \
        /usr/local/share/zsh/site-functions \
        /usr/share/zsh/site-functions \
        /usr/share/zsh/vendor-completions; do
        [[ -e "${dir}/_$1" ]] && return 0
    done
    return 1
}

# Generate zsh completions for the tools that can print their own but ship it
# nowhere useful. Runs after every other install step, since it invokes each
# binary. The output goes to the user site-functions directory that
# home/dot_zshrc.tmpl prepends to fpath.
#
# A tool whose completion is already installed system-wide is skipped rather
# than shadowed, so a later `brew upgrade` keeps ownership of it. delta is the
# exception that motivated this: nothing ships a _delta, and zsh's bundled
# _sccs registers the name `delta` for SCCS, so without a generated one
# git-delta completes SCCS flags.
install_zsh_completions() {
    local comp_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/zsh/site-functions"
    local spec cmd args out generated=0

    mkdir -p "${comp_dir}"

    # "<command>|<arguments that print a zsh completion script>"
    for spec in \
        "uv|generate-shell-completion zsh" \
        "uvx|--generate-shell-completion zsh" \
        "fd|--gen-completions zsh" \
        "delta|--generate-completion zsh" \
        "rustup|completions zsh" \
        "atuin|gen-completions --shell zsh" \
        "chezmoi|completion zsh"; do
        cmd="${spec%%|*}"
        args="${spec#*|}"

        command -v "${cmd}" >/dev/null 2>&1 || continue
        _zsh_completion_installed "${cmd}" && continue

        # Via a temporary file: a generator that fails half way would otherwise
        # leave a truncated function that breaks completion for that command
        # until the next run.
        out="${comp_dir}/_${cmd}"
        # shellcheck disable=SC2086  # args is a deliberate word-split argv
        if "${cmd}" ${args} >"${out}.tmp" 2>/dev/null && [[ -s "${out}.tmp" ]]; then
            mv -f "${out}.tmp" "${out}"
            generated=$((generated + 1))
        else
            rm -f "${out}.tmp"
            log "Could not generate zsh completion for ${cmd}; skipping"
        fi
    done

    log "Generated ${generated} zsh completion function(s) in ${comp_dir}"

    # compinit caches the command-to-function map in the dump and rereads fpath
    # only when the dump is stale. Drop it so the next shell picks the new
    # functions up instead of waiting out the 24-hour timer in .zshrc.
    rm -f "${ZDOTDIR:-${HOME}}/.zcompdump" "${ZDOTDIR:-${HOME}}/.zcompdump.zwc"
}

install_rust() {
    load_cargo_env
    if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Rust already installed; skipping"
            return
        fi
        log "Upgrading Rust"
        rustup update
        return
    fi
    log "Installing Rust"
    local script_path
    script_path="$(mktemp)"
    download https://sh.rustup.rs "${script_path}" || return 1
    sh "${script_path}" -y || return 1
    rm -f "${script_path}"

    load_cargo_env
}

install_rust_analyzer() {
    load_cargo_env
    if command -v rust-analyzer >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "rust-analyzer already installed; skipping"
            return
        fi
        log "Upgrading rust-analyzer"
    else
        log "Installing rust-analyzer"
    fi
    require_cmd rustup
    rustup component add rust-analyzer
}

install_btop() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if command -v btop >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "btop already installed; skipping"
                return
            fi
            log "Upgrading btop"
            brew upgrade btop
            return
        fi
        log "Installing btop"
        brew install btop
        return
    fi

    # Linux: build from source, because neither packaged option can show GPU
    # metrics. apt (jammy/universe) is pinned at 1.2.3, which predates GPU
    # monitoring entirely (added in 1.3.0). The upstream release binaries are
    # newer but built STATIC=true, and btop's Makefile force-disables
    # GPU_SUPPORT for static builds since the NVIDIA/AMD backends dlopen their
    # vendor libraries. A stock source build turns GPU_SUPPORT on by default on
    # linux/x86_64 and resolves libnvidia-ml.so at runtime, so it needs no CUDA
    # toolkit at build time -- just the driver already being present.
    #
    local version="${BTOP_VERSION}"

    # ~/.local/bin is appended after /usr/bin on PATH, so a leftover apt btop
    # would shadow the binary installed below.
    if dpkg -s btop >/dev/null 2>&1; then
        log "Removing apt btop (predates GPU support, and shadows ~/.local/bin)"
        sudo apt-get purge -y btop
    fi

    if command -v btop >/dev/null 2>&1; then
        # Matched out of the output rather than cut from a field, because
        # `btop --version` wraps the number in bold (`btop version: ^[[1m1.4.4`),
        # prints two more lines of compiler and make flags after it, and — built
        # from the clone below — appends the commit it was built from,
        # `1.4.4+0f398ab`, which the tarball builds this step used to make had no
        # .git to produce. A field-splitting read picks up the escape and the
        # suffix, so `--upgrade` never matched the pinned version and rebuilt
        # every run.
        local current raw
        raw="$(btop --version 2>/dev/null)" || raw=""
        current=""
        if [[ "${raw}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            current="${BASH_REMATCH[1]}"
        fi
        if [[ -z "${UPGRADE:-}" ]]; then
            log "btop ${current} already installed; skipping"
            return
        fi
        if [[ "${current}" == "${version}" ]]; then
            log "btop ${current} already at pinned version; skipping"
            return
        fi
        log "Upgrading btop to ${version}"
    else
        log "Installing btop ${version}"
    fi

    local tmp_dir src_dir
    tmp_dir="$(mktemp -d)"
    src_dir="${tmp_dir}/btop"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    # A shallow clone of the tag, rather than the release tarball this used to
    # fetch. codeload.github.com — the host every /archive/refs/tags/ URL
    # redirects to — rate-limits by source address and answers 429 to
    # unauthenticated requests from a busy or NAT'd one; a 17 August 2026 install
    # got 429 on all six attempts while api.github.com, release assets and git
    # itself were all serving this machine normally. Cloning takes the git
    # endpoint instead, which is not on that budget, and --depth 1 fetches the
    # same one commit the tarball held.
    if ! git clone --quiet --depth 1 --branch "v${version}" \
        https://github.com/aristocratos/btop.git "${src_dir}"; then
        err "Failed to clone btop v${version}"
        return 1
    fi
    # Build with a pruned PATH and an explicit CXX. If nix is on PATH its
    # binutils/glibc get picked up alongside the system g++, and the link fails
    # on __isoc23_* symbols that the older system glibc does not export.
    local jobs
    jobs="$(cpu_count)"
    env PATH=/usr/local/bin:/usr/bin:/bin CXX=/usr/bin/g++ \
        make -C "${src_dir}" -j"${jobs}" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${src_dir}/bin/btop" "${HOME}/.local/bin/btop" || return 1
    # The apt package supplied themes via /usr/share/btop/themes, which the purge
    # above removes; ship them to the user theme dir so theme selection still works.
    mkdir -p "${HOME}/.config/btop/themes"
    install -m644 "${src_dir}"/themes/*.theme "${HOME}/.config/btop/themes/"
}

install_jq() {
    if command -v jq >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "jq already installed; skipping"
            return
        fi
        log "Upgrading jq"
        local os_name
        os_name="$(uname -s)"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade jq
        else
            sudo apt-get install -y jq
        fi
        return
    fi
    log "Installing jq"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install jq
    else
        sudo apt-get install -y jq
    fi
}

# apt splits zstd across two packages: `zstd` is the CLI (which GNU tar shells
# out to for .tar.zst) and `libzstd-dev` the headers, so cargo/cc builds link
# the system copy instead of vendoring their own. Ubuntu images often ship the
# CLI already, so the guard checks for the dev package too or the headers never
# land. brew's single formula covers both.
install_zstd() {
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        if command -v zstd >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "zstd already installed; skipping"
                return
            fi
            log "Upgrading zstd"
            brew upgrade zstd
            return
        fi
        log "Installing zstd"
        brew install zstd
        return
    fi
    if command -v zstd >/dev/null 2>&1 && dpkg -s libzstd-dev >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "zstd already installed; skipping"
            return
        fi
        log "Upgrading zstd"
    else
        log "Installing zstd"
    fi
    sudo apt-get install -y zstd libzstd-dev
}

install_clangd() {
    if command -v clangd >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "clangd already installed; skipping"
            return
        fi
        log "Upgrading clangd"
        local os_name
        os_name="$(uname -s)"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade llvm
        else
            sudo apt-get install -y clangd
        fi
        return
    fi
    log "Installing clangd"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install llvm
    else
        sudo apt-get install -y clangd
    fi
}

install_cmake() {
    local required_version="${CMAKE_VERSION#v}"
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if [[ -z "${UPGRADE:-}" ]] && command -v cmake >/dev/null 2>&1; then
            local cmake_output current_version
            cmake_output="$(cmake --version)"
            current_version="$(awk 'NR==1{print $3}' <<<"${cmake_output}")"
            if version_gte "${current_version}" "${required_version}"; then
                log "cmake ${current_version} already satisfies >= ${required_version}; skipping"
                return
            fi
            log "cmake ${current_version} < ${required_version}; upgrading"
        elif [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading cmake"
        else
            log "Installing cmake"
        fi
        if brew list --formula cmake >/dev/null 2>&1; then
            brew upgrade cmake
        else
            brew install cmake
        fi
        return
    fi

    # Linux: binary download
    local install_version
    if [[ -n "${UPGRADE:-}" ]]; then
        local latest_tag
        latest_tag="$(github_latest_tag Kitware/CMake)" || return 1
        install_version="${latest_tag#v}"
        if command -v cmake >/dev/null 2>&1; then
            local cmake_output current_version
            cmake_output="$(cmake --version)"
            current_version="$(awk 'NR==1{print $3}' <<<"${cmake_output}")"
            if [[ "${current_version}" == "${install_version}" ]]; then
                log "cmake ${current_version} already at latest; skipping"
                return
            fi
        fi
        log "Upgrading cmake to ${install_version}"
    else
        install_version="${required_version}"
        if command -v cmake >/dev/null 2>&1; then
            local cmake_output current_version
            cmake_output="$(cmake --version)"
            current_version="$(awk 'NR==1{print $3}' <<<"${cmake_output}")"
            if version_gte "${current_version}" "${required_version}"; then
                log "cmake ${current_version} already satisfies >= ${required_version}; skipping"
                return
            fi
            log "cmake ${current_version} < ${required_version}; installing ${install_version}"
        else
            log "Installing cmake ${install_version}"
        fi
    fi

    local os_arch cmake_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        cmake_arch="linux-aarch64"
    else
        cmake_arch="linux-x86_64"
    fi
    local installer="cmake-${install_version}-${cmake_arch}.sh"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    local cmake_base="https://github.com/Kitware/CMake/releases/download/v${install_version}"
    download_verified "${cmake_base}/${installer}" "${tmp_dir}/${installer}" \
        "${cmake_base}/cmake-${install_version}-SHA-256.txt" || return 1
    chmod +x "${tmp_dir}/${installer}"
    sudo sh "${tmp_dir}/${installer}" --prefix=/usr/local --skip-license
}

# The seven tools routed through install_cargo_tool were compiled from source
# until August 2026. On the CI runner that cost 5m21s of a 7m36s install run —
# eza 67s, bat 79s, delta 75s, fd 36s, rg 22s, hyperfine 22s, zoxide 20s — and
# the same wait lands on any new machine. All seven publish prebuilt binaries
# on their GitHub releases, so the tarball is fetched instead and cargo is
# kept only as the fallback.
#
# The release assets agree on nothing. eza leaves the version out of the file
# name entirely; fd, bat and hyperfine keep the tag's leading `v`; ripgrep,
# delta and zoxide strip it. Some unpack a bare binary, others a versioned
# directory. So the name is per-tool data — %TAG% is the tag as published,
# %VER% the same with any leading `v` removed, %TRIPLE% the Rust target triple
# — and the binary is found by searching the unpacked tree rather than by a
# path that would have to be spelled out seven different ways.
#
# The triple list is that tool's platform coverage: only triples upstream
# actually publishes are named, so a platform absent from the list falls back
# to `cargo install`. eza is the one that does, shipping no macOS asset at all.
#
# Five fields, pipe-separated:
#   <repo>|<asset template>|<published triples>|<checksum template>|<pinned tag>
# The checksum template is empty for the upstreams that publish none, which is
# most of them; %ASSET% in it stands for the asset name already expanded.
_rust_tool_spec() {
    case "$1" in
        eza) echo "eza-community/eza|eza_%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-gnu||${EZA_VERSION}" ;;
        fd) echo "sharkdp/fd|fd-%TAG%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin||${FD_VERSION}" ;;
        bat) echo "sharkdp/bat|bat-%TAG%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin||${BAT_VERSION}" ;;
        rg) echo "BurntSushi/ripgrep|ripgrep-%VER%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin|%ASSET%.sha256|${RIPGREP_VERSION}" ;;
        delta) echo "dandavison/delta|delta-%VER%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-gnu aarch64-apple-darwin||${DELTA_VERSION}" ;;
        hyperfine) echo "sharkdp/hyperfine|hyperfine-%TAG%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-gnu aarch64-apple-darwin||${HYPERFINE_VERSION}" ;;
        zoxide) echo "ajeetdsouza/zoxide|zoxide-%VER%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin||${ZOXIDE_VERSION}" ;;
        difft) echo "Wilfred/difftastic|difft-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-gnu aarch64-apple-darwin x86_64-apple-darwin||${DIFFTASTIC_VERSION}" ;;
        sccache) echo "mozilla/sccache|sccache-%TAG%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin|%ASSET%.sha256|${SCCACHE_VERSION}" ;;
        # Upstream publishes one fat macOS binary rather than a per-arch pair,
        # which is why universal-apple-darwin is in the triple list at all.
        cargo-nextest) echo "nextest-rs/nextest|%TAG%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl aarch64-unknown-linux-musl universal-apple-darwin|%TAG%-%TRIPLE%.sha256|${CARGO_NEXTEST_VERSION}" ;;
        # No aarch64 asset for either platform, so an ARM machine takes the
        # cargo fallback; git-absorb is a small crate and builds in seconds.
        git-absorb) echo "tummychow/git-absorb|git-absorb-%VER%-%TRIPLE%.tar.gz|x86_64-unknown-linux-musl x86_64-apple-darwin||${GIT_ABSORB_VERSION}" ;;
        *) return 1 ;;
    esac
}

# Target triples for this machine, best first. musl leads gnu wherever a tool
# offers both, for the reason install_atuin sets out at length: upstream builds
# the gnu binaries against a newer glibc than the oldest distro here ships, and
# they die at the dynamic linker before main() runs. None of these tools is
# allocator-bound, so the static build costs nothing that matters.
_rust_tool_triples() {
    local os_name arch
    os_name="$(uname -s)"
    arch="$(uname -m)"
    case "${os_name}/${arch}" in
        Linux/x86_64 | Linux/amd64) echo "x86_64-unknown-linux-musl x86_64-unknown-linux-gnu" ;;
        Linux/aarch64 | Linux/arm64) echo "aarch64-unknown-linux-musl aarch64-unknown-linux-gnu" ;;
        Darwin/arm64 | Darwin/aarch64) echo "aarch64-apple-darwin universal-apple-darwin" ;;
        Darwin/x86_64) echo "x86_64-apple-darwin universal-apple-darwin" ;;
        *) echo "" ;;
    esac
}

# First release-asset version number in `<tool> --version` output. Matched with
# a regex rather than by field, because the seven disagree there too: eza
# prints a bare `v0.23.5`, rg and eza print several lines, and some wrap the
# number in escape sequences. This is the same read install_btop makes.
_rust_tool_version() {
    local output
    output="$("$1" --version 2>/dev/null)" || return 1
    [[ "${output}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

_install_rust_tool_binary() {
    local cmd="$1" repo="$2" template="$3" triple="$4" sum_template="$5" pin="$6"

    local tag version
    tag="$(pinned_tag "${pin}" "${repo}")" || return 1
    # nextest-rs tags the crate name into the tag (`cargo-nextest-0.9.143`), so
    # strip that as well as a leading `v` before comparing against what the
    # installed binary reports.
    version="${tag#v}"
    version="${version#"${cmd}-"}"
    if [[ -z "${version}" ]]; then
        err "Could not resolve the ${cmd} release to install"
        return 1
    fi

    if [[ -n "${UPGRADE:-}" ]] && command -v "${cmd}" >/dev/null 2>&1; then
        local current
        current="$(_rust_tool_version "${cmd}")" || current=""
        if [[ "${current}" == "${version}" ]]; then
            log "${cmd} ${current} already at latest; skipping"
            return
        fi
    fi

    local asset="${template}"
    asset="${asset//%TAG%/${tag}}"
    asset="${asset//%VER%/${version}}"
    asset="${asset//%TRIPLE%/${triple}}"

    local base_url="https://github.com/${repo}/releases/download/${tag}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    if [[ -n "${sum_template}" ]]; then
        local sum_asset="${sum_template}"
        sum_asset="${sum_asset//%ASSET%/${asset}}"
        sum_asset="${sum_asset//%TAG%/${tag}}"
        sum_asset="${sum_asset//%VER%/${version}}"
        sum_asset="${sum_asset//%TRIPLE%/${triple}}"
        download_verified "${base_url}/${asset}" "${tmp_dir}/${asset}" \
            "${base_url}/${sum_asset}" || return 1
    else
        download "${base_url}/${asset}" "${tmp_dir}/${asset}" || return 1
    fi
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${asset}" || return 1

    # Located by name, since the tarballs disagree on whether the binary sits
    # at the root or inside a versioned directory. -type f keeps it off the
    # completion and man directories several of them ship alongside.
    local binary
    binary="$(find "${tmp_dir}" -type f -name "${cmd}" -print -quit)"
    if [[ -z "${binary}" ]]; then
        err "No ${cmd} binary inside ${asset}"
        return 1
    fi
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${binary}" "${HOME}/.local/bin/${cmd}" || return 1

    # Several of these tarballs carry a completions/ directory, and for a tool
    # with no "print your own completion" subcommand that archive is the only
    # source there is: install_zsh_completions can generate for uv, fd, delta
    # and the rest, but zoxide 0.9.9 has no such subcommand, so on Linux — where
    # these arrive as bare binaries with no package manager to link a
    # site-functions file — `zoxide <TAB>` completed nothing at all. Homebrew
    # links one on macOS, which is why the gap only shows on the other platform.
    # Skipped where a system-wide copy already exists, so the package manager
    # keeps ownership, matching the policy install_zsh_completions follows.
    local completion
    completion="$(find "${tmp_dir}" -type f -name "_${cmd}" -print -quit)"
    if [[ -n "${completion}" ]] && ! _zsh_completion_installed "${cmd}"; then
        local comp_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/zsh/site-functions"
        mkdir -p "${comp_dir}"
        if install -m644 "${completion}" "${comp_dir}/_${cmd}"; then
            log "Installed the zsh completion shipped with ${cmd}"
            # compinit caches the command-to-function map in the dump and only
            # rereads fpath when the dump is stale, so drop it. Cheap, and this
            # step does not always run before install_zsh_completions, which
            # does the same at the end of a full run.
            rm -f "${ZDOTDIR:-${HOME}}/.zcompdump" "${ZDOTDIR:-${HOME}}/.zcompdump.zwc"
        fi
    fi

    # Delete the build this function left behind before it moved to prebuilt
    # binaries. ~/.local/bin leads ~/.cargo/bin in the rendered zshrc so the new
    # copy would win there anyway, but verify-install.sh searches the two the
    # other way round, and a stale build answering for the tool on every check
    # is exactly the shadowing install_starship had to unpick for /usr/local.
    rm -f "${HOME}/.cargo/bin/${cmd}"
}

_install_cargo_tool_from_source() {
    local crate="$1"
    load_cargo_env
    require_cmd cargo
    # --locked builds against the dependency versions the crate was published
    # with, taken from the Cargo.lock it ships, rather than re-resolving every
    # dependency to the newest semver-compatible release. eza is what made this
    # necessary. It pins `palette = "=0.7.5"`, palette itself takes
    # `palette_derive = "0.7"`, and an unlocked resolve therefore pairs the 0.7.5
    # library with the 0.7.7 derive macro. That macro generates references to
    # `crate::lms` and `xyz::meta`, modules which only exist from 0.7.6, so the
    # build dies with 34 E0433s and takes the step with it. Every CI install job
    # between 13 and 18 August 2026 failed there. The shipped lockfile pairs
    # 0.7.5 with palette_derive 0.7.6, and `cargo install eza --locked` then
    # builds in 43s. All six crates installed through here ship a Cargo.lock,
    # which is what --locked needs.
    cargo install --locked "${crate}"
}

install_cargo_tool() {
    local cmd="$1" crate="${2:-$1}"

    local repo="" template="" published="" sum_template="" pin="" triple=""
    local spec
    if spec="$(_rust_tool_spec "${cmd}")"; then
        IFS='|' read -r repo template published sum_template pin <<<"${spec}"

        local candidates candidate triple_list
        triple_list="$(_rust_tool_triples)"
        read -r -a candidates <<<"${triple_list}"
        for candidate in "${candidates[@]}"; do
            if [[ " ${published} " == *" ${candidate} "* ]]; then
                triple="${candidate}"
                break
            fi
        done
    fi

    # The skip check comes before github_latest_tag, so an already-installed
    # tool costs no API call. install_atuin and install_treehouse still resolve
    # the tag first and pay for it on every run.
    local existing
    existing="$(command -v "${cmd}" 2>/dev/null)" || existing=""
    if [[ -n "${existing}" && -z "${UPGRADE:-}" ]]; then
        if [[ -z "${triple}" || "${existing}" != "${HOME}/.cargo/bin/"* ]]; then
            log "${cmd} already installed; skipping"
            return
        fi
        log "Replacing cargo-built ${cmd} with the prebuilt binary"
    elif [[ -n "${existing}" ]]; then
        log "Upgrading ${cmd}"
    else
        log "Installing ${cmd}"
    fi

    if [[ -z "${triple}" ]]; then
        _install_cargo_tool_from_source "${crate}"
        return
    fi
    _install_rust_tool_binary "${cmd}" "${repo}" "${template}" "${triple}" \
        "${sum_template}" "${pin}"
}

install_pyright() {
    if command -v pyright >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "pyright already installed; skipping"
            return
        fi
        log "Upgrading pyright"
    else
        log "Installing pyright"
    fi
    require_cmd npm
    npm_install_g pyright
}

install_eza() { install_cargo_tool eza; }
install_fd() { install_cargo_tool fd fd-find; }
install_bat() { install_cargo_tool bat; }
install_ripgrep() { install_cargo_tool rg ripgrep; }
install_git_delta() { install_cargo_tool delta git-delta; }
install_hyperfine() { install_cargo_tool hyperfine; }

install_gh() {
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        if command -v gh >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "GitHub CLI already installed; skipping"
                return
            fi
            log "Upgrading GitHub CLI"
            brew upgrade gh
            return
        fi
        log "Installing GitHub CLI"
        brew install gh
        return
    fi
    # Linux: install from GitHub's official apt repo — Ubuntu's `gh` package is
    # years out of date. Skip only when gh is present AND already sourced from
    # the official repo, so a gh first installed from Ubuntu's repos gets
    # migrated to the official one on the next run.
    if command -v gh >/dev/null 2>&1 &&
        [[ -f /etc/apt/sources.list.d/github-cli.list ]] &&
        [[ -z "${UPGRADE:-}" ]]; then
        log "GitHub CLI already installed; skipping"
        return
    fi
    log "Installing GitHub CLI from official apt repo"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    local tmp
    tmp="$(mktemp)"
    download https://cli.github.com/packages/githubcli-archive-keyring.gpg "${tmp}" || return 1
    sudo install -m 644 "${tmp}" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -f "${tmp}"
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    local arch
    arch="$(dpkg --print-architecture)"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y gh
}

# Both gh-stack steps hit the GitHub API — to resolve the extension's release
# and to read the skill's contents — so both need an authenticated gh. Nothing
# in these scripts runs `gh auth login`, and it cannot be automated, so on a
# freshly provisioned box the credential simply is not there yet. Skip with a
# warning rather than failing the run; the next install after the user has
# authenticated picks both up.
gh_authenticated() {
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

install_gh_stack() {
    if ! gh_authenticated; then
        log "gh is not authenticated; skipping gh-stack extension (run 'gh auth login', then re-run)"
        return
    fi
    # Match on the source repo rather than the extension name, so a same-named
    # extension from another owner is replaced rather than mistaken for this one.
    local extensions
    extensions="$(gh extension list 2>/dev/null)"
    if grep -q "github/gh-stack" <<<"${extensions}"; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "gh-stack extension already installed; skipping"
            return
        fi
        log "Upgrading gh-stack extension"
        gh extension upgrade gh-stack
        return
    fi
    log "Installing gh-stack extension"
    gh extension install github/gh-stack
}

install_gh_stack_skill() {
    if ! gh_authenticated; then
        log "gh is not authenticated; skipping gh-stack skill (run 'gh auth login', then re-run)"
        return
    fi
    # User scope, so the skill applies in every repo instead of only whichever
    # one the install happened to run from. It lands in ~/.claude/skills/gh-stack,
    # which chezmoi does not manage: nothing under home/dot_claude/ claims it.
    local skills
    skills="$(gh skill list --agent claude-code --scope user --json skillName --jq '.[].skillName' 2>/dev/null)"
    if grep -qx "gh-stack" <<<"${skills}"; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "gh-stack skill already installed; skipping"
            return
        fi
        log "Upgrading gh-stack skill"
        gh skill update gh-stack --all
        return
    fi
    log "Installing gh-stack skill for Claude Code"
    gh skill install github/gh-stack gh-stack --agent claude-code --scope user --force
}

install_zoxide() { install_cargo_tool zoxide; }

install_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "fzf already installed; skipping"
            return
        fi
        log "Upgrading fzf"
        if [[ -d "${HOME}/.fzf" ]]; then
            ensure_user_owns "${HOME}/.fzf"
            safe_git "${HOME}/.fzf" pull || return 1
            "${HOME}/.fzf/install" --bin --no-update-rc --no-bash --no-fish
        fi
        return
    fi
    log "Installing fzf"
    if [[ ! -d "${HOME}/.fzf" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git "${HOME}/.fzf"
    else
        log "fzf already cloned; skipping"
    fi
    "${HOME}/.fzf/install" --bin --no-update-rc --no-bash --no-fish
}

# atuin keeps shell history in its own SQLite database and syncs it one command
# record at a time, so two machines merge without the conflict a shared
# ~/.zsh_history file produces — that file only ever appends locally, so git or
# rsync sees two divergent tails and cannot reconcile them. Sync is end-to-end
# encrypted with a key held on the machine, so the server stores ciphertext.
install_atuin() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula atuin >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "atuin already installed; skipping"
                return
            fi
            log "Upgrading atuin"
            brew upgrade atuin
            return
        fi
        log "Installing atuin"
        brew install atuin
        return
    fi

    # Linux: official release tarball, which upstream ships for both arches.
    # The skip check comes first, so an install that has nothing to do costs no
    # network round trip -- and, under --upgrade, the pin resolves to whatever
    # upstream calls latest.
    if command -v atuin >/dev/null 2>&1 && [[ -z "${UPGRADE:-}" ]] &&
        atuin --version >/dev/null 2>&1; then
        log "atuin already installed; skipping"
        return
    fi

    local tag version
    tag="$(pinned_tag "${ATUIN_VERSION}" atuinsh/atuin)" || return 1
    version="${tag#v}"

    if command -v atuin >/dev/null 2>&1; then
        # Field 2, not $NF: `atuin --version` prints `atuin 18.19.0 ()`, with a
        # trailing git-hash field — empty on some builds, the commit on others —
        # that $NF would pick up instead of the version, making every --upgrade
        # re-download an already-current build.
        local version_output current
        version_output="$(atuin --version 2>/dev/null)" || version_output=""
        current="$(awk '{print $2}' <<<"${version_output}")"
        if [[ -z "${current}" ]]; then
            # An atuin that will not report its version is a broken install, not
            # a present one — the gnu tarball this step used to fetch dies at the
            # dynamic linker on any distro whose glibc predates the build host's.
            # Reinstall over it, since treating it as installed leaves the
            # machine skipping the step and the binary broken for ever.
            log "atuin present but not runnable; reinstalling ${version}"
        elif [[ -z "${UPGRADE:-}" ]]; then
            log "atuin ${current} already installed; skipping"
            return
        elif [[ "${current}" == "${version}" ]]; then
            log "atuin ${current} already at latest; skipping"
            return
        else
            log "Upgrading atuin to ${version}"
        fi
    else
        log "Installing atuin ${version}"
    fi

    # musl, not gnu. Upstream builds the gnu tarballs on a newer glibc than the
    # oldest target distro here ships — 18.19 needs GLIBC_2.38/2.39, jammy has
    # 2.35 — so the gnu binary exits at the dynamic linker with a `version
    # GLIBC_2.38 not found` before main() ever runs. The musl builds are static,
    # so they run on any of these machines; atuin's work is SQLite and a sync
    # request, neither of which the musl allocator is a bottleneck for.
    local arch triple
    arch="$(uname -m)"
    case "${arch}" in
        x86_64 | amd64) triple="x86_64-unknown-linux-musl" ;;
        aarch64 | arm64) triple="aarch64-unknown-linux-musl" ;;
        *)
            log "Unsupported arch ${arch} for atuin install; skipping"
            return
            ;;
    esac

    local tarball="atuin-${triple}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    local atuin_base="https://github.com/atuinsh/atuin/releases/download/${tag}"
    download_verified "${atuin_base}/${tarball}" "${tmp_dir}/${tarball}" \
        "${atuin_base}/${tarball}.sha256" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/atuin-${triple}/atuin" "${HOME}/.local/bin/atuin"
}

enable_nix_flakes() {
    local nix_conf="${HOME}/.config/nix/nix.conf"
    if [[ -f "${nix_conf}" ]] && grep -qE '^[[:space:]]*extra-experimental-features.*\bflakes\b|^[[:space:]]*experimental-features.*\bflakes\b' "${nix_conf}"; then
        return
    fi
    log "Enabling Nix flakes"
    mkdir -p "$(dirname "${nix_conf}")"
    echo "extra-experimental-features = nix-command flakes" >>"${nix_conf}"
}

source_nix_profile() {
    # shellcheck disable=SC1091
    [[ -f /etc/bashrc ]] && source /etc/bashrc
    # shellcheck disable=SC1091
    [[ -f "/etc/profile.d/nix.sh" ]] && source /etc/profile.d/nix.sh
}

# min-free/max-free/auto-optimise-store/extra-substituters etc. in
# ~/.config/nix/nix.conf are "restricted settings": the multi-user daemon
# silently ignores them from anyone not listed in /etc/nix/nix.conf's
# trusted-users (which defaults to root only), so grant the installing user
# trust to make the chezmoi-managed nix.conf actually take effect.
configure_nix_trusted_user() {
    local sys_conf="/etc/nix/nix.conf"
    local user
    user="$(whoami)"
    if [[ -f "${sys_conf}" ]] && grep -qE "^[[:space:]]*(extra-)?trusted-users[[:space:]]*=.*\b${user}\b" "${sys_conf}"; then
        return
    fi
    log "Adding ${user} to Nix trusted-users"
    echo "extra-trusted-users = ${user}" | sudo tee -a "${sys_conf}" >/dev/null
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        sudo launchctl kickstart -k system/org.nixos.nix-daemon
    else
        sudo systemctl restart nix-daemon
    fi
}

install_nix() {
    if command -v nix >/dev/null 2>&1 || [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
        # command -v may miss an existing install under non-login shells
        # (e.g. Ansible's command module), so re-source the profile scripts
        # to put nix on PATH for the rest of this script's execution.
        command -v nix >/dev/null 2>&1 || source_nix_profile
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Nix already installed; skipping"
            enable_nix_flakes
            configure_nix_trusted_user
            return
        fi
        log "Upgrading Nix"
        sudo -i nix upgrade-nix
        enable_nix_flakes
        configure_nix_trusted_user
        return
    fi
    log "Installing Nix"
    local script_path
    script_path="$(mktemp)"
    download https://nixos.org/nix/install "${script_path}" || return 1
    sh "${script_path}" --daemon --yes || return 1
    rm -f "${script_path}"

    source_nix_profile

    enable_nix_flakes
    configure_nix_trusted_user
}

install_direnv() {
    if command -v direnv >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "direnv already installed; skipping"
            return
        fi
        log "Upgrading direnv"
    else
        log "Installing direnv"
    fi
    mkdir -p "${HOME}/.local/bin"
    local script_path
    script_path="$(mktemp)"
    download https://direnv.net/install.sh "${script_path}" || return 1
    bin_path="${HOME}/.local/bin" bash "${script_path}" || return 1
    rm -f "${script_path}"
}

_nix_profile_has() {
    local list
    list="$(nix profile list 2>/dev/null)"
    grep -qE "^Flake attribute:[[:space:]]+legacyPackages\.[^.]+\.$1\$" <<<"${list}"
}

install_modern_bash() {
    # nix-direnv requires bash >= 4.4; macOS ships bash 3.2 (GPLv2-only) as /bin/bash.
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" != "Darwin" ]]; then
        return
    fi
    require_cmd nix
    if _nix_profile_has bash; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading bash"
            nix profile upgrade bash
        else
            log "Modern bash already installed; skipping"
        fi
        return
    fi
    log "Installing modern bash (nix-direnv requires >= 4.4)"
    nix profile install nixpkgs#bash
}

install_nix_direnv() {
    require_cmd nix
    install_modern_bash
    local direnvrc="${HOME}/.config/direnv/direnvrc"
    # shellcheck disable=SC2016
    local source_line='source $HOME/.nix-profile/share/nix-direnv/direnvrc'
    if _nix_profile_has nix-direnv; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "nix-direnv already installed; skipping"
        else
            log "Upgrading nix-direnv"
            nix profile upgrade nix-direnv
        fi
    else
        log "Installing nix-direnv"
        nix profile install nixpkgs#nix-direnv
    fi
    if [[ -f "${direnvrc}" ]] && grep -qF "nix-direnv/direnvrc" "${direnvrc}"; then
        return
    fi
    log "Wiring nix-direnv into direnvrc"
    mkdir -p "$(dirname "${direnvrc}")"
    echo "${source_line}" >>"${direnvrc}"
}

# The vendor installer defaults BIN_DIR to /usr/local/bin, which is root:wheel
# 0755 on macOS, so its `test_writable` fails and it runs `sudo -v` — a password
# prompt from a third-party script this one cannot reach into. Every other bare
# binary these scripts fetch already goes to ~/.local/bin, so send starship there
# too and the step needs no privileges at all.
STARSHIP_BIN_DIR="${HOME}/.local/bin"

install_starship() {
    if command -v starship >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Starship already installed; skipping"
            return
        fi
        log "Upgrading Starship"
    else
        log "Installing Starship"
    fi
    mkdir -p "${STARSHIP_BIN_DIR}"
    local script_path
    script_path="$(mktemp)"
    download https://starship.rs/install.sh "${script_path}" || return 1
    sh "${script_path}" -y -b "${STARSHIP_BIN_DIR}" || return 1
    rm -f "${script_path}"
    remove_shadowing_starship
}

# A copy left in the old location is dead weight at best. ~/.local/bin now leads
# /usr/local/bin in the rendered zshrc, but only for shells started since that
# change, and anything reading the system PATH still finds the stale one first —
# so the managed binary gets installed and then ignored, silently, for as long
# as the old one exists. Remove it once the new one is in place, and only then.
remove_shadowing_starship() {
    local stale="/usr/local/bin/starship"
    if [[ ! -e "${stale}" ]]; then
        return 0
    fi
    if [[ ! -x "${STARSHIP_BIN_DIR}/starship" ]]; then
        return 0
    fi
    log "Removing stale ${stale}, superseded by ${STARSHIP_BIN_DIR}/starship"
    sudo rm -f "${stale}" ||
        log "Could not remove ${stale}; it may still shadow the managed copy"
}

install_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Claude Code already installed; skipping"
            return
        fi
        log "Upgrading Claude Code"
        # Use the native updater, not npm -g: npm would install a second copy
        # under /usr/lib/node_modules that shadows the native one on PATH.
        claude update
        return
    fi
    log "Installing Claude Code"
    local script_path
    script_path="$(mktemp)"
    download https://claude.ai/install.sh "${script_path}" || return 1
    bash "${script_path}" || return 1
    rm -f "${script_path}"
}

install_rtk() {
    if command -v rtk >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "rtk already installed; skipping"
            return
        fi
        log "Upgrading rtk"
    else
        log "Installing rtk"
    fi
    local script_path
    script_path="$(mktemp)"
    download https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh "${script_path}" || return 1
    sh "${script_path}" || return 1
    rm -f "${script_path}"
}

install_uv() {
    if command -v uv >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "uv already installed; skipping"
            return
        fi
        log "Upgrading uv"
        uv self update
        return
    fi
    log "Installing uv"
    local script_path
    script_path="$(mktemp)"
    download https://astral.sh/uv/install.sh "${script_path}" || return 1
    sh "${script_path}" || return 1
    rm -f "${script_path}"
    export PATH="${HOME}/.local/bin:${PATH}"
}

install_ccusage() {
    require_cmd npm
    if command -v ccusage >/dev/null 2>&1; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading ccusage"
            npm_install_g ccusage
        else
            log "ccusage already installed; skipping"
        fi
    else
        log "Installing ccusage"
        npm_install_g ccusage
    fi
}

install_tmux_from_source() {
    local required_major=3 required_minor=3
    local build_version

    if [[ -n "${UPGRADE:-}" ]]; then
        build_version="$(github_latest_tag tmux/tmux)" || return 1
        if command -v tmux >/dev/null 2>&1; then
            local tmux_v_output tmux_v_word current_version
            tmux_v_output="$(tmux -V)"
            tmux_v_word="$(awk '{print $2}' <<<"${tmux_v_output}")"
            current_version="${tmux_v_word%%[[:alpha:]]*}"
            local latest_bare="${build_version#v}"
            if [[ "${tmux_v_word}" == "${latest_bare}" ]]; then
                log "tmux ${tmux_v_word} already at latest; skipping"
                return
            fi
            log "Upgrading tmux to ${build_version}"
        else
            log "Installing tmux ${build_version}"
        fi
    else
        build_version="${TMUX_VERSION}"
        if command -v tmux >/dev/null 2>&1; then
            local current_version
            local tmux_v_output tmux_v_word
            tmux_v_output="$(tmux -V)"
            tmux_v_word="$(awk '{print $2}' <<<"${tmux_v_output}")"
            current_version="${tmux_v_word%%[[:alpha:]]*}"
            local current_major current_minor
            current_major="$(echo "${current_version}" | cut -d. -f1)"
            current_minor="$(echo "${current_version}" | cut -d. -f2)"
            if ((current_major > required_major)) || ((current_major == required_major && current_minor >= required_minor)); then
                log "tmux ${current_version} already satisfies >= ${required_major}.${required_minor}; skipping"
                return
            fi
            log "tmux ${current_version} < ${required_major}.${required_minor}; building from source"
        else
            log "Installing tmux from source"
        fi
    fi

    local tarball="tmux-${build_version}.tar.gz"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "${build_dir}"; trap - RETURN' RETURN
    download "https://github.com/tmux/tmux/releases/download/${build_version}/${tarball}" \
        "${build_dir}/${tarball}" || return 1
    tar -C "${build_dir}" -xf "${build_dir}/${tarball}" || return 1
    local jobs
    jobs="$(cpu_count)"
    # configure and make run with a pruned PATH and an explicit CC, for the same
    # reason install_btop does. direnv activates this repo's own flake for anyone
    # running the installer from a shell sat in it, and pkgs.mkShell puts
    # stdenv's gcc wrapper on PATH ahead of /usr/bin. That wrapper searches
    # /nix/store alone for headers, so the header check fails against a
    # /usr/include/event2/event.h it cannot see and configure stops at "libevent
    # not found" — one line after /usr/bin/pkg-config reported libevent_core
    # present, since pkg-config is the system one and needs no -I for it.
    local build_env=(env PATH=/usr/local/bin:/usr/bin:/bin CC=/usr/bin/gcc)
    (
        cd "${build_dir}/tmux-${build_version}" &&
            "${build_env[@]}" ./configure &&
            "${build_env[@]}" make -j"${jobs}" &&
            sudo make install
    )
}

install_tmux_plugins() {
    require_cmd git
    local tpm_dir="${HOME}/.tmux/plugins/tpm"
    if [[ -d "${tpm_dir}" ]]; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading tmux plugin manager (tpm)"
            ensure_user_owns "${tpm_dir}"
            safe_git "${tpm_dir}" fetch origin || return 1
            safe_git "${tpm_dir}" reset --hard origin/master
        else
            log "tmux plugin manager (tpm) already installed; skipping"
        fi
    else
        log "Installing tmux plugin manager (tpm)"
        mkdir -p "${HOME}/.tmux/plugins"
        git clone https://github.com/tmux-plugins/tpm "${tpm_dir}" || return 1
    fi

    # Cloning tpm installs no plugin: tpm's own binding does that, and nothing
    # here ever pressed it, so every machine had ~/.tmux/plugins holding tpm
    # alone and tmux-sensible's settings were never applied. install_plugins
    # reads the @plugin lines out of the tmux config and is a no-op once they
    # are all cloned, so it can run on every install. It needs no server and
    # skips tpm itself.
    #
    # It does need a tmux.conf that sources tpm, though: it reads
    # TMUX_PLUGIN_MANAGER_PATH out of the running config and aborts with
    # "Tmux Plugin Manager not configured in tmux.conf" when there is none.
    # The install scripts run before `chezmoi apply`, so on a fresh machine
    # ~/.tmux.conf does not exist yet and there are no @plugin lines to act
    # on — which is what failed CI run 33694339533. Skipping is the whole
    # answer: with no config there is nothing to install, and the next run
    # after chezmoi apply picks the plugins up.
    if [[ ! -x "${tpm_dir}/bin/install_plugins" ]]; then
        return
    fi
    if ! grep -qs "tpm/tpm" "${HOME}/.tmux.conf"; then
        log "No ~/.tmux.conf sourcing tpm yet; skipping plugin install (re-run after chezmoi apply)"
        return
    fi
    log "Installing tmux plugins"
    "${tpm_dir}/bin/install_plugins" || return 1
}

install_wezterm() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "WezTerm: no display session detected; skipping on headless Linux"
        return
    fi

    if command -v wezterm >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "WezTerm already installed; skipping"
            return
        fi
        log "Upgrading WezTerm"
        if [[ "${os_name}" == "Darwin" ]]; then
            # wezterm@nightly's cask upstream occasionally ships a broken source
            # glob; a failed upgrade reverts to the existing working install, so
            # treat it as best-effort rather than failing the whole run.
            if ! brew upgrade --cask wezterm@nightly; then
                log "WezTerm nightly upgrade failed (likely upstream cask bug); keeping existing install; skipping"
            fi
            return
        fi
        # Linux: fall through to re-download latest
    else
        log "Installing WezTerm"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install --cask wezterm@nightly
            return
        fi
    fi

    # Linux binary download, tracking the rolling `nightly` tag rather than the
    # newest tagged release. WezTerm has cut no release since 20240203 (February
    # 2024), so `releases/latest` pinned Linux to a build two and a half years
    # behind the wezterm@nightly cask that macOS installs. The nightly tag name
    # never changes; its assets are rebuilt from the tip of main.
    local os_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" != "x86_64" ]]; then
        # arm64 nightly debs are published but lag the x86_64 ones by months,
        # so there is nothing worth tracking on that architecture yet.
        log "WezTerm: no official binary for ${os_arch}; skipping"
        return
    fi
    local ubuntu_version version_id_line
    version_id_line="$(grep -m1 '^VERSION_ID=' /etc/os-release || true)"
    ubuntu_version="${version_id_line#VERSION_ID=}"
    ubuntu_version="${ubuntu_version//\"/}"
    # Nightly publishes 20.04, 22.04, 24.04 and 26.04 packages. Anything else
    # falls back to 22.04, which runs on newer Ubuntu.
    case "${ubuntu_version}" in
        20.04 | 22.04 | 24.04 | 26.04) ;;
        *) ubuntu_version="22.04" ;;
    esac
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    # No "already at latest" check: the tag is fixed, so the installed version
    # string can never match it, and a nightly moves most days in any case. This
    # only runs when UPGRADE is set, since an existing install returns above.
    local deb="wezterm-nightly.Ubuntu${ubuntu_version}.deb"
    local wezterm_base="https://github.com/wezterm/wezterm/releases/download/nightly"
    download_verified "${wezterm_base}/${deb}" "${tmp_dir}/${deb}" \
        "${wezterm_base}/${deb}.sha256" || return 1
    sudo apt-get install -y "${tmp_dir}/${deb}"
}

install_nerd_font() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "CodeNewRoman Nerd Font: no display session detected; skipping on headless Linux"
        return
    fi

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask font-code-new-roman-nerd-font >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "CodeNewRoman Nerd Font already installed; skipping"
                return
            fi
            log "Upgrading CodeNewRoman Nerd Font"
            brew upgrade --cask font-code-new-roman-nerd-font
            return
        fi
        log "Installing CodeNewRoman Nerd Font"
        brew install --cask font-code-new-roman-nerd-font
        return
    fi

    # Linux: no cask equivalent; download the patched font from nerd-fonts releases
    require_cmd unzip
    local font_dir="${HOME}/.local/share/fonts/CodeNewRomanNerdFont"
    local version_file="${font_dir}/.version"
    if [[ -d "${font_dir}" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "CodeNewRoman Nerd Font already installed; skipping"
            return
        fi
        log "Upgrading CodeNewRoman Nerd Font"
    else
        log "Installing CodeNewRoman Nerd Font"
    fi
    local tag
    tag="$(pinned_tag "${NERD_FONTS_VERSION}" ryanoasis/nerd-fonts)" || return 1
    if [[ -n "${UPGRADE:-}" ]] && [[ -f "${version_file}" ]]; then
        local installed_tag
        installed_tag="$(cat "${version_file}")"
        if [[ "${installed_tag}" == "${tag}" ]]; then
            log "CodeNewRoman Nerd Font ${tag} already at latest; skipping"
            return
        fi
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    local nerd_base="https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}"
    download_verified "${nerd_base}/CodeNewRoman.zip" "${tmp_dir}/CodeNewRoman.zip" \
        "${nerd_base}/SHA-256.txt" || return 1
    mkdir -p "${font_dir}"
    unzip -oq "${tmp_dir}/CodeNewRoman.zip" -d "${font_dir}" || return 1
    echo "${tag}" >"${version_file}"
    fc-cache -f "${font_dir}" >/dev/null 2>&1 || true
}

install_tailscale() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask tailscale >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Tailscale already installed; skipping"
                return
            fi
            log "Upgrading Tailscale"
            brew upgrade --cask tailscale
            return
        fi
        log "Installing Tailscale"
        brew install --cask tailscale
        return
    fi

    if command -v tailscale >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Tailscale already installed; skipping"
            return
        fi
        log "Upgrading Tailscale"
    else
        log "Installing Tailscale"
    fi
    local script_path
    script_path="$(mktemp)"
    download https://tailscale.com/install.sh "${script_path}" || return 1
    sh "${script_path}" || return 1
    rm -f "${script_path}"
}

install_lua_ls() {
    local os_name
    os_name="$(uname -s)"

    if command -v lua-language-server >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "lua-language-server already installed; skipping"
            return
        fi
        log "Upgrading lua-language-server"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade lua-language-server
            return
        fi
        # Linux: fall through to re-download latest
    else
        log "Installing lua-language-server"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install lua-language-server
            return
        fi
    fi

    # Linux binary download (install or upgrade via latest GitHub release)
    local os_arch lua_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        lua_arch="linux-arm64"
    else
        lua_arch="linux-x64"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    local tag
    tag="$(pinned_tag "${LUA_LS_VERSION}" LuaLS/lua-language-server)" || return 1
    if [[ -n "${UPGRADE:-}" ]] && command -v lua-language-server >/dev/null 2>&1; then
        local current_version
        current_version="$(lua-language-server --version 2>/dev/null || true)"
        if [[ "${current_version}" == "${tag}" ]]; then
            log "lua-language-server ${tag} already at latest; skipping"
            return
        fi
    fi
    local archive="lua-language-server-${tag}-${lua_arch}.tar.gz"
    local install_dir="${HOME}/.local/opt/lua-language-server"
    mkdir -p "${install_dir}"
    # No checksum manifest: LuaLS publishes the tarballs alone.
    download "https://github.com/LuaLS/lua-language-server/releases/download/${tag}/${archive}" \
        "${tmp_dir}/${archive}" || return 1
    tar -xf "${tmp_dir}/${archive}" -C "${install_dir}" || return 1
    mkdir -p "${HOME}/.local/bin"
    ln -sf "${install_dir}/bin/lua-language-server" "${HOME}/.local/bin/lua-language-server"
}

_opam_sandboxing_works() {
    bwrap --bind / / --dev-bind /dev /dev --proc /proc true 2>/dev/null
}

install_opam() {
    local os_name
    os_name="$(uname -s)"

    _install_opam_linux_binary() {
        local os_arch opam_arch
        os_arch="$(uname -m)"
        if [[ "${os_arch}" == "aarch64" ]]; then
            opam_arch="arm64"
        else
            opam_arch="x86_64"
        fi
        # opam signs its binaries with a detached GPG signature rather than
        # publishing a checksum manifest, and verifying one needs the opam
        # release key imported first, so this download is unverified.
        local tag version
        tag="$(pinned_tag "${OPAM_VERSION}" ocaml/opam)" || return 1
        version="${tag#v}"
        if [[ -n "${UPGRADE:-}" ]] && command -v opam >/dev/null 2>&1; then
            local current_version
            current_version="$(opam --version 2>/dev/null || true)"
            if [[ "${current_version}" == "${version}" ]]; then
                log "opam ${version} already at latest; skipping"
                return
            fi
        fi
        local binary install_dir
        binary="opam-${version}-${opam_arch}-linux"
        install_dir="${HOME}/.local/bin"
        mkdir -p "${install_dir}"
        download "https://github.com/ocaml/opam/releases/download/${tag}/${binary}" \
            "${install_dir}/opam" || return 1
        chmod +x "${install_dir}/opam"
    }

    if command -v opam >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "opam already installed; skipping"
        else
            log "Upgrading opam"
            if [[ "${os_name}" == "Darwin" ]]; then
                brew upgrade opam
            else
                _install_opam_linux_binary
            fi
        fi
    else
        log "Installing opam"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install opam
        else
            _install_opam_linux_binary
        fi
    fi
    unset -f _install_opam_linux_binary

    # Initialise opam root (idempotent: skip if ~/.opam already exists)
    if [[ -d "${HOME}/.opam" ]]; then
        log "opam already initialised; skipping opam init"
    else
        local init_flags=(--bare --yes --no-setup)
        if ! _opam_sandboxing_works; then
            log "bwrap sandboxing unavailable (container/VM); initialising opam with --disable-sandboxing"
            init_flags+=(--disable-sandboxing)
        fi
        opam init "${init_flags[@]}" || return 1
    fi

    install_ocaml_tools
}

# Where a C header lives on a Mac whose active developer directory does not
# carry it. `xcode-select -p` can point at a nix-provided apple-sdk — it does on
# this machine, at .../apple-sdk-14.4 — and those SDKs ship a subset of the
# headers a Command Line Tools SDK does. zlib.h is one of the missing ones, so
# /usr/bin/cc cannot preprocess `#include <zlib.h>` at all, and any opam package
# with a C stub needing it fails to build. Homebrew's keg-only zlib is preferred
# because it is the copy the rest of the machine already builds against; the CLT
# SDK is the fallback for a Mac without it. Setting SDKROOT does not help, since
# the CLT shim resolves its toolchain through xcode-select regardless.
_macos_c_search_path() {
    local candidate
    for candidate in /opt/homebrew/opt/zlib/include \
        /usr/local/opt/zlib/include \
        "$(xcrun --show-sdk-path 2>/dev/null)/usr/include" \
        /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include; do
        if [[ -f "${candidate}/zlib.h" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

# ocamllsp and ocamlformat, which the Neovim config enables and expects on PATH.
# They are opam packages, so they need a switch: `opam init --bare` deliberately
# creates none, and `opam install` into no switch fails. ocaml-system reuses a
# compiler already on the machine where there is one, which is the difference
# between seconds and a from-source OCaml build on every fresh install.
#
# This installs into whichever `default` switch the machine already has, which
# is shared with whatever else the user keeps there. opam resolves the request
# against the whole switch, so it may recompile packages this step never asked
# for — and a build failing part way leaves opam rolling back the ones it had
# already removed. That is not hypothetical: on 2 September 2026 camlzip failed
# on the missing zlib.h above, and the rollback dropped alt-ergo and why3 from
# this machine's default switch. Hence the search path below, and hence failing
# the step loudly rather than continuing.
install_ocaml_tools() {
    require_cmd opam

    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        local c_include
        if c_include="$(_macos_c_search_path)"; then
            export CPATH="${c_include}${CPATH:+:${CPATH}}"
            export LIBRARY_PATH="${c_include%/include}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
        else
            err "No zlib.h on this Mac; opam packages with C stubs will not build"
            return 1
        fi
    fi
    local switches
    switches="$(opam switch list --short 2>/dev/null || true)"
    if ! grep -qx "default" <<<"${switches}"; then
        log "Creating the default opam switch"
        # --packages is required on both paths. `opam switch create <name>`
        # reads a bare name as a compiler specification, so `opam switch create
        # default --yes` looks for a compiler called "default" and exits with
        # "No compiler matching `default' found" — which is what failed CI run
        # 33694339533 on a runner with no OCaml. ocaml-system reuses a compiler
        # already on the machine, the difference between seconds and a
        # from-source build; ocaml-base-compiler is that from-source build, and
        # is the only option where the machine has no ocamlc.
        if command -v ocamlc >/dev/null 2>&1; then
            opam switch create default --packages=ocaml-system --yes || return 1
        else
            opam switch create default --packages=ocaml-base-compiler --yes || return 1
        fi
    fi

    local installed
    installed="$(opam list --switch default --installed --short 2>/dev/null || true)"
    local missing=()
    local package
    for package in ocaml-lsp-server ocamlformat; do
        if ! grep -qx "${package}" <<<"${installed}"; then
            missing+=("${package}")
        fi
    done
    if ((${#missing[@]} == 0)); then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "ocaml-lsp-server and ocamlformat already installed; skipping"
            return
        fi
        log "Upgrading ocaml-lsp-server and ocamlformat"
        opam upgrade --switch default --yes ocaml-lsp-server ocamlformat || return 1
        return
    fi
    log "Installing ${missing[*]} into the default opam switch"
    opam install --switch default --yes "${missing[@]}" || return 1
}

install_go() {
    # Linux only — macOS gets Go via brew when needed.
    # Check /usr/local/go directly rather than relying on PATH: a
    # distro-packaged /usr/bin/go can shadow the toolchain this function
    # installs, making every run think it needs to upgrade.
    local go_bin=""
    if [[ -x /usr/local/go/bin/go ]]; then
        go_bin=/usr/local/go/bin/go
    elif command -v go >/dev/null 2>&1; then
        go_bin=go
    fi
    local go_minor=0
    if [[ -n "${go_bin}" ]]; then
        local go_version_output
        go_version_output="$("${go_bin}" version)"
        go_minor="$(printf '%s' "${go_version_output}" | sed 's/.*go1\.\([0-9]*\).*/\1/')"
        if [[ "${go_minor:-0}" -ge 21 ]]; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Go 1.${go_minor} already installed; skipping"
                return
            fi
            log "Upgrading Go"
        else
            log "Go 1.${go_minor} < 1.21; upgrading to latest stable"
        fi
    else
        log "Installing Go"
    fi

    local arch go_arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) go_arch="amd64" ;;
        aarch64) go_arch="arm64" ;;
        *)
            log "Unsupported arch ${arch} for Go install; skipping"
            return
            ;;
    esac

    # Pinned like every other toolchain here. Under --upgrade the current
    # release comes from go.dev, whose status is checked: a bare curl left an
    # empty version behind, which then built a tarball name of
    # `.linux-amd64.tar.gz` and fetched a 404 page under it.
    local latest="${GO_VERSION}"
    if [[ -n "${UPGRADE:-}" ]]; then
        local version_output
        if ! version_output="$(curl -fsSL --proto '=https' --tlsv1.2 \
            "${_CURL_RETRY_OPTS[@]}" 'https://go.dev/VERSION?m=text')"; then
            err "Could not read the current Go release from go.dev"
            return 1
        fi
        latest="${version_output%%$'\n'*}" # e.g. go1.24.2
        if [[ -z "${latest}" ]]; then
            err "go.dev returned no version"
            return 1
        fi
    fi

    local tarball="${latest}.linux-${go_arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download_verified "https://go.dev/dl/${tarball}" "${tmp_dir}/${tarball}" \
        "https://dl.google.com/go/${tarball}.sha256" || return 1

    # Unpack beside the live toolchain and swap, rather than deleting first: an
    # extract that fails after `rm -rf /usr/local/go` used to leave the machine
    # with no Go at all, and the tar was unchecked.
    local staged="${tmp_dir}/stage"
    mkdir -p "${staged}"
    tar -C "${staged}" -xf "${tmp_dir}/${tarball}" || return 1
    if [[ ! -x "${staged}/go/bin/go" ]]; then
        err "No go binary inside ${tarball}; upstream layout changed"
        return 1
    fi
    sudo rm -rf /usr/local/go.old
    if [[ -d /usr/local/go ]]; then
        sudo mv /usr/local/go /usr/local/go.old || return 1
    fi
    if ! sudo mv "${staged}/go" /usr/local/go; then
        err "Could not move the new Go into place"
        sudo mv /usr/local/go.old /usr/local/go 2>/dev/null || true
        return 1
    fi
    sudo rm -rf /usr/local/go.old
    export PATH="/usr/local/go/bin:${PATH}"
}

install_moor() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula moor >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "moor already installed; skipping"
                return
            fi
            log "Upgrading moor"
            brew upgrade moor
            return
        fi
        log "Installing moor"
        brew install moor
        return
    fi

    # Linux
    if command -v moor >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "moor already installed; skipping"
            return
        fi
        log "Upgrading moor"
    else
        log "Installing moor"
    fi

    local arch
    arch="$(uname -m)"

    if [[ "${arch}" == "aarch64" ]]; then
        # No official arm64 binary; build from source. install_go ensures a
        # modern Go is available; GOTOOLCHAIN=auto downloads a newer toolchain
        # if go.mod requires one beyond what's installed.
        GOTOOLCHAIN=auto go install github.com/walles/moor/v2/cmd/moor@latest
        return
    fi

    # x86_64: download official release binary. No checksum manifest is
    # published alongside it.
    local tag
    tag="$(pinned_tag "${MOOR_VERSION}" walles/moor)" || return 1
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download "https://github.com/walles/moor/releases/download/${tag}/moor-${tag}-linux-amd64" \
        "${tmp_dir}/moor" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/moor" "${HOME}/.local/bin/moor"
}

install_glow() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula glow >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "glow already installed; skipping"
                return
            fi
            log "Upgrading glow"
            brew upgrade glow
            return
        fi
        log "Installing glow"
        brew install glow
        return
    fi

    # Linux
    if command -v glow >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "glow already installed; skipping"
            return
        fi
        log "Upgrading glow"
    else
        log "Installing glow"
    fi

    local arch release_arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) release_arch="x86_64" ;;
        aarch64) release_arch="arm64" ;;
        *)
            log "Unsupported arch ${arch} for glow install; skipping"
            return
            ;;
    esac

    local tag version
    tag="$(pinned_tag "${GLOW_VERSION}" charmbracelet/glow)" || return 1
    version="${tag#v}" # release assets drop the leading v
    local dir_name="glow_${version}_Linux_${release_arch}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    local glow_base="https://github.com/charmbracelet/glow/releases/download/${tag}"
    download_verified "${glow_base}/${dir_name}.tar.gz" "${tmp_dir}/${dir_name}.tar.gz" \
        "${glow_base}/checksums.txt" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${dir_name}.tar.gz" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/${dir_name}/glow" "${HOME}/.local/bin/glow"
}

install_treehouse() {
    # Not in brew and no upstream arm64-Linux gap, so download the official
    # release binary on every platform (darwin/linux x amd64/arm64).
    #
    # The skip check comes before the tag resolves, so an install with nothing
    # to do costs no network round trip.
    local version_output current=""
    if command -v treehouse >/dev/null 2>&1; then
        version_output="$(treehouse --version 2>/dev/null)"
        current="$(awk '{print $NF}' <<<"${version_output}")"
        if [[ -z "${UPGRADE:-}" ]]; then
            log "treehouse ${current} already installed; skipping"
            return
        fi
    fi

    local tag
    tag="$(pinned_tag "${TREEHOUSE_VERSION}" kunchenguid/treehouse)" || return 1

    if [[ -n "${current}" ]]; then
        if [[ "${current}" == "${tag}" ]]; then
            log "treehouse ${current} already at latest; skipping"
            return
        fi
        log "Upgrading treehouse to ${tag}"
    else
        log "Installing treehouse ${tag}"
    fi

    local os_name arch go_os go_arch
    os_name="$(uname -s)"
    arch="$(uname -m)"
    case "${os_name}" in
        Darwin) go_os="darwin" ;;
        Linux) go_os="linux" ;;
        *)
            log "Unsupported OS ${os_name} for treehouse install; skipping"
            return
            ;;
    esac
    case "${arch}" in
        x86_64 | amd64) go_arch="amd64" ;;
        aarch64 | arm64) go_arch="arm64" ;;
        *)
            log "Unsupported arch ${arch} for treehouse install; skipping"
            return
            ;;
    esac

    local tarball="treehouse-${tag}-${go_os}-${go_arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    local treehouse_base="https://github.com/kunchenguid/treehouse/releases/download/${tag}"
    download_verified "${treehouse_base}/${tarball}" "${tmp_dir}/${tarball}" \
        "${treehouse_base}/checksums.txt" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/treehouse" "${HOME}/.local/bin/treehouse"
}

# Prebuilt release binaries where upstream publishes one for this platform, and
# `cargo install` where it does not -- the shape install_cargo_tool already has.
install_sccache() { install_cargo_tool sccache; }
install_difftastic() { install_cargo_tool difft difftastic; }
install_cargo_nextest() { install_cargo_tool cargo-nextest; }

# git-absorb publishes no aarch64 asset for either platform, so on an ARM Mac
# install_cargo_tool would build it from source on every fresh machine. brew
# has a bottle, so take that and leave Linux on the release binary.
install_git_absorb() {
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" != "Darwin" ]]; then
        install_cargo_tool git-absorb
        return
    fi
    if brew list --formula git-absorb >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "git-absorb already installed; skipping"
            return
        fi
        log "Upgrading git-absorb"
        brew upgrade git-absorb
        return
    fi
    log "Installing git-absorb"
    brew install git-absorb
}

# rga is two binaries, not one: `rga` shells out to `rga-preproc` for every
# adapter it runs, so installing the first alone gives a tool that fails on the
# first PDF it meets. install_cargo_tool only knows how to place one, so this
# step places both by hand.
install_ripgrep_all() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula ripgrep-all >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "ripgrep-all already installed; skipping"
                return
            fi
            log "Upgrading ripgrep-all"
            brew upgrade ripgrep-all
            return
        fi
        log "Installing ripgrep-all"
        brew install ripgrep-all
        return
    fi

    if command -v rga >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "ripgrep-all already installed; skipping"
            return
        fi
        log "Upgrading ripgrep-all"
    else
        log "Installing ripgrep-all"
    fi

    local arch triple
    arch="$(uname -m)"
    case "${arch}" in
        # musl on x86_64 and gnu on aarch64 is upstream's own split; those are
        # the only two Linux assets published.
        x86_64 | amd64) triple="x86_64-unknown-linux-musl" ;;
        aarch64 | arm64) triple="aarch64-unknown-linux-gnu" ;;
        *)
            log "Unsupported arch ${arch} for ripgrep-all install; skipping"
            return
            ;;
    esac

    local tag
    tag="$(pinned_tag "${RIPGREP_ALL_VERSION}" phiresky/ripgrep-all)" || return 1
    local tarball="ripgrep_all-${tag}-${triple}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    # No checksum manifest is published alongside the tarballs.
    download "https://github.com/phiresky/ripgrep-all/releases/download/${tag}/${tarball}" \
        "${tmp_dir}/${tarball}" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
    mkdir -p "${HOME}/.local/bin"
    local binary name
    for name in rga rga-preproc; do
        binary="$(find "${tmp_dir}" -type f -name "${name}" -print -quit)"
        if [[ -z "${binary}" ]]; then
            err "No ${name} binary inside ${tarball}"
            return 1
        fi
        install -m755 "${binary}" "${HOME}/.local/bin/${name}" || return 1
    done
}

install_gitleaks() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula gitleaks >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "gitleaks already installed; skipping"
                return
            fi
            log "Upgrading gitleaks"
            brew upgrade gitleaks
            return
        fi
        log "Installing gitleaks"
        brew install gitleaks
        return
    fi

    if command -v gitleaks >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "gitleaks already installed; skipping"
            return
        fi
        log "Upgrading gitleaks"
    else
        log "Installing gitleaks"
    fi

    # Go release naming, so the asset carries `x64`/`arm64` rather than a Rust
    # target triple.
    local arch release_arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64 | amd64) release_arch="x64" ;;
        aarch64 | arm64) release_arch="arm64" ;;
        *)
            log "Unsupported arch ${arch} for gitleaks install; skipping"
            return
            ;;
    esac

    local tag version
    tag="$(pinned_tag "${GITLEAKS_VERSION}" gitleaks/gitleaks)" || return 1
    version="${tag#v}"
    local tarball="gitleaks_${version}_linux_${release_arch}.tar.gz"
    local gitleaks_base="https://github.com/gitleaks/gitleaks/releases/download/${tag}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download_verified "${gitleaks_base}/${tarball}" "${tmp_dir}/${tarball}" \
        "${gitleaks_base}/gitleaks_${version}_checksums.txt" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/gitleaks" "${HOME}/.local/bin/gitleaks" || return 1
}

# ansible-lint is a Python package, so brew on macOS and a uv-managed tool
# environment on Linux -- the same place aider and the other Python CLIs here
# would go, and version-independent of whatever python3 the distro ships.
install_ansible_lint() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --formula ansible-lint >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "ansible-lint already installed; skipping"
                return
            fi
            log "Upgrading ansible-lint"
            brew upgrade ansible-lint
            return
        fi
        log "Installing ansible-lint"
        brew install ansible-lint
        return
    fi

    require_cmd uv
    if command -v ansible-lint >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "ansible-lint already installed; skipping"
            return
        fi
        log "Upgrading ansible-lint"
        uv tool upgrade ansible-lint
        return
    fi
    log "Installing ansible-lint"
    uv tool install ansible-lint
}

# elan is Lean's toolchain manager, the equivalent of rustup: it installs `lean`
# and `lake` per project from the lean-toolchain file, so this step only has to
# put elan itself on the machine. The release tarball holds `elan-init`, the
# one-shot installer, which writes into ~/.elan.
install_elan() {
    if command -v elan >/dev/null 2>&1 || [[ -x "${HOME}/.elan/bin/elan" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "elan already installed; skipping"
            return
        fi
        log "Upgrading elan"
        "${HOME}/.elan/bin/elan" self update || return 1
        return
    fi

    local os_name arch triple
    os_name="$(uname -s)"
    arch="$(uname -m)"
    case "${os_name}/${arch}" in
        Darwin/arm64 | Darwin/aarch64) triple="aarch64-apple-darwin" ;;
        Darwin/x86_64) triple="x86_64-apple-darwin" ;;
        Linux/x86_64 | Linux/amd64) triple="x86_64-unknown-linux-gnu" ;;
        Linux/aarch64 | Linux/arm64) triple="aarch64-unknown-linux-gnu" ;;
        *)
            log "Unsupported platform ${os_name}/${arch} for elan install; skipping"
            return
            ;;
    esac

    local tag
    tag="$(pinned_tag "${ELAN_VERSION}" leanprover/elan)" || return 1
    log "Installing elan ${tag}"
    local tarball="elan-${triple}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    # No checksum manifest is published alongside the tarballs.
    download "https://github.com/leanprover/elan/releases/download/${tag}/${tarball}" \
        "${tmp_dir}/${tarball}" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
    if [[ ! -x "${tmp_dir}/elan-init" ]]; then
        err "No elan-init inside ${tarball}; upstream layout changed"
        return 1
    fi
    # --no-modify-path: ~/.elan/bin goes on PATH from the shell config, not from
    # a line elan-init appends to a profile file chezmoi owns.
    "${tmp_dir}/elan-init" -y --no-modify-path || return 1
}

# fzf-git.sh binds git objects -- branches, tags, hashes, remotes, stashes --
# onto fzf pickers. Clone-and-source, like fzf-tab, so the clone is all this
# step does; the shell config sources it.
install_fzf_git() {
    local fzf_git_home="${XDG_DATA_HOME:-${HOME}/.local/share}/fzf-git.sh"
    if [[ -d "${fzf_git_home}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "fzf-git.sh already installed; skipping"
            return
        fi
        log "Upgrading fzf-git.sh"
        ensure_user_owns "${fzf_git_home}"
        safe_git "${fzf_git_home}" fetch origin || return 1
        safe_git "${fzf_git_home}" reset --hard origin/main
        return
    fi
    log "Installing fzf-git.sh"
    mkdir -p "$(dirname "${fzf_git_home}")"
    git clone --depth 1 https://github.com/junegunn/fzf-git.sh.git "${fzf_git_home}"
}

# The cargo tools with no prebuilt binary upstream. Every one of these is a
# source build, so this is the slowest step on a fresh machine; it is one step
# rather than five so a single failure is reported as one line, and each tool
# is skipped individually once installed.
install_cargo_extras() {
    local tool
    for tool in cargo-audit cargo-fuzz cargo-llvm-cov cross samply; do
        install_cargo_tool "${tool}" || return 1
    done
}

# The thing advertised at obsidian.md/cli is not a separately installable
# binary: it ships inside the desktop app. On macOS the cask now links it onto
# PATH itself — a `binary` stanza pointing /opt/homebrew/bin/obsidian at
# Contents/MacOS/obsidian-cli, added upstream in March 2026 — so a cask install
# needs no further step. Everywhere else it is registered by a GUI toggle
# (Settings -> General -> Command line interface), which copies the binary to
# ~/.local/bin/obsidian on Linux or symlinks /usr/local/bin/obsidian on macOS.
# It also needs the app to be running — the first command launches it. So the
# most a script can do on those paths is install the app and point at the
# remaining manual step, which is also why this is optional rather than
# installed everywhere.
install_obsidian() {
    local os_name os_arch
    os_name="$(uname -s)"
    os_arch="$(uname -m)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask obsidian >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Obsidian already installed; skipping"
                print_obsidian_macos_cli_note
                return
            fi
            # The cask sets `auto_updates true`, so this is a no-op unless
            # --greedy is passed. That is deliberate: Obsidian replaces its own
            # bundle, and a greedy upgrade only races the app's own updater.
            log "Upgrading Obsidian"
            brew upgrade --cask obsidian || true
            print_obsidian_macos_cli_note
            return
        fi

        # `brew list --cask` only sees what brew put there, so an Obsidian
        # installed by hand before these scripts existed reads as absent. Left
        # to fall through, the install below aborts on the existing bundle and
        # every later run repeats it, which is invisible from the outside
        # because run_step calls this inside an `if !`, disabling errexit, so
        # the failure never reaches the step report.
        if [[ -d "/Applications/Obsidian.app" ]]; then
            local installed cask_version
            installed="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
                /Applications/Obsidian.app/Contents/Info.plist 2>/dev/null || true)"
            cask_version="$(brew info --cask --json=v2 obsidian 2>/dev/null |
                jq -r '.casks[0].version' 2>/dev/null || true)"
            # --adopt takes over an existing artifact only when it is identical
            # to the cask's, so it is worth trying at a matching version and a
            # wasted download at any other. Compare first rather than let brew
            # pull ~150MB to discover the same thing.
            if [[ -n "${installed}" ]] && [[ "${installed}" == "${cask_version}" ]]; then
                log "Adopting the existing Obsidian ${installed} into brew"
                if brew install --cask --adopt obsidian; then
                    print_obsidian_macos_cli_note
                    return
                fi
            fi
            log "Obsidian ${installed:-(version unknown)} at /Applications was not installed by brew; leaving it alone"
            log "  to hand it over: rm -rf /Applications/Obsidian.app && brew install --cask obsidian"
            print_obsidian_cli_hint
            return
        fi

        log "Installing Obsidian"
        brew install --cask obsidian || return 1
        print_obsidian_macos_cli_note
        return
    fi

    # The CLI drives a running GUI app, so an Obsidian install on a machine with
    # no display buys nothing.
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "Obsidian: no display session detected; skipping on headless Linux"
        return
    fi

    local tag version
    tag="$(github_latest_tag obsidianmd/obsidian-releases)" || return 1
    version="${tag#v}"

    case "${os_arch}" in
        x86_64 | amd64)
            if dpkg -s obsidian >/dev/null 2>&1; then
                local current
                current="$(dpkg-query -W -f='${Version}' obsidian 2>/dev/null || true)"
                if [[ -z "${UPGRADE:-}" ]]; then
                    log "Obsidian ${current} already installed; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                if [[ "${current}" == "${version}" ]]; then
                    log "Obsidian ${current} already at latest; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                log "Upgrading Obsidian to ${version}"
            else
                log "Installing Obsidian ${version}"
            fi
            local deb="obsidian_${version}_amd64.deb"
            local tmp_dir
            tmp_dir="$(mktemp -d)"
            trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
            download "https://github.com/obsidianmd/obsidian-releases/releases/download/${tag}/${deb}" \
                "${tmp_dir}/${deb}" || return 1
            sudo apt-get install -y "${tmp_dir}/${deb}" || return 1
            ;;
        aarch64 | arm64)
            # Upstream publishes no arm64 .deb, only a tarball, so unpack it
            # under ~/.local/share and link the launcher onto PATH by hand.
            local dest="${HOME}/.local/share/obsidian"
            local version_file="${dest}/.version"
            if [[ -f "${version_file}" ]]; then
                local current
                current="$(cat "${version_file}")"
                if [[ -z "${UPGRADE:-}" ]]; then
                    log "Obsidian ${current} already installed; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                if [[ "${current}" == "${version}" ]]; then
                    log "Obsidian ${current} already at latest; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                log "Upgrading Obsidian to ${version}"
            else
                log "Installing Obsidian ${version}"
            fi
            local tarball="obsidian-${version}-arm64.tar.gz"
            local tmp_dir
            tmp_dir="$(mktemp -d)"
            trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
            download "https://github.com/obsidianmd/obsidian-releases/releases/download/${tag}/${tarball}" \
                "${tmp_dir}/${tarball}" || return 1
            tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
            local unpacked="${tmp_dir}/obsidian-${version}-arm64"
            if [[ ! -x "${unpacked}/obsidian" ]]; then
                err "Obsidian: no 'obsidian' binary at ${unpacked}; upstream layout changed"
                return 1
            fi
            rm -rf "${dest}"
            mkdir -p "$(dirname "${dest}")"
            mv "${unpacked}" "${dest}" || return 1
            printf '%s\n' "${version}" >"${version_file}"
            # Electron refuses to start if its setuid sandbox helper is not
            # root-owned and mode 4755. The .deb arranges that; an unpacked
            # tarball cannot, so do it here. Best-effort: failing only costs the
            # sandbox, and saying so beats a bare "app won't launch".
            if [[ -e "${dest}/chrome-sandbox" ]]; then
                if ! sudo chown root:root "${dest}/chrome-sandbox" ||
                    ! sudo chmod 4755 "${dest}/chrome-sandbox"; then
                    log "Obsidian: could not setuid chrome-sandbox; skipping (launch with --no-sandbox if the app refuses to start)"
                fi
            fi
            mkdir -p "${HOME}/.local/bin"
            ln -sf "${dest}/obsidian" "${HOME}/.local/bin/obsidian-app" || return 1
            ;;
        *)
            log "Unsupported arch ${os_arch} for Obsidian install; skipping"
            return
            ;;
    esac

    print_obsidian_cli_hint
}

# The cask has already linked /opt/homebrew/bin/obsidian, so the GUI toggle the
# hint below describes is not needed here. The command still cannot do anything
# with the app closed — it exits with "unable to find Obsidian" — so say that
# much rather than nothing.
print_obsidian_macos_cli_note() {
    log "Obsidian CLI linked as 'obsidian'; it needs the app running to do anything"
}

print_obsidian_cli_hint() {
    log "Obsidian CLI needs a one-time manual step: open Obsidian, then"
    log "  Settings -> General -> enable 'Command line interface'"
    log "  and follow the prompt to register it (installs the 'obsidian' command)"
}

# Sharing Obsidian config across machines is really this clone plus its
# schedule: the vault is a git repository and `.obsidian/` lives inside it, so
# settings, hotkeys, appearance, snippets and community-plugin code all ride
# along with the notes. Only `.obsidian/workspace.json` is gitignored. Nothing
# here belongs in chezmoi — obsync commits whatever Obsidian writes every 15
# minutes, so a chezmoi-managed copy would fight it for the same files.
#
# Three pieces have to line up and none is discoverable from the app: the
# obsync checkout, a vault clone whose remote is named `personal`, and the
# periodic invocation. This step owns the first and the third. The vault clone
# stays manual, because its URL is a private self-hosted forge and this
# repository is public — see scripts/CLAUDE.md for the reasoning.
OBSYNC_DIR="${HOME}/projects/obsync"
OBSYNC_REPO="https://github.com/benmandrew/obsync.git"
OBSYNC_VAULT_DIR="${HOME}/projects/obsidian-vault"
OBSYNC_VAULT_REMOTE="personal"
OBSYNC_LOG="${HOME}/.local/share/obsync/cron.log"
OBSYNC_INTERVAL_MIN=15
OBSYNC_CRON_MARKER="# obsync: managed by dotfiles install"
OBSYNC_LAUNCHD_LABEL="com.benmandrew.obsync"

install_obsync() {
    # obsync itself is public, so it clones over https and needs no key.
    if [[ -d "${OBSYNC_DIR}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "obsync already cloned; skipping"
        else
            log "Upgrading obsync"
            ensure_user_owns "${OBSYNC_DIR}"
            safe_git "${OBSYNC_DIR}" fetch origin || return 1
            safe_git "${OBSYNC_DIR}" reset --hard origin/main
        fi
    else
        log "Cloning obsync"
        mkdir -p "$(dirname "${OBSYNC_DIR}")"
        git clone "${OBSYNC_REPO}" "${OBSYNC_DIR}"
    fi

    # No vault means nothing to schedule against, and obsync.sh exits 1 on a
    # missing directory — which the cron job would then alert about every 15
    # minutes.
    if ! ensure_obsidian_vault; then
        return 0
    fi

    mkdir -p "$(dirname "${OBSYNC_LOG}")"
    schedule_obsync
}

# Both conditions gate the schedule, since obsync fails on either and a cron
# job would report that failure every 15 minutes. Neither is repairable from
# here: cloning the vault and naming its remote both need the forge URL, which
# is deliberately not in this repository. So this detects and explains.
#
# The remote name is the one worth explaining. obsync.sh hardcodes
# PRIMARY_REMOTE=personal, so a vault cloned the usual way — which gets
# `origin` — fails at `rev-parse personal/main` on every run, and the EXIT trap
# reports it as a bare exit status with no indication of the cause.
ensure_obsidian_vault() {
    if [[ ! -d "${OBSYNC_VAULT_DIR}/.git" ]]; then
        log "obsync: no vault at ${OBSYNC_VAULT_DIR}; skipping schedule"
        log "  clone it there first, naming the remote '${OBSYNC_VAULT_REMOTE}':"
        log "    git clone -o ${OBSYNC_VAULT_REMOTE} <vault-url> ${OBSYNC_VAULT_DIR}"
        return 1
    fi

    local url
    url="$(safe_git "${OBSYNC_VAULT_DIR}" remote get-url "${OBSYNC_VAULT_REMOTE}" 2>/dev/null || true)"
    if [[ -z "${url}" ]]; then
        log "obsync: vault has no '${OBSYNC_VAULT_REMOTE}' remote; skipping schedule"
        log "  git -C ${OBSYNC_VAULT_DIR} remote add ${OBSYNC_VAULT_REMOTE} <vault-url>"
        return 1
    fi

    return 0
}

schedule_obsync() {
    local os_name
    os_name="$(uname -s)"
    case "${os_name}" in
        Darwin) schedule_obsync_launchd ;;
        *) schedule_obsync_cron ;;
    esac
}

# The crontab in $1 with every obsync line taken out. Matching on obsync.sh as
# well as the marker catches hand-written entries that predate it. Everything
# else is passed through.
obsync_cron_stripped() {
    printf '%s\n' "$1" | grep -vF "${OBSYNC_CRON_MARKER}" | grep -vF 'obsync.sh' || true
}

# Called from the launchd path as well as here, so a Mac that predates the
# LaunchAgent does not keep running the crontab entry beside it. obsync.sh has
# no lock file, and launchd's phase resets on every reboot, so the two
# schedules can land together mid-rebase.
remove_obsync_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    local existing kept
    existing="$(crontab -l 2>/dev/null || true)"
    kept="$(obsync_cron_stripped "${existing}")"
    if [[ "${kept}" == "${existing}" ]]; then
        return 0
    fi

    log "Removing obsync crontab entry"
    printf '%s\n' "${kept}" | crontab -
}

schedule_obsync_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        log "obsync: no crontab command; skipping schedule"
        return
    fi

    # The redirect merges stderr into the log. Without it obsync's failure
    # output goes to cron's local mail, which nothing on these machines reads.
    local line
    line="*/${OBSYNC_INTERVAL_MIN} * * * * cd ${OBSYNC_DIR} && /bin/bash obsync.sh ${OBSYNC_VAULT_DIR} >> ${OBSYNC_LOG} 2>&1"

    local existing
    existing="$(crontab -l 2>/dev/null || true)"
    if [[ "${existing}" == *"${line}"* ]]; then
        log "obsync cron entry already installed; skipping"
        return
    fi

    # Drop any earlier entry before appending, so re-running does not stack up
    # duplicate schedules.
    local kept
    kept="$(obsync_cron_stripped "${existing}")"

    # Assemble first, pipe second. Anything but printf on the left of
    # `crontab -` has its exit status masked by the pipeline, so a failure
    # there would install a truncated crontab instead of stopping.
    local payload="${OBSYNC_CRON_MARKER}"$'\n'"${line}"
    if [[ -n "${kept//[[:space:]]/}" ]]; then
        payload="${kept}"$'\n'"${payload}"
    fi

    log "Installing obsync cron entry (every ${OBSYNC_INTERVAL_MIN} minutes)"
    printf '%s\n' "${payload}" | crontab -
}

# macOS still has cron, but it runs under a sandbox that needs Full Disk Access
# granted to /usr/sbin/cron by hand, and inherits a PATH with no Homebrew on it,
# so git is absent. A LaunchAgent avoids both.
schedule_obsync_launchd() {
    local plist="${HOME}/Library/LaunchAgents/${OBSYNC_LAUNCHD_LABEL}.plist"
    local interval=$((OBSYNC_INTERVAL_MIN * 60))

    mkdir -p "$(dirname "${plist}")"
    log "Installing obsync LaunchAgent (every ${OBSYNC_INTERVAL_MIN} minutes)"
    cat >"${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${OBSYNC_LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${OBSYNC_DIR}/obsync.sh</string>
        <string>${OBSYNC_VAULT_DIR}</string>
    </array>
    <key>WorkingDirectory</key><string>${OBSYNC_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key><integer>${interval}</integer>
    <key>StandardOutPath</key><string>${OBSYNC_LOG}</string>
    <key>StandardErrorPath</key><string>${OBSYNC_LOG}</string>
</dict>
</plist>
EOF

    local domain
    domain="gui/$(id -u)"
    # bootout first so a changed plist is picked up; it fails when nothing is
    # loaded, which is the normal first-install case.
    launchctl bootout "${domain}/${OBSYNC_LAUNCHD_LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap "${domain}" "${plist}" || return 1

    # After the agent is loaded, not before: a machine whose bootstrap failed
    # keeps the crontab entry and stays scheduled by it.
    remove_obsync_cron
}

# Both halves run under the one `obsidian` opt-in. install_obsidian returns
# early on several paths — already installed, headless, unsupported arch — so
# the two are sequenced here rather than chained inside it, and a failure in
# one still lets the other run.
install_obsidian_stack() {
    local rc=0
    install_obsidian || rc=1
    install_obsync || rc=1
    return "${rc}"
}

# zathura is a keyboard-driven PDF viewer. The managed zathurarc wires up SyncTeX
# inverse search into VS Code, so the build has to have SyncTeX support: Debian's
# package does, but the macOS formula makes it an :optional dependency, hence
# --with-synctex.
#
# macOS has no zathura in homebrew-core, so this uses the community tap. That tap
# builds from source and ships each document backend as its own formula, so a
# bare `brew install zathura` renders nothing at all — the backend plugin is not
# a nicety. The plugin also has to be linked into place by hand: its formula
# installs the .dylib into its own keg, while zathura only scans
# $(brew --prefix zathura)/lib/zathura.
#
# poppler is the backend on both platforms. The tap recommends mupdf and mupdf is
# the faster renderer, but only in ratio: measured on a 6-page typst paper, a
# single-page re-render — which is all watch mode does — is 24.3ms under mupdf
# against 30.2ms under poppler, and typst's own compile of the same document is
# 92ms. A ~6ms edge is invisible next to that, and it costs 71MB of mupdf plus a
# second renderer's quirks to learn. poppler is already present on most machines
# and is what Debian ships, so one backend covers both platforms.
install_zathura() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        local taps
        taps="$(brew tap)"
        if ! grep -q "^homebrew-zathura/zathura$" <<<"${taps}"; then
            log "Tapping homebrew-zathura/zathura"
            brew tap homebrew-zathura/zathura
        fi
        # Homebrew 6 refuses to load formulae from an unofficial tap until it is
        # trusted. The refusal is a per-formula error rather than a failed tap,
        # so without this the step walks straight past it and "succeeds" having
        # built nothing. Answering yes to the optional-tool prompt is the opt-in;
        # re-asking per tap would make the install interactive again.
        local trusted_taps
        trusted_taps="$(brew trust --json v1)"
        if ! jq -e '.taps | index("homebrew-zathura/zathura")' <<<"${trusted_taps}" >/dev/null; then
            log "Trusting tap homebrew-zathura/zathura"
            brew trust --tap homebrew-zathura/zathura || return 1
        fi
        if brew list --formula zathura >/dev/null 2>&1; then
            if [[ -n "${UPGRADE:-}" ]]; then
                log "Upgrading zathura"
                # `brew upgrade` reuses the options a formula was installed with
                # and appends any given here, so --with-synctex also repairs a
                # build that predates it.
                brew upgrade zathura --with-synctex || return 1
            else
                log "zathura already installed; skipping"
            fi
        else
            log "Installing zathura"
            brew install zathura --with-synctex || return 1
        fi
        # Guarded separately from zathura itself: the two are distinct formulae,
        # and an interrupted first run can leave the viewer without a backend.
        if brew list --formula zathura-pdf-poppler >/dev/null 2>&1; then
            if [[ -n "${UPGRADE:-}" ]]; then
                log "Upgrading zathura-pdf-poppler"
                brew upgrade zathura-pdf-poppler || return 1
            fi
        else
            log "Installing zathura-pdf-poppler"
            brew install zathura-pdf-poppler || return 1
        fi
        # Deliberately not the last command in the function: the hint below
        # returns 0, so letting it run last would mask a link failure and report
        # a clean install that renders nothing.
        link_zathura_pdf_plugin || return 1
        print_zathura_app_hint
        return 0
    fi

    # A GUI document viewer buys nothing on a machine with no display.
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "zathura: no display session detected; skipping on headless Linux"
        return
    fi

    if command -v zathura >/dev/null 2>&1 && dpkg -s zathura-pdf-poppler >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "zathura already installed; skipping"
            return
        fi
        log "Upgrading zathura"
    else
        log "Installing zathura"
    fi
    sudo apt-get install -y zathura zathura-pdf-poppler
}

link_zathura_pdf_plugin() {
    local zathura_prefix plugin_prefix
    # `brew --prefix <formula>` answers with the opt path whether or not the
    # formula is installed, so check installation separately or a failed install
    # gets misreported as an upstream layout change.
    if ! brew list --formula zathura-pdf-poppler >/dev/null 2>&1; then
        err "zathura: zathura-pdf-poppler is not installed; cannot link the PDF backend"
        return 1
    fi
    zathura_prefix="$(brew --prefix zathura)"
    plugin_prefix="$(brew --prefix zathura-pdf-poppler)"
    if [[ ! -f "${plugin_prefix}/libpdf-poppler.dylib" ]]; then
        err "zathura: no libpdf-poppler.dylib under ${plugin_prefix}; upstream layout changed"
        return 1
    fi
    mkdir -p "${zathura_prefix}/lib/zathura"
    ln -sf "${plugin_prefix}/libpdf-poppler.dylib" \
        "${zathura_prefix}/lib/zathura/libpdf-poppler.dylib"
}

print_zathura_app_hint() {
    log "zathura on macOS is a command-line tool. To also get a /Applications bundle"
    log "  that opens PDFs on double-click, run the tap's convert-into-app.sh:"
    log "  https://github.com/homebrew-zathura/homebrew-zathura"
}

print_chezmoi_init_hint() {
    log "You can initialize chezmoi with: chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
}
