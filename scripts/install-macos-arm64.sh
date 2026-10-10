#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# A library of steps: scripts/installer runs each function here in a process of
# its own, through legacy-step.sh. Run directly, this hands over to the entry
# point, so an old habit or an old document still installs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exec "${SCRIPT_DIR}/install.sh" "$@"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

install_brew_formulae_if_missing() {
    local formula
    if [[ -n "${UPGRADE:-}" ]]; then
        log "Upgrading Homebrew formulae: $*"
        brew update
        # A batch `brew upgrade` stops at the formula that failed and takes the
        # rest of the list with it. The failure used to be discarded with
        # `|| true` and only entirely-missing formulae reinstalled, so a
        # half-finished upgrade reported success. Retry each formula on its own
        # instead, and fail the step for whatever is still broken at the end.
        local failed=()
        if ! brew upgrade "$@"; then
            log "Batch upgrade failed; retrying each formula on its own"
            for formula in "$@"; do
                if ! brew list --formula "${formula}" >/dev/null 2>&1; then
                    brew install "${formula}" || failed+=("${formula}")
                elif ! brew upgrade "${formula}"; then
                    failed+=("${formula}")
                fi
            done
        fi
        if ((${#failed[@]} > 0)); then
            err "Homebrew formulae failed: ${failed[*]}"
            return 1
        fi
        return
    fi
    local missing_formulae=()
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

install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log "Homebrew already installed"
        return
    fi
    log "Installing Homebrew"
    local script_path
    script_path="$(mktemp)"
    download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "${script_path}" || return 1
    # This step used to be called outside the runner, under errexit, where a
    # failed installer ended the run. Inside a step errexit is off.
    /bin/bash "${script_path}" || return 1
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
