# Fish

Paths are relative to the chezmoi source root.

fish is the login shell and the only one configured. `home/dot_config/fish/config.fish.tmpl` tests for the OS at run time, never with `.chezmoi.os`, so one rendering carries every arm to `scripts/lint-templates.sh`, which also runs `fish_indent --check`. Its `status is-login` block sources the Nix profile ahead of Homebrew, and erases `__ETC_PROFILE_NIX_SOURCED` first, since a tmux server hands it to every pane. The environment and plugin loading stay above the `status is-interactive` guard, since fifc runs each preview in a non-interactive `fish -c`. fifc's built-in rules match first, so a custom rule must not match a file or directory. Each tool's init script is sourced through `_source_cached_init`, keyed on mtimes, so a tool whose init output reads a config file names it with `--depends`, as atuin does. `nvm_data` points nvm.fish at `~/.nvm/versions/node`, nvm's own tree.

Each rule says what to preserve; the commit that introduced it records why.
