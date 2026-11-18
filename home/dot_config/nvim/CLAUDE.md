# Neovim

Paths are relative to the chezmoi source root.

`home/dot_config/nvim/`; `home/dot_vimrc` is for vim only. Plugin setup lives in each lazy.nvim spec. `.config/nvim/after` stays in `home/.chezmoiremove`, since nvim sources any leftover file there. Language server protocol (LSP) completion items need the `o` flag in `'complete'`, and `autotrigger` stays off, since beside `'autocomplete'` it doubles requests. `lazy-lock.json` is managed, so a plugin update trips chezmoi's "has changed" prompt; the restore script saves the lock first, since lazy rewrites it as nvim starts.

Each rule says what to preserve; the commit that introduced it records why.
