;;; doom-hacktober-theme.el --- Hacktober, as WezTerm and tmux draw it -*- lexical-binding: t; no-byte-compile: t; -*-

;; The palette is WezTerm's built-in Hacktober scheme, plus the colours this
;; repository shares between home/dot_config/wezterm/wezterm.lua,
;; dot_tmux.conf.tmpl and the atuin theme:
;;   bg #141414   surface #191918   hover #464444   text #c9c9c9
;;   orange #c75a22   selection #3d5278
;; A Doom theme wants nine greys, base0 to base8. Hacktober gives three of them
;; (base1 #191918, base4 #464444, base8 #f1eee7); the rest are interpolated,
;; and base6 #8a8a8a is the atuin theme's.
;;
;; Each entry is (truecolour 256-colour 16-colour). Panes export
;; COLORTERM=truecolor, so Emacs draws the first. The last is the terminal's
;; own ANSI name, which in WezTerm is Hacktober's matching entry anyway.

(require 'doom-themes)

(def-doom-theme doom-hacktober
  "Hacktober, matching the WezTerm and tmux palettes."
  :family 'doom-hacktober
  :background-mode 'dark

  ((bg         '("#141414" "#121212" "black"        ))
   (fg         '("#c9c9c9" "#c6c6c6" "white"        ))

   (bg-alt     '("#191918" "#1c1c1c" "black"        ))
   (fg-alt     '("#8a8a8a" "#8a8a8a" "brightblack"  ))

   (base0      '("#0e0e0e" "#080808" "black"        ))
   (base1      '("#191918" "#1c1c1c" "black"        ))
   (base2      '("#222120" "#262626" "brightblack"  ))
   (base3      '("#2c2b2a" "#303030" "brightblack"  ))
   (base4      '("#464444" "#444444" "brightblack"  ))
   (base5      '("#6b6969" "#6c6c6c" "brightblack"  ))
   (base6      '("#8a8a8a" "#8a8a8a" "brightblack"  ))
   (base7      '("#a9a9a9" "#a8a8a8" "white"        ))
   (base8      '("#f1eee7" "#eeeeee" "brightwhite"  ))

   (grey       base4)
   (red        '("#b34538" "#af5f5f" "red"          ))
   (orange     '("#c75a22" "#d75f00" "brightyellow" ))
   (green      '("#587744" "#5f875f" "green"        ))
   (teal       '("#42824a" "#5f875f" "brightgreen"  ))
   (yellow     '("#d08949" "#d7875f" "yellow"       ))
   (blue       '("#5389c5" "#5f87d7" "brightblue"   ))
   (dark-blue  '("#206ec5" "#005fd7" "blue"         ))
   (magenta    '("#e795a5" "#d787af" "brightmagenta"))
   (violet     '("#864651" "#875f5f" "magenta"      ))
   (cyan       '("#ebc587" "#d7af87" "brightcyan"   ))
   (dark-cyan  '("#ac9166" "#af875f" "cyan"         ))

   (highlight      orange)
   (vertical-bar   base4)
   (selection      '("#3d5278" "#5f5f87" "blue"     ))
   (builtin        dark-cyan)
   (comments       base5)
   (doc-comments   base6)
   (constants      magenta)
   (functions      blue)
   (keywords       orange)
   (methods        blue)
   (operators      fg)
   (type           yellow)
   (strings        green)
   (variables      cyan)
   (numbers        magenta)
   (region         selection)
   (error          '("#b33323" "#af0000" "brightred"))
   (warning        orange)
   (success        teal)
   (vc-modified    yellow)
   (vc-added       teal)
   (vc-deleted     red)

   ;; The mode line is tmux's status bar: text on the surface grey, and the
   ;; bar drawn in the accent orange as tmux draws the current window.
   (modeline-fg              fg)
   (modeline-fg-alt          base4)
   (modeline-bg              bg-alt)
   (modeline-bg-alt          bg)
   (modeline-bg-inactive     bg)
   (modeline-bg-inactive-alt bg))

  (((line-number &override) :foreground base4)
   ((line-number-current-line &override) :foreground fg)
   (mode-line :background modeline-bg :foreground modeline-fg)
   (mode-line-inactive :background modeline-bg-inactive :foreground modeline-fg-alt)
   (mode-line-emphasis :foreground highlight)
   (doom-modeline-bar :background highlight)
   (doom-modeline-buffer-file :inherit 'mode-line-buffer-id :weight 'bold)
   (doom-modeline-buffer-path :inherit 'mode-line-emphasis :weight 'bold)
   (doom-modeline-buffer-project-root :foreground teal :weight 'bold)
   (markdown-markup-face :foreground base5)
   (markdown-header-face :inherit 'bold :foreground orange)
   ((markdown-code-face &override) :background bg-alt)
   (solaire-mode-line-face :inherit 'mode-line :background modeline-bg-alt)
   (solaire-mode-line-inactive-face
    :inherit 'mode-line-inactive :background modeline-bg-inactive-alt))

  ())

;;; doom-hacktober-theme.el ends here
