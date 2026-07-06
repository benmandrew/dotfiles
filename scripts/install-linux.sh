#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

install_apt_packages_if_missing() {
    if [[ -n "${UPGRADE:-}" ]]; then
        log "Upgrading base packages: $*"
        sudo apt update
        sudo apt install -y "$@"
        return
    fi
    local missing_packages=()
    local package
    for package in "$@"; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing_packages+=("${package}")
        fi
    done
    if ((${#missing_packages[@]} == 0)); then
        log "Base packages already installed; skipping"
        return
    fi
    log "Installing missing base packages: ${missing_packages[*]}"
    sudo apt install -y "${missing_packages[@]}"
}

install_perf() {
    if command -v perf >/dev/null 2>&1; then
        log "perf already installed; skipping"
        return
    fi
    log "Installing perf (linux-tools-generic)"
    # linux-tools-generic depends on an exact-version linux-tools-$(uname -r)
    # package. Cloud/CI runners often run a custom kernel with no matching
    # package in the archive, so this install is best-effort: warn and
    # continue rather than failing the whole script.
    if ! sudo apt install -y linux-tools-generic; then
        log "WARNING: failed to install linux-tools-generic (perf); skipping, this is expected on some cloud kernels"
    fi
}

remove_conflicting_libnode_dev() {
    # The distro-provided libnode-dev ships headers (e.g. common.gypi) that
    # the NodeSource nodejs package also ships, so dpkg refuses to unpack
    # nodejs while libnode-dev is still installed.
    if dpkg -s libnode-dev >/dev/null 2>&1; then
        log "Removing distro libnode-dev (conflicts with NodeSource nodejs package)"
        sudo apt remove -y libnode-dev
    fi
}

install_node() {
    if command -v node >/dev/null 2>&1; then
        local node_major
        node_major="$(node --version | cut -d. -f1 | tr -d 'v')"
        if ((node_major >= 20)); then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Node.js ${node_major} already installed; skipping"
                return
            fi
            log "Upgrading Node.js LTS"
            sudo apt update
            remove_conflicting_libnode_dev
            sudo apt install -y nodejs
            return
        fi
        log "Node.js ${node_major} < 20; upgrading to LTS"
    else
        log "Installing Node.js LTS"
    fi
    remove_conflicting_libnode_dev
    local setup_path
    setup_path="$(mktemp)"
    curl -fsSL https://deb.nodesource.com/setup_lts.x -o "${setup_path}"
    sudo -E bash "${setup_path}"
    rm -f "${setup_path}"
    sudo apt install -y nodejs
}

install_neovim_if_missing() {
    local os_arch nvim_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        nvim_arch="arm64"
    else
        nvim_arch="${os_arch}"
    fi
    local nvim_dir="nvim-linux-${nvim_arch}"
    local nvim_path="/opt/${nvim_dir}/bin/nvim"
    if [[ -x "${nvim_path}" ]] || command -v nvim >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Neovim already installed; skipping"
            return
        fi
        log "Upgrading Neovim"
    else
        log "Installing Neovim"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/${nvim_dir}.tar.gz" \
        -o "${tmp_dir}/${nvim_dir}.tar.gz"
    sudo rm -rf "/opt/${nvim_dir}"
    sudo tar -C /opt -xzf "${tmp_dir}/${nvim_dir}.tar.gz"
}

main() {
    parse_args "$@"
    log "Checking prerequisites"
    require_cmd sudo
    require_cmd ssh-keygen
    require_cmd dpkg
    require_cmd apt
    install_apt_packages_if_missing git curl build-essential zsh entr libevent-dev libncurses-dev pkg-config bubblewrap bison autoconf unzip
    install_perf
    run_step install_tmux_from_source
    run_step install_cmake
    run_step install_nix
    run_step install_direnv
    run_step install_nix_direnv

    run_step install_zinit
    run_step install_rust
    run_step install_rust_analyzer
    run_step install_eza
    run_step install_fd
    run_step install_bat
    run_step install_btop
    run_step install_ripgrep
    run_step install_git_delta
    run_step install_jq
    run_step install_hyperfine
    run_step install_zoxide
    run_step install_fzf
    run_step install_gh
    run_step install_tailscale
    run_step install_claude_code
    run_step install_rtk
    run_step install_node
    run_step install_uv
    run_step install_clangd
    run_step install_pyright
    run_step install_lua_ls
    run_step install_opam
    run_step install_go
    run_step install_moor
    run_step install_token_savior
    run_step install_token_optimizer_mcp
    run_step install_ccusage
    run_step install_git_mcp
    run_step install_starship
    run_step install_tmux_plugins
    run_step install_wezterm
    run_step install_nerd_font

    run_step install_neovim_if_missing

    print_chezmoi_init_hint
    check_failed
}

main "$@"
