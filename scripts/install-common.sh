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

load_cargo_env() {
    if [[ -f "${HOME}/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "${HOME}/.cargo/env"
    fi
}

install_oh_my_zsh() {
    if [[ -d "${HOME}/.oh-my-zsh" ]]; then
        log "Oh My Zsh already installed; skipping"
        return
    fi
    log "Installing Oh My Zsh"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "${script_path}"
    RUNZSH=no CHSH=no sh "${script_path}"
    rm -f "${script_path}"
}

install_rust() {
    load_cargo_env
    if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
        log "Rust already installed; skipping"
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

install_eza() {
    if command -v eza >/dev/null 2>&1; then
        log "eza already installed; skipping"
        return
    fi
    load_cargo_env
    require_cmd cargo
    log "Installing eza"
    cargo install eza
}

install_fd() {
    if command -v fd >/dev/null 2>&1; then
        log "fd already installed; skipping"
        return
    fi
    load_cargo_env
    require_cmd cargo
    log "Installing fd"
    cargo install fd-find
}

install_zoxide() {
    if command -v zoxide >/dev/null 2>&1; then
        log "zoxide already installed; skipping"
        return
    fi
    log "Installing zoxide"
    local script_path
    script_path="$(mktemp)"
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        log "fzf already installed; skipping"
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

install_starship() {
    if command -v starship >/dev/null 2>&1; then
        log "Starship already installed; skipping"
        return
    fi
    log "Installing Starship"
    local script_path
    script_path="$(mktemp)"
    curl -sS https://starship.rs/install.sh -o "${script_path}"
    sh "${script_path}" -y
    rm -f "${script_path}"
}

install_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        log "Claude Code already installed; skipping"
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
        log "rtk already installed; skipping"
        return
    fi
    log "Installing rtk"
    local script_path
    script_path="$(mktemp)"
    curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o "${script_path}"
    sh "${script_path}"
    rm -f "${script_path}"
}

install_uv() {
    if command -v uv >/dev/null 2>&1; then
        log "uv already installed; skipping"
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

install_token_savior() {
    require_cmd uvx
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "token-savior"; then
        log "token-savior MCP server already registered; skipping"
        return
    fi
    log "Registering token-savior MCP server"
    claude mcp add -s user token-savior -- uvx --from "token-savior-recall[mcp]" token-savior
}

install_token_optimizer_mcp() {
    require_cmd npx
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "token-optimizer-mcp"; then
        log "token-optimizer-mcp MCP server already registered; skipping"
        return
    fi
    log "Registering token-optimizer-mcp MCP server"
    claude mcp add -s user token-optimizer-mcp -- npx -y @ooples/token-optimizer-mcp
}

install_ccusage() {
    require_cmd npm
    if ! command -v ccusage >/dev/null 2>&1; then
        log "Installing ccusage"
        npm install -g ccusage
    else
        log "ccusage already installed; skipping"
    fi
    local mcp_list
    mcp_list="$(claude mcp list 2>/dev/null)" || true
    if echo "${mcp_list}" | grep -q "ccusage"; then
        log "ccusage MCP server already registered; skipping"
        return
    fi
    log "Registering ccusage MCP server"
    claude mcp add -s user ccusage -- npx @ccusage/mcp@latest
}

install_tmux_plugins() {
    require_cmd git
    local tpm_dir="${HOME}/.tmux/plugins/tpm"
    local catppuccin_dir="${HOME}/.config/tmux/plugins/catppuccin"
    if [[ -d "${tpm_dir}" ]]; then
        log "tmux plugin manager (tpm) already installed; skipping"
    else
        log "Installing tmux plugin manager (tpm)"
        mkdir -p "${HOME}/.tmux/plugins"
        git clone https://github.com/tmux-plugins/tpm "${tpm_dir}"
    fi
    if [[ -d "${catppuccin_dir}" ]]; then
        log "tmux catppuccin theme already installed; skipping"
    else
        log "Installing tmux catppuccin theme"
        mkdir -p "${HOME}/.config/tmux/plugins"
        git clone https://github.com/catppuccin/tmux.git "${catppuccin_dir}"
    fi
}

print_chezmoi_init_hint() {
    log "You can initialize chezmoi with: chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
}
