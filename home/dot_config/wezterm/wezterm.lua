local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- Font
config.font = wezterm.font("JetBrains Mono")
config.font_size = 13.0

-- Colors
config.color_scheme = "Hacktober"

-- Tab bar: Hacktober palette
local hacktober = {
    bg = "#141414",
    surface = "#191918",
    hover = "#464444",
    text = "#c9c9c9",
    orange = "#c75a22",
}
config.colors = {
    selection_fg = "none",
    selection_bg = "#3d5278",
    tab_bar = {
        background = hacktober.bg,
        active_tab = {
            bg_color = hacktober.orange,
            fg_color = hacktober.bg,
            intensity = "Bold",
        },
        inactive_tab = {
            bg_color = hacktober.surface,
            fg_color = hacktober.text,
        },
        inactive_tab_hover = {
            bg_color = hacktober.hover,
            fg_color = hacktober.text,
        },
        new_tab = {
            bg_color = hacktober.bg,
            fg_color = hacktober.text,
        },
        new_tab_hover = {
            bg_color = hacktober.surface,
            fg_color = hacktober.text,
        },
    },
}

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
config.tab_bar_at_bottom = false
config.hide_tab_bar_if_only_one_tab = true

-- Tab title: remote hostname when SSH'd elsewhere, else focused directory's
-- name, unless manually renamed.
local TAB_TITLE_MAX_WIDTH = 24
-- Room for the " [" / "] " decoration around the truncated title above
config.tab_max_width = TAB_TITLE_MAX_WIDTH + 4
-- Short (domain-stripped, lowercased) hostname, for comparing the OSC 7 host
-- reported by the shell against the machine WezTerm is running on.
local function short_host(h)
    return (h or ""):gsub("%..*$", ""):lower()
end
local LOCAL_HOSTNAME = short_host(wezterm.hostname())

-- ssh options that consume the following token as their argument; used to
-- skip past them when locating the destination host in an ssh command line.
local SSH_ARG_OPTS = {
    b = true,
    c = true,
    D = true,
    E = true,
    e = true,
    F = true,
    I = true,
    i = true,
    J = true,
    L = true,
    l = true,
    m = true,
    O = true,
    o = true,
    p = true,
    Q = true,
    R = true,
    S = true,
    W = true,
    w = true,
}

-- Resolve a TabInformation to its active pane as a real mux Pane. The
-- PaneInformation handed to format-tab-title doesn't expose the process
-- table (nor, on older WezTerm, a pane handle), so we go through the mux
-- by tab id, which is stable across versions.
local function active_mux_pane(tab)
    local ok, mux_tab = pcall(wezterm.mux.get_tab, tab.tab_id)
    if not (ok and mux_tab) then
        return nil
    end
    for _, info in ipairs(mux_tab:panes_with_info()) do
        if info.is_active then
            return info.pane
        end
    end
    return nil
end

-- If the tab's active foreground process is `ssh`, return the destination
-- host (short form, user@ and domain stripped); otherwise nil. Covers remote
-- machines whose OSC 7 never reaches WezTerm — e.g. anything behind the
-- remote tmux our dotfiles auto-start, which swallows the sequence.
local function ssh_host(tab)
    local pane = active_mux_pane(tab)
    if not pane then
        return nil
    end
    local ok, argv = pcall(function()
        return pane:get_foreground_process_info().argv
    end)
    if not (ok and argv) then
        return nil
    end
    if (argv[1] or ""):gsub(".*/", "") ~= "ssh" then
        return nil
    end
    local i = 2
    while i <= #argv do
        local a = argv[i]
        if a:sub(1, 1) == "-" then
            -- A bare "-x" where x takes an argument swallows the next token.
            if #a == 2 and SSH_ARG_OPTS[a:sub(2, 2)] then
                i = i + 2
            else
                i = i + 1
            end
        else
            -- First positional argument is the destination.
            return short_host(a:gsub(".*@", ""))
        end
    end
    return nil
end

wezterm.on("format-tab-title", function(tab)
    local title = tab.tab_title
    if not (title and #title > 0) then
        local cwd = tab.active_pane.current_working_dir
        local host = cwd and short_host(cwd.host)
        if host and host ~= "" and host ~= LOCAL_HOSTNAME then
            -- OSC 7 reports a foreign host: we're SSH'd into another machine
            -- that emits it (our dotfiles do).
            title = host
        else
            local remote = ssh_host(tab)
            if remote and remote ~= "" then
                -- Foreground process is ssh: use its destination host.
                title = remote
            elseif cwd and cwd.file_path then
                title = cwd.file_path:gsub("/$", ""):match("([^/]+)$") or cwd.file_path
            else
                title = tab.active_pane.title
            end
        end
    end
    return " [" .. wezterm.truncate_right(title, TAB_TITLE_MAX_WIDTH) .. "] "
end)

-- Clear the Claude Code notification flag (see dot_claude/executable_wezterm-notify.sh)
-- once its tab is actually viewed, reverting to the auto cwd-based title.
wezterm.on("update-status", function(window)
    local tab = window:active_tab()
    if tab then
        local title = tab:get_title()
        if title and title:find("^🔔") then
            tab:set_title("")
        end
    end
end)

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
    { key = "w", mods = "LEADER", action = act.PaneSelect({ mode = "SwapWithActive" }) },
    -- Tabs
    { key = "c", mods = "LEADER", action = act.SpawnTab("CurrentPaneDomain") },
    { key = "n", mods = "LEADER", action = act.ActivateTabRelative(1) },
    { key = "p", mods = "LEADER", action = act.ActivateTabRelative(-1) },
    {
        key = ",",
        mods = "LEADER",
        action = act.PromptInputLine({
            description = "Rename tab",
            action = wezterm.action_callback(function(window, _pane, line)
                if line then
                    window:active_tab():set_title(line)
                end
            end),
        }),
    },
    -- Close pane/tab
    { key = "x", mods = "LEADER", action = act.CloseCurrentPane({ confirm = false }) },
    -- Copy mode (vi keys work inside)
    { key = "[", mods = "LEADER", action = act.ActivateCopyMode },
    -- Send literal C-a to the terminal (e.g. for remote tmux): double-tap C-a
    { key = "a", mods = "LEADER|CTRL", action = act.SendKey({ key = "a", mods = "CTRL" }) },
}

return config
