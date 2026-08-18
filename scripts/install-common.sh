#!/bin/bash

UPGRADE=""
_INSTALL_FAILED=false

# Homebrew 6 has ask mode on by default, so `brew install` and `brew upgrade`
# stop for a [y/n] confirmation whenever the plan reaches past the packages
# named on the command line — a dependency bump, a cask's dependants. Nothing
# here answers those prompts, so an install left to run unattended stalls on the
# first one. HOMEBREW_NO_ASK is what turns the default back off; the equivalent
# per-command flags are --no-ask/--yes.
export HOMEBREW_NO_ASK=1

run_step() {
    if ! "$@"; then
        err "Step failed: $*"
        _INSTALL_FAILED=true
    fi
}

check_failed() {
    if [[ "${_INSTALL_FAILED}" == "true" ]]; then
        err "One or more install steps failed; see errors above"
        exit 1
    fi
}

log() {
    if [[ "$*" == *"skipping"* ]]; then
        printf "\033[1;33m[install]\033[0m %s\n" "$*"
    elif [[ "$*" == *"pgrading"* ]]; then
        printf "\033[1;36m[install]\033[0m %s\n" "$*"
    else
        printf "\033[1;32m[install]\033[0m %s\n" "$*"
    fi
}

err() {
    printf "\033[1;31m[install]\033[0m ERROR: %s\n" "$*" >&2
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

# sudo caches credentials for a short window (15 minutes by default, less on
# some configs) and a full install — especially the --upgrade path, which
# rebuilds tmux and re-downloads every toolchain — comfortably outruns it, so
# the password gets asked for again at each later sudo step. Authenticate once
# up front and refresh the timestamp from the background for as long as the
# script runs, which covers every step whose only problem is outlasting the
# cache. Some steps still prompt. Homebrew 6 runs `sudo --reset-timestamp` at
# the start of every brew invocation (Library/Homebrew/brew.sh), wiping the
# cached credential, so the next privileged step after any brew command asks
# for the password again.
_SUDO_KEEPALIVE_PID=""

start_sudo_keepalive() {
    # Already root: nothing to cache, and `sudo -v` would be pointless.
    if ((EUID == 0)); then
        return
    fi
    log "Requesting sudo access (refreshed in the background; steps that follow a brew command may re-prompt)"
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
        sudo -n true 2>/dev/null || true
        sleep 50
    done &
    _SUDO_KEEPALIVE_PID=$!
    # Suppress a "Terminated" job notice if the script is ever run with job
    # control on (sourced from an interactive shell); a plain `bash install.sh`
    # never prints one. Best-effort: macOS ships bash 3.2, where `disown` may
    # only accept a %jobspec rather than a bare pid, so failure is ignored.
    disown "${_SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    trap stop_sudo_keepalive EXIT
}

stop_sudo_keepalive() {
    if [[ -n "${_SUDO_KEEPALIVE_PID}" ]]; then
        kill "${_SUDO_KEEPALIVE_PID}" 2>/dev/null || true
        _SUDO_KEEPALIVE_PID=""
    fi
}

parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            --upgrade) UPGRADE=true ;;
            --all-optional) OPTIONAL_MODE=all ;;
            --no-optional) OPTIONAL_MODE=none ;;
            --reconfigure-optional) OPTIONAL_RECONFIGURE=true ;;
            *)
                err "Unknown argument: ${arg}. Usage: $0 [--upgrade] [--all-optional|--no-optional] [--reconfigure-optional]"
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
        printf "\033[1;35m[install]\033[0m %s\n" "${description}"
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
github_api_curl() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -fsSL "${_CURL_RETRY_OPTS[@]}" -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
    else
        curl -fsSL "${_CURL_RETRY_OPTS[@]}" "$@"
    fi
}

