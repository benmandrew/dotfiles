#!/bin/bash

set -uo pipefail

export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${HOME}/.fzf/bin:/opt/nvim-linux-x86_64/bin:/opt/nvim-linux-arm64/bin:${PATH}"

ok=0
fail=0

check_cmd() {
    local name="$1"
    if command -v "${name}" >/dev/null 2>&1; then
        printf "\033[1;32m[ok]\033[0m   %s\n" "${name}"
        ((ok++)) || true
    else
        printf "\033[1;31m[FAIL]\033[0m %s\n" "${name}" >&2
        ((fail++)) || true
    fi
}

check_dir() {
    local name="$1"
    local path="$2"
    if [[ -d "${path}" ]]; then
        printf "\033[1;32m[ok]\033[0m   %s\n" "${name}"
        ((ok++)) || true
    else
        printf "\033[1;31m[FAIL]\033[0m %s (%s)\n" "${name}" "${path}" >&2
        ((fail++)) || true
    fi
}

check_cmd git
check_cmd curl
check_cmd zsh
check_cmd tmux
check_cmd entr

check_dir "zinit" "${HOME}/.local/share/zinit/zinit.git"

check_cmd rustup
check_cmd cargo
check_cmd rust-analyzer
check_cmd clangd
check_cmd cmake
check_cmd pyright
check_cmd lua-language-server
check_cmd opam
check_cmd eza
check_cmd fd
check_cmd bat
check_cmd zoxide
check_cmd fzf
check_cmd gh
check_cmd tailscale

headless_linux=false
os_name="$(uname -s)"
if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    headless_linux=true
fi

if [[ "${headless_linux}" == false ]]; then
    check_cmd mullvad
fi

check_cmd claude
check_cmd rtk

check_cmd node
check_cmd npm

check_cmd uv
check_cmd uvx

check_cmd ccusage
check_cmd starship

if [[ "${headless_linux}" == false ]]; then
    check_cmd wezterm
fi

check_dir "tpm" "${HOME}/.tmux/plugins/tpm"
check_dir "catppuccin" "${HOME}/.config/tmux/plugins/catppuccin"

check_cmd nvim

printf "\n%d passed, %d failed\n" "${ok}" "${fail}"
((fail == 0))
