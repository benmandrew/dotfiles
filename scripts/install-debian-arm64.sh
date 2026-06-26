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
            sudo apt install -y nodejs
            return
        fi
        log "Node.js ${node_major} < 20; upgrading to LTS"
    else
        log "Installing Node.js LTS"
    fi
    local setup_path
    setup_path="$(mktemp)"
    curl -fsSL https://deb.nodesource.com/setup_lts.x -o "${setup_path}"
    sudo -E bash "${setup_path}"
    rm -f "${setup_path}"
    sudo apt install -y nodejs
}

install_neovim_if_missing() {
    local nvim_path="/opt/nvim-linux-arm64/bin/nvim"
    if [[ -x "${nvim_path}" ]] || command -v nvim >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Neovim already installed; skipping"
            return
        fi
        log "Upgrading Neovim (ARM64)"
    else
        log "Installing Neovim (ARM64)"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    curl -fsSL https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.tar.gz \
        -o "${tmp_dir}/nvim-linux-arm64.tar.gz"
    sudo rm -rf /opt/nvim-linux-arm64
    sudo tar -C /opt -xzf "${tmp_dir}/nvim-linux-arm64.tar.gz"
}

main() {
    parse_args "$@"
    log "Checking prerequisites"
    require_cmd sudo
    require_cmd ssh-keygen
    require_cmd dpkg
    require_cmd apt

    install_apt_packages_if_missing git curl build-essential zsh entr libevent-dev libncurses-dev pkg-config
    install_tmux_from_source
    install_cmake

    install_oh_my_zsh
    install_rust
    install_rust_analyzer
    install_eza
    install_fd
    install_bat
    install_zoxide
    install_fzf
    install_gh
    install_claude_code
    install_rtk
    install_node
    install_uv
    install_clangd
    install_pyright
    install_lua_ls
    install_token_savior
    install_token_optimizer_mcp
    install_ccusage
    install_mcp_manim
    install_mcp_latex
    install_git_mcp
    install_starship
    install_tmux_plugins

    install_neovim_if_missing

    print_chezmoi_init_hint
}

main "$@"