github_latest_tag() {
    local repo="$1"
    local tmp
    tmp="$(mktemp)"
    # RETURN traps persist for the caller too until unset, so clear it here
    # or it would also fire (and re-delete an unrelated tmp) when the caller returns.
    trap 'rm -f "${tmp}"; trap - RETURN' RETURN
    github_api_curl "https://api.github.com/repos/${repo}/releases/latest" -o "${tmp}"
    local tag_line tag
    tag_line="$(grep -m1 '"tag_name"' "${tmp}" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
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
        safe_git "${zinit_home}" fetch origin
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
        safe_git "${fzf_tab_home}" fetch origin
        safe_git "${fzf_tab_home}" reset --hard origin/master
        return
    fi
    log "Installing fzf-tab"
    mkdir -p "$(dirname "${fzf_tab_home}")"
    git clone --depth 1 https://github.com/Aloxaf/fzf-tab.git "${fzf_tab_home}"
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
    sh "${script_path}" -y
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
    # Pinned rather than tracking latest: btop >= 1.4.5 uses std::ranges::to,
    # which needs GCC 14, and jammy ships GCC 11. Bump this once the oldest
    # target distro has a new enough compiler.
    local version="1.4.4"

    # ~/.local/bin is appended after /usr/bin on PATH, so a leftover apt btop
    # would shadow the binary installed below.
    if dpkg -s btop >/dev/null 2>&1; then
        log "Removing apt btop (predates GPU support, and shadows ~/.local/bin)"
        sudo apt purge -y btop
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
    jobs="$(nproc)"
    env PATH=/usr/local/bin:/usr/bin:/bin CXX=/usr/bin/g++ \
        make -C "${src_dir}" -j"${jobs}" || return 1
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${src_dir}/bin/btop" "${HOME}/.local/bin/btop"
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
            sudo apt install -y jq
        fi
        return
    fi
    log "Installing jq"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install jq
    else
        sudo apt install -y jq
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
    sudo apt install -y zstd libzstd-dev
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
            sudo apt install -y clangd
        fi
        return
    fi
    log "Installing clangd"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install llvm
    else
        sudo apt install -y clangd
    fi
}

install_cmake() {
    local required_version="4.3.2"
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
        latest_tag="$(github_latest_tag Kitware/CMake)"
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
    download "https://github.com/Kitware/CMake/releases/download/v${install_version}/${installer}" \
        "${tmp_dir}/${installer}" || return 1
    chmod +x "${tmp_dir}/${installer}"
    sudo sh "${tmp_dir}/${installer}" --prefix=/usr/local --skip-license
}

install_cargo_tool() {
    local cmd="$1" crate="${2:-$1}"
    if command -v "${cmd}" >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "${cmd} already installed; skipping"
            return
        fi
        log "Upgrading ${cmd}"
    else
        log "Installing ${cmd}"
    fi
    load_cargo_env
    require_cmd cargo
    cargo install "${crate}"
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
    sudo apt update
    sudo apt install -y gh
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
            safe_git "${HOME}/.fzf" pull
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
    local tag version
    tag="$(github_latest_tag atuinsh/atuin)"
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
    download "https://github.com/atuinsh/atuin/releases/download/${tag}/${tarball}" \
        "${tmp_dir}/${tarball}" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}"
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
    sh "${script_path}" --daemon --yes
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
    bin_path="${HOME}/.local/bin" bash "${script_path}"
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
    local script_path
    script_path="$(mktemp)"
    download https://starship.rs/install.sh "${script_path}" || return 1
    sh "${script_path}" -y
    rm -f "${script_path}"
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
    bash "${script_path}"
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
    sh "${script_path}"
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
    sh "${script_path}"
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
        build_version="$(github_latest_tag tmux/tmux)"
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
        build_version="3.6b"
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
    tar -C "${build_dir}" -xf "${build_dir}/${tarball}"
    local cpu_count
    cpu_count="$(nproc)"
    (cd "${build_dir}/tmux-${build_version}" && ./configure && make -j"${cpu_count}" && sudo make install)
}

