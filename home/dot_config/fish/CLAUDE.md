# Fish

Paths are relative to the chezmoi source root.

fish is the login shell and the only one configured. `home/dot_config/fish/config.fish.tmpl` branches on `uname`, never `.chezmoi.os`, so one rendering carries every arm to `scripts/lint-templates.sh`, which also runs `fish_indent --check`. Its `status is-login` block sources the Nix profile ahead of Homebrew, and erases `__ETC_PROFILE_NIX_SOURCED` first, since a tmux server hands it to every pane. The environment and plugin loading stay above the `status is-interactive` guard, since fifc runs each preview in a non-interactive `fish -c`. fifc's built-in rules match first, so a custom rule must not match a file or directory. `nvm_data` points nvm.fish at `~/.nvm/versions/node`, nvm's own tree.

Each rule says what to preserve; the commit that introduced it records why.
