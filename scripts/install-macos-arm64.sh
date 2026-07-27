#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

install_brew_formulae_if_missing() {
    if [[ -n "${UPGRADE:-}" ]]; then
        log "Upgrading Homebrew formulae: $*"
        brew update
        brew upgrade "$@" || true
        for formula in "$@"; do
            if ! brew list --formula "${formula}" >/dev/null 2>&1; then
                brew install "${formula}"
            fi
        done
        return
    fi
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
        if [[ -n "${UPGRADE:-}" ]]; then
            log "Upgrading Neovim"
            brew upgrade neovim
        else
            log "Neovim already installed; skipping"
        fi
        return
    fi
    log "Installing Neovim"
    brew install neovim
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
    parse_args "$@"
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

    run_step install_brew_formulae_if_missing git zsh tmux node entr
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
    run_step install_zstd
    run_step install_hyperfine
    run_step install_zoxide
    run_step install_fzf
    run_step install_gh
    run_step install_tailscale
    run_step install_claude_code
    run_step install_rtk
    run_step install_uv
    run_step install_clangd
    run_step install_pyright
    run_step install_lua_ls
    run_step install_opam
    run_step install_moor
    run_step install_glow
    run_step install_treehouse
    run_step install_ccusage
    run_step install_starship
    run_step install_tmux_plugins
    run_step install_wezterm
    run_step install_nerd_font

    run_step install_neovim_if_missing

    print_chezmoi_init_hint
    check_failed
}

main "$@"
