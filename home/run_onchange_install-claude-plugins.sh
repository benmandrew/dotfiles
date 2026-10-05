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
# the profile's settings.json itself, and reorders the other keys while it is
# there. That is why the add is guarded — it should run once on a new machine,
# never on a machine where the marketplace is already registered. The next
# `chezmoi apply` restores the canonical key order.

# marketplace-source:marketplace-name:plugin-name
#
# Keep this in step with enabledPlugins in
# .chezmoitemplates/claude-settings.json.tmpl: a plugin enabled there but
# missing here is enabled on paper and absent on disk.
PLUGINS=(
    "anthropics/claude-plugins-official:claude-plugins-official:clangd-lsp"
    "anthropics/claude-plugins-official:claude-plugins-official:pyright-lsp"
    "anthropics/claude-plugins-official:claude-plugins-official:lua-lsp"
    "isaaccorley/skills:isaaccorley-skills:bib-audit"
)

if ! command -v claude >/dev/null 2>&1; then
    exit 0
fi

# Plugins are per profile: ~/.claude-work shares agents and skills with
# ~/.claude through symlinks, but keeps its own plugin store, so each profile
# gets the same install pass with CLAUDE_CONFIG_DIR pointed at it.
#
# Each listing is captured before it is searched. Piped straight into
# `grep -q`, grep exits at the first match and closes the pipe, claude dies of
# SIGPIPE, and under pipefail the pipeline then reports failure -- so the guard
# would read "not installed" and rerun an install that had already happened.
# Both listings are refreshed after each change, since one marketplace serves
# several entries.
install_plugins() {
    local marketplaces installed entry source marketplace plugin
    marketplaces=$(claude plugin marketplace list 2>/dev/null || true)
    installed=$(claude plugin list 2>/dev/null || true)

    for entry in "${PLUGINS[@]}"; do
        IFS=':' read -r source marketplace plugin <<<"${entry}"

        if ! grep -qF -- "${marketplace}" <<<"${marketplaces}"; then
            claude plugin marketplace add "${source}"
            marketplaces=$(claude plugin marketplace list 2>/dev/null || true)
        fi

        if ! grep -qF -- "${plugin}@${marketplace}" <<<"${installed}"; then
            claude plugin install "${plugin}@${marketplace}" --scope user
            installed=$(claude plugin list 2>/dev/null || true)
        fi
    done
}

for config_dir in "${HOME}/.claude" "${HOME}/.claude-work"; do
    CLAUDE_CONFIG_DIR="${config_dir}" install_plugins
done
