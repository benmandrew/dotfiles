#!/bin/bash

set -uo pipefail

# Every directory the install scripts put a binary in. /opt/homebrew/bin was
# missing, so on macOS every brew-installed tool reported FAIL unless brew
# happened to be on the caller's PATH already; /usr/local/go/bin, ~/.opam and
# ~/.elan/bin cover the three toolchains that install outside ~/.local/bin.
export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${HOME}/.fzf/bin:${HOME}/go/bin:${HOME}/.elan/bin:${HOME}/.opam/default/bin:/usr/local/go/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/opt/nvim-linux-x86_64/bin:/opt/nvim-linux-arm64/bin:/nix/var/nix/profiles/default/bin:${PATH}"

os_name="$(uname -s)"

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

check_file() {
    local name="$1"
    local path="$2"
    if [[ -f "${path}" ]]; then
        printf "\033[1;32m[ok]\033[0m   %s\n" "${name}"
        ((ok++)) || true
    else
        printf "\033[1;31m[FAIL]\033[0m %s (%s)\n" "${name}" "${path}" >&2
        ((fail++)) || true
    fi
}

# perf (linux-tools-generic) depends on an exact-version kernel-tools package
# that isn't always available on cloud/CI kernels, so its absence is a
# warning rather than a failure.
check_cmd_optional() {
    local name="$1"
    if command -v "${name}" >/dev/null 2>&1; then
        printf "\033[1;32m[ok]\033[0m   %s\n" "${name}"
        ((ok++)) || true
    else
        printf "\033[1;33m[warn]\033[0m %s (optional, not installed)\n" "${name}"
    fi
}

check_cmd git
check_cmd curl
check_cmd zsh
check_cmd tmux
check_cmd entr
check_cmd_optional perf

check_dir "zinit" "${HOME}/.local/share/zinit/zinit.git"
check_dir "fzf-tab" "${HOME}/.local/share/fzf-tab"
check_dir "zsh-autosuggestions" "${HOME}/.local/share/zsh-autosuggestions"
# install_zsh_completions generates this one on every platform: no package
# ships a _delta, and zsh's bundled _sccs claims the command name, so its
# absence means git-delta is completing SCCS flags.
check_file "zsh completions" "${HOME}/.local/share/zsh/site-functions/_delta"

check_cmd rustup
check_cmd cargo
check_cmd rust-analyzer
check_cmd clangd
check_cmd yacc
check_cmd cmake
check_cmd nix
check_cmd direnv
check_cmd pyright
check_cmd lua-language-server
check_cmd opam
check_cmd moor
check_cmd glow
check_cmd treehouse
check_cmd eza
check_cmd fd
check_cmd bat
check_cmd btop
check_cmd rg
check_cmd delta
check_cmd jq
check_cmd zstd
check_cmd hyperfine
check_cmd zoxide
check_cmd fzf
check_cmd atuin
check_cmd gh
check_cmd tailscale

# Go installs on Linux only; macOS takes it from brew when a project needs it.
if [[ "${os_name}" == "Linux" ]]; then
    check_cmd go
fi

# nix-direnv is a nix profile entry rather than a command, and the line that
# loads it is what actually makes it do anything.
check_file "nix-direnv wired into direnvrc" "${HOME}/.config/direnv/direnvrc"

# nix-direnv's `use flake` refuses to run under bash older than 4.4, and macOS
# ships 3.2.57 as /bin/bash. install_modern_bash puts 5.x in the nix profile,
# which only counts if the login shell has ~/.nix-profile/bin on PATH — a macOS
# update rewrote /etc/zshrc and took the whole nix block with it, and every
# .envrc in a flake repository stopped loading. So resolve bash off a login
# shell's PATH the way direnv does, not off the doctored one at the top of this
# script, which would report every machine as fine.
#
# The probe starts from the system PATH with the environment cleared, because
# nix-daemon.sh exports __ETC_PROFILE_NIX_SOURCED and returns early when it is
# already set: inheriting it from the caller leaves the profile directory
# wherever the caller happened to have it, and the answer says more about this
# script's parent than about the machine. `zsh -lc` reads .zshenv, .zprofile
# and .zlogin and skips .zshrc, so nothing interactive writes to the stdout
# being read here. That understates the real PATH by whatever .zshrc prepends,
# which can only move bash earlier, so a pass here is a pass in the interactive
# shell direnv actually runs from.
check_bash_version() {
    local login_path bash_path version major minor
    # Single-quoted on purpose in both: the PATH and the version are the inner
    # shell's to expand, and expanding them here would report this one.
    # shellcheck disable=SC2016
    login_path="$(env -i "HOME=${HOME}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        zsh -lc 'printf "%s" "$PATH"' 2>/dev/null)"
    bash_path="$(PATH="${login_path:-${PATH}}" command -v bash 2>/dev/null)"
    # shellcheck disable=SC2016
    version="$("${bash_path:-/nonexistent}" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null)"
    major="${version%%.*}"
    minor="${version##*.}"
    if [[ -n "${version}" ]] && ((major > 4 || (major == 4 && minor >= 4))); then
        printf "\033[1;32m[ok]\033[0m   bash >= 4.4 for nix-direnv (%s, %s)\n" "${version}" "${bash_path}"
        ((ok++)) || true
    else
        printf "\033[1;31m[FAIL]\033[0m bash >= 4.4 for nix-direnv (login shell resolves bash to %s, version %s)\n" \
            "${bash_path:-none}" "${version:-unknown}" >&2
        ((fail++)) || true
    fi
}

