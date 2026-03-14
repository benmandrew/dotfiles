#!/bin/bash

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

install_oh_my_zsh() {
    log "Installing Oh My Zsh"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "${script_path}"
    RUNZSH=no CHSH=no sh "${script_path}"
    rm -f "${script_path}"
}

install_rust() {
    log "Installing Rust"
    local script_path
    script_path="$(mktemp)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "${script_path}"
    sh "${script_path}" -s -- -y
    rm -f "${script_path}"

    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi
}

install_eza() {
    require_cmd cargo
    log "Installing eza"
    cargo install eza
}

install_zoxide() {
    log "Installing zoxide"
    local script_path
    script_path="$(mktemp)"
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_fzf() {
    log "Installing fzf"
    if [[ ! -d "${HOME}/.fzf" ]]; then
        git clone --depth 1 https://github.com/junegunn/fzf.git "${HOME}/.fzf"
    else
        log "fzf already cloned; skipping"
    fi
    "${HOME}/.fzf/install" --bin --no-update-rc --no-bash --no-fish
}

install_starship() {
    log "Installing Starship"
    local script_path
    script_path="$(mktemp)"
    curl -sS https://starship.rs/install.sh -o "${script_path}"
    sh "${script_path}" -y
    rm -f "${script_path}"
}

print_chezmoi_init_hint() {
    log "chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
}
