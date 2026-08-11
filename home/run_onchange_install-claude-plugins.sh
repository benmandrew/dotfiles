#!/bin/bash

set -euo pipefail

# Install the third-party Claude Code plugins listed below.
#
# settings.json carries `extraKnownMarketplaces` and `enabledPlugins`, but
# neither key fetches anything — chezmoi can declare a plugin, it cannot clone
# it. This script does the fetching, so a fresh machine ends up with the
# plugins the settings file already claims are enabled.
#
# chezmoi re-runs a run_onchange_ script when the script's own content changes,
# so adding an entry to PLUGINS below is enough to trigger the install.
#
# Note: `claude plugin marketplace add` writes extraKnownMarketplaces into
# ~/.claude/settings.json itself, and reorders the other keys while it is
# there. That is why the add is guarded — it should run once on a new machine,
# never on a machine where the marketplace is already registered. The next
# `chezmoi apply` restores the canonical key order.

# marketplace-source:marketplace-name:plugin-name
PLUGINS=(
    "isaaccorley/skills:isaaccorley-skills:bib-audit"
)

if ! command -v claude >/dev/null 2>&1; then
    exit 0
fi

for entry in "${PLUGINS[@]}"; do
    IFS=':' read -r source marketplace plugin <<<"${entry}"

    if ! claude plugin marketplace list 2>/dev/null | grep -q "${marketplace}"; then
        claude plugin marketplace add "${source}"
    fi

    if ! claude plugin list 2>/dev/null | grep -q "${plugin}@${marketplace}"; then
        claude plugin install "${plugin}@${marketplace}" --scope user
    fi
done
