;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Emacs reads this file once, at startup. `SPC h r r' (doom/reload) reloads it
;; in a running session. A change to init.el or packages.el also needs
;; `doom sync', which `chezmoi apply' runs through
;; run_onchange_after_sync-doom-emacs.sh.tmpl.

;; Hacktober, the scheme Ghostty and tmux use, from themes/ beside this file.
(setq doom-theme 'doom-hacktober)

;; As in Neovim: relative line numbers, and eight lines of context kept above
;; and below the cursor ('scrolloff').
(setq display-line-numbers-type 'relative
      scroll-margin 8)
