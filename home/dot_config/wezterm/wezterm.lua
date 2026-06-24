local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- Font
config.font = wezterm.font("JetBrains Mono")
config.font_size = 13.0
config.harfbuzz_features = { "calt=0", "clig=0", "liga=0" }

-- Colors
config.color_scheme = "Hacktober"

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

-- Leader (mirrors tmux C-a prefix)
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

config.keys = {
    -- Splits
    { key = "v", mods = "LEADER", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
    { key = "s", mods = "LEADER", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
    -- Pane navigation
    { key = "h", mods = "LEADER", action = act.ActivatePaneDirection("Left") },
    { key = "j", mods = "LEADER", action = act.ActivatePaneDirection("Down") },
    { key = "k", mods = "LEADER", action = act.ActivatePaneDirection("Up") },
    { key = "l", mods = "LEADER", action = act.ActivatePaneDirection("Right") },
    -- Tabs
    { key = "c", mods = "LEADER", action = act.SpawnTab("CurrentPaneDomain") },
    { key = "n", mods = "LEADER", action = act.ActivateTabRelative(1) },
    { key = "p", mods = "LEADER", action = act.ActivateTabRelative(-1) },
    -- Close pane/tab
    { key = "x", mods = "LEADER", action = act.CloseCurrentPane({ confirm = true }) },
    -- Copy mode (vi keys work inside)
    { key = "[", mods = "LEADER", action = act.ActivateCopyMode },
    -- Send literal C-a to the terminal (e.g. for remote tmux)
    { key = "a", mods = "LEADER", action = act.SendKey({ key = "a", mods = "CTRL" }) },
}

return config
