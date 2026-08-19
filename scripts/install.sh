#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}" in
    Darwin)
        if [[ "${ARCH}" != "arm64" ]]; then
            echo "error: macOS is only supported on arm64" >&2
            exit 1
        fi
        SCRIPT="${SCRIPT_DIR}/install-macos-arm64.sh"
        ;;
    Linux)
        SCRIPT="${SCRIPT_DIR}/install-linux.sh"
        ;;
    *)
        echo "error: unsupported OS '${OS}'" >&2
        exit 1
        ;;
esac

# On stderr, like everything else the installer says: the platform scripts drop
# each step's stdout, so stdout is where a step's own output goes under --verbose.
echo "Detected platform: ${OS}-${ARCH}" >&2
echo "Running: ${SCRIPT}" >&2
exec bash "${SCRIPT}" "$@"
