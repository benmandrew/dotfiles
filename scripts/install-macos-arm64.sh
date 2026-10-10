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
