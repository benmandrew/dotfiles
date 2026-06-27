#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}-${ARCH}" in
    Darwin-arm64)
        SCRIPT="${SCRIPT_DIR}/install-macos-arm64.sh"
        ;;
    Linux-x86_64)
        # shellcheck disable=SC1091,SC2154
        DISTRO="$(. /etc/os-release && echo "${ID}")"
        case "${DISTRO}" in
            ubuntu)
                SCRIPT="${SCRIPT_DIR}/install-ubuntu-x86_64.sh"
                ;;
            debian)
                echo "error: Debian on x86_64 is not supported" >&2
                exit 1
                ;;
            *)
                echo "error: unsupported Linux distro '${DISTRO}' on x86_64" >&2
                exit 1
                ;;
        esac
        ;;
    Linux-aarch64)
        SCRIPT="${SCRIPT_DIR}/install-debian-arm64.sh"
        ;;
    *)
        echo "error: unsupported platform '${OS}-${ARCH}'" >&2
        exit 1
        ;;
esac

echo "Detected platform: ${OS}-${ARCH}"
echo "Running: ${SCRIPT}"
exec bash "${SCRIPT}" "$@"
