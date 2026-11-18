# Fish

Paths are relative to the chezmoi source root.

the login shell; zsh stays installed as a fallback. `home/dot_config/fish/config.fish.tmpl` branches on `uname`, never `.chezmoi.os`, so one rendering carries every arm to `scripts/lint-templates.sh`, which also runs `fish_indent --check`. Its `status is-login` block ports `.zprofile`, erasing `__ETC_PROFILE_NIX_SOURCED` for the same reason. The environment and plugin loading stay above the `status is-interactive` guard, since fifc runs each preview in a non-interactive `fish -c`. fifc's built-in rules match first, so a custom rule must not match a file or directory. `nvm_data` points nvm.fish at `~/.nvm/versions/node`, zsh-nvm's tree.

Each rule says what to preserve; the commit that introduced it records why.
