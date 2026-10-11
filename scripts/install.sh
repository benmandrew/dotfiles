#!/bin/bash

# The bootstrap. It checks the platform, makes sure there is a python3 to run
# the installer on, and hands over to scripts/install.py. Everything else lives
# in scripts/installer, so this stays small enough to read in one go, and stays
# within bash 3.2, which is what a fresh Mac has.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The oldest python3 the installer supports. The Xcode Command Line Tools ship
# 3.9.6, and Ubuntu 22.04 ships 3.10.
PYTHON_MIN_MINOR=9

# On stderr, like everything else the installer says: stdout is where a step's
# own output goes under --verbose.
log() {
    printf "\033[1;32m[install]\033[0m %s\n" "$*" >&2
}

err() {
    printf "\033[1;31m[install]\033[0m ERROR: %s\n" "$*" >&2
}

# Bounded, since a dismissed or cancelled install dialog leaves nothing to
# wait for. A rerun opens the dialog again.
CLT_WAIT_SECONDS=1800

wait_for_clt() {
    local waited=0
    log "Waiting for Xcode Command Line Tools installation to complete"
    until xcode-select -p >/dev/null 2>&1; do
        if ((waited >= CLT_WAIT_SECONDS)); then
            err "Xcode Command Line Tools not installed after $((CLT_WAIT_SECONDS / 60)) minutes; was the dialog dismissed? Rerun to try again"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# Here rather than in the installer because /usr/bin/python3 is a stub until
# the tools are in place, and running the stub is itself what opens the install
# dialog. It also puts the wait ahead of the sudo password, so the credential
# does not age while the dialog is open.
install_xcode_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        return
    fi
    log "Installing Xcode Command Line Tools"
    xcode-select --install || true
    wait_for_clt
}

# A full Ubuntu has python3. A container image or a minimal install may not.
install_python3() {
    if command -v python3 >/dev/null 2>&1; then
        return
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        err "python3 is missing, and there is no apt-get to install it with"
        return 1
    fi
    log "Installing python3, which the installer runs on"
    # stdout dropped, since apt narrates there and reports failure on stderr.
    if ((EUID == 0)); then
        apt-get update >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null
    else
        sudo apt-get update >/dev/null
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null
    fi
}

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}" in
    Darwin)
        if [[ "${ARCH}" != "arm64" ]]; then
            err "macOS is only supported on arm64"
            exit 1
        fi
        install_xcode_clt
        ;;
    Linux)
        install_python3
        ;;
    *)
        err "unsupported OS '${OS}'"
        exit 1
        ;;
esac

# The system python3 first, so a run uses the interpreter a fresh machine has
# rather than a newer one from Homebrew or a nix devShell earlier on PATH.
PYTHON=/usr/bin/python3
if [[ ! -x "${PYTHON}" ]]; then
    PYTHON="$(command -v python3 || true)"
fi
if [[ -z "${PYTHON}" ]]; then
    err "No python3 found"
    exit 1
fi
if ! "${PYTHON}" -c "import sys; sys.exit(sys.version_info < (3, ${PYTHON_MIN_MINOR}))"; then
    err "${PYTHON} is older than Python 3.${PYTHON_MIN_MINOR}"
    exit 1
fi

# -B, so no __pycache__ is written into the repository.
exec "${PYTHON}" -B "${SCRIPT_DIR}/install.py" "$@"
