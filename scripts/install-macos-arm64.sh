#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

install_brew_formulae_if_missing() {
    local missing_formulae=()
    local formula
    for formula in "$@"; do
        if ! brew list --formula "${formula}" >/dev/null 2>&1; then
            missing_formulae+=("${formula}")
        fi
    done
    if ((${#missing_formulae[@]} == 0)); then
        log "Homebrew formulae already installed; skipping"
        return
    fi
    log "Installing missing Homebrew formulae: ${missing_formulae[*]}"
    brew update
    brew install "${missing_formulae[@]}"
}

install_neovim_if_missing() {
    if brew list --formula neovim >/dev/null 2>&1; then
        log "Neovim already installed; skipping"
        return
    fi
    install_brew_formulae_if_missing neovim
}

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

    install_brew_formulae_if_missing git zsh tmux node

    install_oh_my_zsh
    install_rust
    install_eza
    install_fd
    install_zoxide
    install_fzf
    install_claude_code
    install_rtk
    install_uv
    install_token_savior
    install_token_optimizer_mcp
    install_ccusage
    install_git_mcp
    install_starship
    install_tmux_plugins

    install_neovim_if_missing

    print_chezmoi_init_hint
}

main "$@"
