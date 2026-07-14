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

-- format-tab-title runs on every status tick (100ms, see status_update_interval)
-- and ssh_host walks process state, so memoise it per tab. os.time only has
-- whole-second resolution, which is precisely the recompute rate we want: this
-- keeps the lookup at ~1/sec regardless of how often the tab bar repaints.
local SSH_HOST_TTL_SECONDS = 1
local ssh_host_cache = {}

local function ssh_host_cached(tab)
    local now = os.time()
    -- Expire as we go, which also stops closed tabs' entries accumulating.
    -- A negative age means the wall clock stepped back; treat it as expired.
    for id, entry in pairs(ssh_host_cache) do
        local age = now - entry.at
        if age < 0 or age >= SSH_HOST_TTL_SECONDS then
            ssh_host_cache[id] = nil
        end
    end

    local hit = ssh_host_cache[tab.tab_id]
    if hit then
        return hit.host or nil
    end
    -- nil is both the common answer (any local tab) and a full-price lookup,
    -- so cache it too, as false — the misses are what we're paying for.
    local host = ssh_host(tab)
    ssh_host_cache[tab.tab_id] = { host = host or false, at = now }
    return host
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
            local remote = ssh_host_cached(tab)
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

-- Clipboard indicator. WezTerm has no clipboard event, so every binding that
-- copies emits "copied" itself; the handler flashes the right status rather
-- than raising a desktop notification, which would pile up in the OS tray at
-- one entry per copy.
local COPIED_FLASH_SECONDS = 1.0
-- Bumped per flash so a stale call_after can't clear a newer flash early.
local copied_generation = 0

wezterm.on("copied", function(window, pane)
    -- The mouse binding below fires on every left-click release, not just ones
    -- that completed a selection, so confirm something was actually copied.
    local ok, sel = pcall(function()
        return window:get_selection_text_for_pane(pane)
    end)
    if not (ok and sel and #sel > 0) then
        return
    end

    copied_generation = copied_generation + 1
    local this_flash = copied_generation
    window:set_right_status(wezterm.format({
        { Background = { Color = hacktober.orange } },
        { Foreground = { Color = hacktober.bg } },
        { Attribute = { Intensity = "Bold" } },
        { Text = " copied " },
    }))
    wezterm.time.call_after(COPIED_FLASH_SECONDS, function()
        if copied_generation == this_flash then
            pcall(function()
                window:set_right_status("")
            end)
        end
    end)
end)

-- Behaviour
-- The right status only repaints when the tab bar is recomputed on this tick,
-- so the stock 1000ms makes the "copied" flash appear up to a second late (and
-- linger as long again). This bounds both to 100ms, at the cost of running
-- format-tab-title 10x more often.
config.status_update_interval = 100
config.scrollback_lines = 10000
config.audible_bell = "Disabled"
config.enable_kitty_keyboard = true

-- Leader (mirrors tmux C-a prefix)
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

-- Wrap a copy action so it also flashes the "copied" indicator. EmitEvent runs
-- after the copy, while the selection is still live for the handler to check.
local function copy_and_flash(dest)
    return act.Multiple({ act.CopyTo(dest), act.EmitEvent("copied") })
end

-- Same, for the mouse bindings, which complete a selection rather than copying
-- an existing one.
local function complete_selection_and_flash(dest)
    return act.Multiple({ act.CompleteSelection(dest), act.EmitEvent("copied") })
end

config.keys = {
    -- Copy (overrides the stock CopyTo bindings to add the indicator)
    { key = "c", mods = "SHIFT|CTRL", action = copy_and_flash("Clipboard") },
    { key = "c", mods = "SUPER", action = copy_and_flash("Clipboard") },
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

-- Copy mode's `y` (LEADER [ above). Assigning key_tables.copy_mode replaces the
-- whole table, so start from the defaults and patch just the yank entry.
-- wezterm.gui is absent in the mux server, which also loads this file.
if wezterm.gui then
    local copy_mode = wezterm.gui.default_key_tables().copy_mode
    for _, entry in ipairs(copy_mode) do
        if entry.key == "y" and entry.mods == "NONE" then
            -- Emit before Close: closing copy mode drops the selection the
            -- handler inspects.
            entry.action = act.Multiple({
                act.CopyTo("ClipboardAndPrimarySelection"),
                act.EmitEvent("copied"),
                act.CopyMode("Close"),
            })
        end
    end
    config.key_tables = { copy_mode = copy_mode }
end

-- Selecting with the mouse copies by default (ClipboardAndPrimarySelection);
-- streak 1/2/3 are drag-release, double-click word and triple-click line.
-- User mouse bindings merge over the defaults, so only these are replaced.
config.mouse_bindings = {
    {
        event = { Up = { streak = 1, button = "Left" } },
        mods = "NONE",
        action = act.Multiple({
            act.CompleteSelectionOrOpenLinkAtMouseCursor("ClipboardAndPrimarySelection"),
            act.EmitEvent("copied"),
        }),
    },
    {
        event = { Up = { streak = 2, button = "Left" } },
        mods = "NONE",
        action = complete_selection_and_flash("ClipboardAndPrimarySelection"),
    },
    {
        event = { Up = { streak = 3, button = "Left" } },
        mods = "NONE",
        action = complete_selection_and_flash("ClipboardAndPrimarySelection"),
    },
}

return config
