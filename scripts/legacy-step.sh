#!/bin/bash

# Runs one bash install step for the Python runner in scripts/installer, which
# owns everything around the steps: arguments, sudo, the optional tools, holding
# a step's output and reporting what failed. A step that has been ported to
# Python no longer comes through here, and this file goes with the last of them.
#
#   legacy-step.sh <env-out> <function> [args...]
#
# stdout and stderr are the step's log, or the terminal under --verbose. `log`
# and `err` write to file descriptor 3, which install-common.sh points at the
# descriptor named by DOTFILES_TERM_FD.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

env_out="$1"
shift

os_name="$(uname -s)"
case "${os_name}" in
    Darwin)
        # shellcheck source=scripts/install-macos-arm64.sh
        source "${SCRIPT_DIR}/install-macos-arm64.sh"
        ;;
    *)
        # shellcheck source=scripts/install-linux.sh
        source "${SCRIPT_DIR}/install-linux.sh"
        ;;
esac

# Left of `||`, so errexit is off inside the step and it reports its last
# command's status, as every step is written to expect.
status=0
"$@" || status=$?

# The steps used to share one shell, so a PATH that one of them exported was
# there for the rest. The runner reads this and hands it to the next step. NUL
# separated, since a value may hold a newline.
env -0 >"${env_out}" || true

exit "${status}"
