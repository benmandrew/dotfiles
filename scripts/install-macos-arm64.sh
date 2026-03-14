#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

wait_for_clt() {
    log "Waiting for Xcode Command Line Tools installation to complete"
    until xcode-select -p >/dev/null 2>&1; do
        sleep 5
    done
}

install_xcode_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        log "Xcode Command Line Tools already installed"
        return
    fi

    log "Installing Xcode Command Line Tools"
    xcode-select --install || true
    wait_for_clt
}

install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log "Homebrew already installed"
        return
    fi

    log "Installing Homebrew"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "${script_path}"
    /bin/bash "${script_path}"
    rm -f "${script_path}"

    if [[ -x /opt/homebrew/bin/brew ]]; then
        local shellenv_path
        shellenv_path="$(mktemp)"
        /opt/homebrew/bin/brew shellenv >"${shellenv_path}"
        # shellcheck source=/dev/null
        source "${shellenv_path}"
        rm -f "${shellenv_path}"
    fi
}

main() {
    local os_name arch_name
    os_name="$(uname -s)"
    arch_name="$(uname -m)"

    if [[ "${os_name}" != "Darwin" ]]; then
        err "This script is for macOS only"
        exit 1
    fi

    if [[ "${arch_name}" != "arm64" ]]; then
        err "This script is for arm64 macOS only"
        exit 1
    fi

    log "Checking prerequisites"
    require_cmd sudo
    require_cmd curl
    require_cmd ssh-keygen

    install_xcode_clt
    install_homebrew

    require_cmd brew

    log "Installing base packages"
    brew update
    brew install git zsh tmux

    install_oh_my_zsh
    install_rust
    install_eza
    install_zoxide
    install_fzf
    install_starship

    log "Installing Neovim"
    brew install neovim

    print_chezmoi_init_hint
}

main "$@"
