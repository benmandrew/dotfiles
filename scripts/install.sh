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

echo "Detected platform: ${OS}-${ARCH}"
echo "Running: ${SCRIPT}"
exec bash "${SCRIPT}" "$@"
