#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

main() {
    log "Checking prerequisites"
    require_cmd sudo
    require_cmd ssh-keygen

    log "Installing base packages"
    sudo apt install -y git curl build-essential zsh tmux

    install_oh_my_zsh
    install_rust
    install_eza
    install_zoxide
    install_fzf
    install_starship

    log "Installing Neovim"
    curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
    sudo rm -rf /opt/nvim-linux-x86_64
    sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
    rm nvim-linux-x86_64.tar.gz

    print_chezmoi_init_hint
}

main "$@"