install_tmux_plugins() {
    require_cmd git
    local tpm_dir="${HOME}/.tmux/plugins/tpm"
    if [[ -d "${tpm_dir}" ]]; then
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading tmux plugin manager (tpm)"
            ensure_user_owns "${tpm_dir}"
            safe_git "${tpm_dir}" fetch origin
            safe_git "${tpm_dir}" reset --hard origin/master
        else
            log "tmux plugin manager (tpm) already installed; skipping"
        fi
    else
        log "Installing tmux plugin manager (tpm)"
        mkdir -p "${HOME}/.tmux/plugins"
        git clone https://github.com/tmux-plugins/tpm "${tpm_dir}"
    fi
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

    # Linux binary download (install or upgrade via latest GitHub release)
    local os_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" != "x86_64" ]]; then
        log "WezTerm: no official binary for ${os_arch}; skipping"
        return
    fi
    local ubuntu_version version_id_line
    version_id_line="$(grep -m1 '^VERSION_ID=' /etc/os-release || true)"
    ubuntu_version="${version_id_line#VERSION_ID=}"
    ubuntu_version="${ubuntu_version//\"/}"
    # WezTerm only publishes 20.04 and 22.04 packages; 22.04 works on newer Ubuntu
    if [[ "${ubuntu_version}" != "20.04" && "${ubuntu_version}" != "22.04" ]]; then
        ubuntu_version="22.04"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    github_api_curl https://api.github.com/repos/wez/wezterm/releases/latest \
        -o "${tmp_dir}/release.json"
    local tag tag_line
    tag_line="$(grep -m1 '"tag_name"' "${tmp_dir}/release.json" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
    if [[ -n "${UPGRADE:-}" ]] && command -v wezterm >/dev/null 2>&1; then
        local installed_tag
        installed_tag="$(wezterm --version 2>/dev/null | awk '{print $2}' || true)"
        if [[ "${installed_tag}" == "${tag}" ]]; then
            log "WezTerm ${tag} already at latest; skipping"
            return
        fi
    fi
    local deb="wezterm-${tag}.Ubuntu${ubuntu_version}.deb"
    download "https://github.com/wez/wezterm/releases/download/${tag}/${deb}" \
        "${tmp_dir}/${deb}" || return 1
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
    tag="$(github_latest_tag ryanoasis/nerd-fonts)"
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
    download "https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/CodeNewRoman.zip" \
        "${tmp_dir}/CodeNewRoman.zip" || return 1
    mkdir -p "${font_dir}"
    unzip -oq "${tmp_dir}/CodeNewRoman.zip" -d "${font_dir}"
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
    sh "${script_path}"
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
    github_api_curl https://api.github.com/repos/LuaLS/lua-language-server/releases/latest \
        -o "${tmp_dir}/release.json"
    local tag tag_line
    tag_line="$(grep -m1 '"tag_name"' "${tmp_dir}/release.json" || true)"
    tag="${tag_line#*\"tag_name\": \"}"
    tag="${tag%%\"*}"
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
    download "https://github.com/LuaLS/lua-language-server/releases/download/${tag}/${archive}" \
        "${tmp_dir}/${archive}" || return 1
    tar -xf "${tmp_dir}/${archive}" -C "${install_dir}"
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
        local tag version
        tag="$(github_latest_tag ocaml/opam)"
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
        return
    fi
    local init_flags=(--bare --yes --no-setup)
    if ! _opam_sandboxing_works; then
        log "bwrap sandboxing unavailable (container/VM); initialising opam with --disable-sandboxing"
        init_flags+=(--disable-sandboxing)
    fi
    opam init "${init_flags[@]}"
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

    local latest version_output
    version_output="$(curl -fsSL "${_CURL_RETRY_OPTS[@]}" 'https://go.dev/VERSION?m=text')"
    latest="$(printf '%s' "${version_output}" | head -1)" # e.g. go1.24.2
    local tarball="${latest}.linux-${go_arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download "https://go.dev/dl/${tarball}" "${tmp_dir}/${tarball}" || return 1
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xf "${tmp_dir}/${tarball}"
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

    # x86_64: download official release binary
    local tag
    tag="$(github_latest_tag walles/moor)"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download "https://github.com/walles/moor/releases/download/${tag}/moor-${tag}-linux-amd64" \
        "${tmp_dir}/moor" || return 1
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
    tag="$(github_latest_tag charmbracelet/glow)"
    version="${tag#v}" # release assets drop the leading v
    local dir_name="glow_${version}_Linux_${release_arch}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download "https://github.com/charmbracelet/glow/releases/download/${tag}/${dir_name}.tar.gz" \
        "${tmp_dir}/glow.tar.gz" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/glow.tar.gz"
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/${dir_name}/glow" "${HOME}/.local/bin/glow"
}

