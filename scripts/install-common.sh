#!/bin/bash

UPGRADE=""
_INSTALL_FAILED=false

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

parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            --upgrade) UPGRADE=true ;;
            *)
                err "Unknown argument: ${arg}. Usage: $0 [--upgrade]"
                exit 1
                ;;
        esac
    done
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
        curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
    else
        curl -fsSL "$@"
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
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "${script_path}"
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
    if command -v btop >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "btop already installed; skipping"
            return
        fi
        log "Upgrading btop"
        local os_name
        os_name="$(uname -s)"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew upgrade btop
        else
            sudo apt install -y btop
        fi
        return
    fi
    log "Installing btop"
    local os_name
    os_name="$(uname -s)"
    if [[ "${os_name}" == "Darwin" ]]; then
        brew install btop
    else
        sudo apt install -y btop
    fi
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
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v${install_version}/${installer}" \
        -o "${tmp_dir}/${installer}"
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
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "${tmp}"
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
    curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install -o "${script_path}"
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
    curl -fsSL https://direnv.net/install.sh -o "${script_path}"
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
    curl -sS https://starship.rs/install.sh -o "${script_path}"
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
    curl -fsSL https://claude.ai/install.sh -o "${script_path}"
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
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "${script_path}"
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
    curl -LsSf https://astral.sh/uv/install.sh -o "${script_path}"
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
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${build_version}/${tarball}" \
        -o "${build_dir}/${tarball}"
    tar -C "${build_dir}" -xzf "${build_dir}/${tarball}"
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
    curl -fsSL "https://github.com/wez/wezterm/releases/download/${tag}/${deb}" \
        -o "${tmp_dir}/${deb}"
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
    curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/${tag}/CodeNewRoman.zip" \
        -o "${tmp_dir}/CodeNewRoman.zip"
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
    curl -fsSL https://tailscale.com/install.sh -o "${script_path}"
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
    curl -fsSL "https://github.com/LuaLS/lua-language-server/releases/download/${tag}/${archive}" \
        -o "${tmp_dir}/${archive}"
    tar -xzf "${tmp_dir}/${archive}" -C "${install_dir}"
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
        curl -fsSL "https://github.com/ocaml/opam/releases/download/${tag}/${binary}" \
            -o "${install_dir}/opam"
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
    version_output="$(curl -fsSL 'https://go.dev/VERSION?m=text')"
    latest="$(printf '%s' "${version_output}" | head -1)" # e.g. go1.24.2
    local tarball="${latest}.linux-${go_arch}.tar.gz"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL "https://go.dev/dl/${tarball}" -o "${tmp_dir}/${tarball}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "${tmp_dir}/${tarball}"
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
    curl -fsSL "https://github.com/walles/moor/releases/download/${tag}/moor-${tag}-linux-amd64" \
        -o "${tmp_dir}/moor"
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
    curl -fsSL "https://github.com/charmbracelet/glow/releases/download/${tag}/${dir_name}.tar.gz" \
        -o "${tmp_dir}/glow.tar.gz"
    tar -C "${tmp_dir}" -xzf "${tmp_dir}/glow.tar.gz"
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
    curl -fsSL "https://github.com/kunchenguid/treehouse/releases/download/${tag}/${tarball}" \
        -o "${tmp_dir}/${tarball}"
    tar -C "${tmp_dir}" -xzf "${tmp_dir}/${tarball}"
    mkdir -p "${HOME}/.local/bin"
    install -m755 "${tmp_dir}/treehouse" "${HOME}/.local/bin/treehouse"
}

print_chezmoi_init_hint() {
    log "You can initialize chezmoi with: chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
}
