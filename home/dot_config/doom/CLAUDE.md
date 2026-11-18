# Doom Emacs

Paths are relative to the chezmoi source root.

`home/dot_config/doom/` is Doom's private config; the clone in `~/.config/emacs` belongs to the optional `install_doom_emacs` step. `run_onchange_after_sync-doom-emacs.sh.tmpl` hashes only `init.el` and `packages.el`, the files that need `doom sync`. `doom install` takes `--no-config`, or Doom's template files trip chezmoi's "has changed" prompt. `init.el` is Doom's own template, excluded from `typos`. `themes/doom-hacktober-theme.el` copies the Hacktober colours Ghostty and tmux use; change them together.

Each rule says what to preserve; the commit that introduced it records why.
