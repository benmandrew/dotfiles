local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- Font
config.font = wezterm.font("JetBrains Mono")
config.font_size = 13.0

-- Colors
config.color_scheme = "Catppuccin Mocha"

-- Window
config.window_padding = {
    left = 8,
    right = 8,
    top = 8,
    bottom = 8,
}
config.window_decorations = "RESIZE"

-- Tab bar
config.enable_tab_bar = true
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = true

-- Behaviour
config.scrollback_lines = 10000
config.audible_bell = "Disabled"
config.enable_kitty_keyboard = true

return config
