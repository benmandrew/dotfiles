#!/bin/bash

set -euo pipefail

log() {
    printf "[install] %s\n" "$*"
}

err() {
    printf "[install] ERROR: %s\n" "$*" >&2
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing required command: $1"
        exit 1
    fi
}

main() {
    log "Checking prerequisites"
    require_cmd sudo
    require_cmd curl
    require_cmd git
    require_cmd ssh-keygen

    log "Installing base packages"
    sudo apt install -y zsh tmux bat chezmoi

    log "Installing Rust"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi

    require_cmd cargo
    log "Installing eza"
    cargo install eza

    log "Installing zoxide"
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

    log "Installing fzf"
    if [[ ! -d "${HOME}/.fzf" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git "${HOME}/.fzf"
    else
        log "fzf already cloned; skipping"
    fi
    "${HOME}/.fzf/install"

    log "Installing Neovim"
    curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
    sudo rm -rf /opt/nvim-linux-x86_64
    sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
    rm nvim-linux-x86_64.tar.gz

    log "Initialization step"
    log "Creating SSH key pair at ${HOME}/.ssh/id_benmandrew"
    if [[ ! -f "${HOME}/.ssh/id_benmandrew" ]]; then
        mkdir -p "${HOME}/.ssh"
        ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_benmandrew" -N ""
    else
        log "SSH key already exists; skipping"
    fi

    log "Public key (copy this into Gitea or GitHub):"
    cat "${HOME}/.ssh/id_benmandrew.pub"
    log "Then run:"
    log "chezmoi init --apply git@ssh.git.benmandrew.com:me/dotfiles.git"
}

main "$@"
