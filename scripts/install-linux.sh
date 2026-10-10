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