check_bash_version

# Editor and formatter for OCaml, installed into the default opam switch.
check_cmd ocamllsp
check_cmd ocamlformat

check_cmd git-absorb
check_cmd gitleaks
check_cmd sccache
check_cmd rga
check_cmd rga-preproc
check_cmd difft
check_cmd ansible-lint
check_cmd cargo-nextest
check_cmd elan

check_cmd cargo-audit
check_cmd cargo-fuzz
check_cmd cargo-llvm-cov
check_cmd cross
check_cmd samply

check_dir "fzf-git.sh" "${HOME}/.local/share/fzf-git.sh"

# Neither of these is a binary on PATH, and both are skipped by the install
# when gh is unauthenticated — which it is on any box that has not had
# `gh auth login` run by hand — so absence is a warning, not a failure.
check_optional() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf "\033[1;32m[ok]\033[0m   %s\n" "${name}"
        ((ok++)) || true
    else
        printf "\033[1;33m[warn]\033[0m %s (optional, not installed)\n" "${name}"
    fi
}

has_gh_stack_ext() {
    gh extension list 2>/dev/null | grep -q "github/gh-stack"
}

has_gh_stack_skill() {
    gh skill list --agent claude-code --scope user --json skillName \
        --jq '.[].skillName' 2>/dev/null | grep -qx "gh-stack"
}

check_optional "gh-stack extension" has_gh_stack_ext
check_optional "gh-stack skill" has_gh_stack_skill

headless_linux=false
if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    headless_linux=true
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
    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask font-code-new-roman-nerd-font >/dev/null 2>&1; then
            printf "\033[1;32m[ok]\033[0m   nerd-font\n"
            ((ok++)) || true
        else
            printf "\033[1;31m[FAIL]\033[0m nerd-font\n" >&2
            ((fail++)) || true
        fi
    else
        check_dir "nerd-font" "${HOME}/.local/share/fonts/CodeNewRomanNerdFont"
    fi
fi

# Optional (opted into per machine) and, even when opted in, the `obsidian`
# command only appears after the app's GUI registration step — so absence is
# never a failure.
check_cmd_optional obsidian

# Also optional per machine, and skipped outright on headless Linux even when
# opted into.
check_cmd_optional zathura

check_dir "tpm" "${HOME}/.tmux/plugins/tpm"
# tpm clones its plugins beside itself, so a declared plugin that is not there
# means install_tmux_plugins cloned the manager and never ran it -- which is
# what left history-limit at tmux's 2000-line default on every machine. Read
# the declarations out of the rendered config rather than assume them, since
# the plugin list is free to change.
#
# Anchored to a `set -g @plugin` line, and reading every plugin rather than
# naming one. It used to grep the rendered config for the bare string
# tmux-sensible, which matched the comment above the four options inlined when
# that plugin was dropped, so it demanded a directory for a plugin the config
# no longer declares and reported FAIL on a correctly provisioned machine.
if [[ -f "${HOME}/.tmux.conf" ]]; then
    tmux_plugins="$(sed -nE "s|^[[:space:]]*set[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+'[^/']+/([^']+)'.*|\1|p" "${HOME}/.tmux.conf")"
    while read -r plugin; do
        # tpm is the manager, cloned by install_tmux_plugins and checked as
        # itself above; it does not live beside its own plugins.
        if [[ -n "${plugin}" && "${plugin}" != "tpm" ]]; then
            check_dir "tmux plugin ${plugin}" "${HOME}/.tmux/plugins/${plugin}"
        fi
    done <<<"${tmux_plugins}"
fi

check_cmd nvim

printf "\n%d passed, %d failed\n" "${ok}" "${fail}"
((fail == 0))
