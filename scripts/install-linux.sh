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

# A step's output is held in a file while it runs, so a debconf dialog would be
# both invisible and unanswerable. noninteractive is the frontend that never
# opens one, taking each package's default instead.
export DEBIAN_FRONTEND=noninteractive

set_default_terminal_wezterm() {
    # GNOME's Ctrl+Alt+T and "Open in Terminal" run x-terminal-emulator, which
    # otherwise points at whichever terminal registered the highest priority.
    # The wezterm-nightly deb registers open-wezterm-here; without it (headless,
    # or arm64, where install_wezterm skips) there is nothing to point at.
    local target="/usr/bin/open-wezterm-here"
    local query
    query="$(update-alternatives --query x-terminal-emulator 2>/dev/null)"
    if ! grep -qxF "Alternative: ${target}" <<<"${query}"; then
        log "x-terminal-emulator: ${target} not registered; skipping"
        return
    fi
    if grep -qxF "Value: ${target}" <<<"${query}"; then
        log "x-terminal-emulator already WezTerm; skipping"
        return
    fi
    log "Setting x-terminal-emulator to WezTerm"
    sudo update-alternatives --set x-terminal-emulator "${target}"
}