install_treehouse() {
    # Not in brew and no upstream arm64-Linux gap, so download the official
    # release binary on every platform (darwin/linux x amd64/arm64).
    local tag
    tag="$(github_latest_tag kunchenguid/treehouse)"

    if command -v treehouse >/dev/null 2>&1; then
        local version_output current
        version_output="$(treehouse --version 2>/dev/null)"
        current="$(awk '{print $NF}' <<<"${version_output}")"
        if [[ -z "${UPGRADE:-}" ]]; then
            log "treehouse ${current} already installed; skipping"
            return
        fi
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
    download "https://github.com/kunchenguid/treehouse/releases/download/${tag}/${tarball}" \
        "${tmp_dir}/${tarball}" || return 1
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}"
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/treehouse" "${HOME}/.local/bin/treehouse"
}

# The thing advertised at obsidian.md/cli is not a separately installable
# binary: it ships inside the desktop app and is registered by a GUI toggle
# (Settings -> General -> Command line interface), which copies the binary to
# ~/.local/bin/obsidian on Linux or symlinks /usr/local/bin/obsidian on macOS.
# It also needs the app to be running — the first command launches it. So the
# most a script can do is install the app and point at the remaining manual
# step, which is also why this is optional rather than installed everywhere.
install_obsidian() {
    local os_name os_arch
    os_name="$(uname -s)"
    os_arch="$(uname -m)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask obsidian >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Obsidian already installed; skipping"
                print_obsidian_cli_hint
                return
            fi
            log "Upgrading Obsidian"
            brew upgrade --cask obsidian || true
        else
            log "Installing Obsidian"
            brew install --cask obsidian
        fi
        print_obsidian_cli_hint
        return
    fi

    # The CLI drives a running GUI app, so an Obsidian install on a machine with
    # no display buys nothing.
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "Obsidian: no display session detected; skipping on headless Linux"
        return
    fi

    local tag version
    tag="$(github_latest_tag obsidianmd/obsidian-releases)"
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
            sudo apt-get install -y "${tmp_dir}/${deb}"
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
            tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}"
            local unpacked="${tmp_dir}/obsidian-${version}-arm64"
            if [[ ! -x "${unpacked}/obsidian" ]]; then
                err "Obsidian: no 'obsidian' binary at ${unpacked}; upstream layout changed"
                return 1
            fi
            rm -rf "${dest}"
            mkdir -p "$(dirname "${dest}")"
            mv "${unpacked}" "${dest}"
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
            ln -sf "${dest}/obsidian" "${HOME}/.local/bin/obsidian-app"
            ;;
        *)
            log "Unsupported arch ${os_arch} for Obsidian install; skipping"
            return
            ;;
    esac

    print_obsidian_cli_hint
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
            safe_git "${OBSYNC_DIR}" fetch origin
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
    # duplicate schedules. Matching on obsync.sh as well as the marker catches
    # hand-written entries that predate it. Everything else is passed through.
    local kept
    kept="$(printf '%s\n' "${existing}" | grep -vF "${OBSYNC_CRON_MARKER}" | grep -vF 'obsync.sh' || true)"

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
    launchctl bootstrap "${domain}" "${plist}"
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
    sudo apt install -y zathura zathura-pdf-poppler
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
