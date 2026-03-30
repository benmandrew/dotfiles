#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

install_apt_packages_if_missing() {
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

install_neovim_if_missing() {
    local nvim_path="/opt/nvim-linux-x86_64/bin/nvim"
    if [[ -x "${nvim_path}" ]] || command -v nvim >/dev/null 2>&1; then
        log "Neovim already installed; skipping"
        return
    fi
    log "Installing Neovim"
    curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
    sudo rm -rf /opt/nvim-linux-x86_64
    sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
    rm nvim-linux-x86_64.tar.gz
}

main() {
    log "Checking prerequisites"
    require_cmd sudo
    require_cmd ssh-keygen
    require_cmd dpkg
    require_cmd apt

    install_apt_packages_if_missing git curl build-essential zsh tmux

    install_oh_my_zsh
    install_rust
    install_eza
    install_fd
    install_zoxide
    install_fzf
    install_starship
    install_tmux_plugins

    install_neovim_if_missing

    print_chezmoi_init_hint
}

main "$@"
