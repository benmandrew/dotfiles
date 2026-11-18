# Zsh

Zsh is the fallback shell; fish is the login shell. Paths are relative to the chezmoi source root.

Load order in `home/dot_zshrc.tmpl` matters: fzf-tab after `~/.fzf.zsh` so it owns `^I`, atuin after both so it wins `^R`, and zsh-autosuggestions last, so it wraps every zsh line editor (ZLE) widget and keeps atuin's `ZSH_AUTOSUGGEST_STRATEGY`.

- fzf-tab needs `zstyle ':completion:*' menu no`. `make-target-recipe` reads recipes with awk, since `make -n` runs `$(shell ...)` per keystroke. Generated completions go first on `fpath`, before `compinit`, so `_delta` beats system functions like `_sccs`.
- `~/.rvmrc` sets `rvm_ignore_dotfiles=yes` so `rvm get` adds no eager loads back. `LS_COLORS` is a literal, the block running before `PATH` is set. `GLOB_DOTS` stays unset, so `rm *` cannot take `.git`.

Each rule says what to preserve; the commit that introduced it records why.
