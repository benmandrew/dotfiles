local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- Font: JetBrains Mono for text, with a fully-patched Nerd Font as fallback so
-- icon glyphs outside WezTerm's built-in symbol coverage (e.g. the Font Awesome
-- RAM glyph in the status bar) still resolve. CodeNewRoman is installed by our
-- install scripts on every non-headless machine.
config.font = wezterm.font_with_fallback({ "JetBrains Mono", "CodeNewRoman Nerd Font Mono" })
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
-- Keep the tab bar visible even with a single tab: the right status (the
-- "copied" flash below) lives in the tab bar and has nowhere to render
-- otherwise.
config.hide_tab_bar_if_only_one_tab = false

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

-- System metrics (CPU / RAM / uptime) in the right status: a local mirror of
-- the tmux remote-host status-right. The values move slowly but are relatively
-- costly to source, so we recompute at most once a second and cache the
-- formatted string; the tab bar itself repaints at 10Hz (status_update_interval).
-- os.time's 1s resolution is also exactly the window the Linux CPU delta samples.
local IS_MACOS = wezterm.target_triple:find("apple%-darwin") ~= nil

-- Status icons, by codepoint so an editor can't mangle the literal glyphs.
-- CPU is the MDI chip; RAM is the Font Awesome DIMM (needs the patched-font
-- fallback on config.font); uptime is the MDI clock. All three are ~55% em
-- height so the row stays visually even (the tmux hourglass is an outlier at 82%).
local ICON_CPU = utf8.char(0xF035B) -- nf-md-memory
local ICON_RAM = utf8.char(0x0EFC5) -- nf-fa-memory
local ICON_UPTIME = utf8.char(0xF0954) -- nf-md-clock

-- Seconds -> compact "3d 4h" / "5h 12m" / "42m".
local function fmt_uptime(s)
    local d = math.floor(s / 86400)
    local h = math.floor((s % 86400) / 3600)
    local m = math.floor((s % 3600) / 60)
    if d > 0 then
        return string.format("%dd %dh", d, h)
    elseif h > 0 then
        return string.format("%dh %dm", h, m)
    end
    return string.format("%dm", m)
end

-- Run argv, returning stdout on success or nil (never throws).
local function capture(argv)
    local ok, success, stdout = pcall(wezterm.run_child_process, argv)
    if ok and success then
        return stdout
    end
    return nil
end

-- Linux CPU: diff two /proc/stat snapshots taken across calls. Since the refresh
-- cadence is ~1s (see the cache below), the delta spans ~1s without the blocking
-- `sleep 0.2` the tmux cpu.sh needs. The first call has no baseline -> nil.
local prev_cpu_linux = nil
local function cpu_linux()
    local f = io.open("/proc/stat", "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    -- "cpu  user nice system idle iowait irq softirq steal ..."; idle is field 4.
    local total, idle, i = 0, 0, 0
    for n in (line or ""):gmatch("%d+") do
        i = i + 1
        n = tonumber(n) or 0
        total = total + n
        if i == 4 then
            idle = n
        end
    end
    local pct = nil
    if prev_cpu_linux and total > prev_cpu_linux.total then
        local dt = total - prev_cpu_linux.total
        local di = idle - prev_cpu_linux.idle
        pct = math.floor((dt - di) * 100 / dt + 0.5)
    end
    prev_cpu_linux = { total = total, idle = idle }
    return pct
end

-- macOS CPU: sum of per-process %cpu / core count. Cheap and non-blocking,
-- unlike `top -l 2` (which would stall ~1s); it's a smoothed approximation.
local function cpu_macos()
    local out = capture({ "ps", "-A", "-o", "%cpu=" })
    if not out then
        return nil
    end
    local sum = 0
    for n in out:gmatch("[%d.]+") do
        sum = sum + tonumber(n)
    end
    local ncpu = tonumber((capture({ "sysctl", "-n", "hw.ncpu" }) or ""):match("%d+")) or 1
    return math.min(100, math.floor(sum / ncpu + 0.5))
end

-- Linux RAM: used = MemTotal - MemAvailable (kB), rendered in GiB, matching ram.sh.
local function ram_linux()
    local f = io.open("/proc/meminfo", "r")
    if not f then
        return nil
    end
    local total, avail
    for line in f:lines() do
        local k, v = line:match("^(%w+):%s+(%d+)")
        if k == "MemTotal" then
            total = tonumber(v)
        elseif k == "MemAvailable" then
            avail = tonumber(v)
        end
        if total and avail then
            break
        end
    end
    f:close()
    if not (total and avail) then
        return nil
    end
    return string.format("%4.1fG/%4.1fG", (total - avail) / 1048576, total / 1048576)
end

-- macOS RAM: used = (active + wired + compressed) pages * page size; total from
-- hw.memsize. Rendered in GiB.
local function ram_macos()
    local total_out = capture({ "sysctl", "-n", "hw.memsize" })
    local vm = capture({ "vm_stat" })
    if not (total_out and vm) then
        return nil
    end
    local total = tonumber(total_out:match("%d+"))
    local pagesize = tonumber(vm:match("page size of (%d+) bytes")) or 4096
    local function pages(label)
        return tonumber(vm:match(label .. "%D-(%d+)")) or 0
    end
    local used = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * pagesize
    if not total then
        return nil
    end
    return string.format("%4.1fG/%4.1fG", used / 1073741824, total / 1073741824)
end

local function uptime_linux()
    local f = io.open("/proc/uptime", "r")
    if not f then
        return nil
    end
    local secs = f:read("*n")
    f:close()
    return secs and fmt_uptime(math.floor(secs)) or nil
end

local function uptime_macos()
    local out = capture({ "sysctl", "-n", "kern.boottime" })
    local boot = out and tonumber(out:match("sec%s*=%s*(%d+)"))
    return boot and fmt_uptime(os.time() - boot) or nil
end

-- Cached formatted right-status text; refreshed at most once a second.
local metrics_cache = { at = -1, text = nil }
local function metrics_text()
    local now = os.time()
    local age = now - metrics_cache.at
    if metrics_cache.text and age >= 0 and age < 1 then
        return metrics_cache.text
    end
    local cpu, ram, up
    if IS_MACOS then
        cpu, ram, up = cpu_macos(), ram_macos(), uptime_macos()
    else
        cpu, ram, up = cpu_linux(), ram_linux(), uptime_linux()
    end
    -- Fixed-width fields so a changing value doesn't nudge the row: the right
    -- status is right-aligned, so any width change shifts everything to its left.
    -- CPU pads to 3 digits (the 100% case), RAM to %4.1f per number (as ram.sh
    -- does), uptime left-justified into a field wide enough for "123d 4h".
    local cpu_s = cpu and string.format("%3d%%", cpu) or " --%"
    local text =
        string.format(" %s %s   %s %-11s   %s %-7s ", ICON_CPU, cpu_s, ICON_RAM, ram or "--", ICON_UPTIME, up or "--")
    metrics_cache = { at = now, text = text }
    return text
end

local function metrics_status()
    return wezterm.format({
        -- Reset intensity so a preceding bold segment (the flash) can't bleed in.
        { Attribute = { Intensity = "Normal" } },
        { Background = { Color = hacktober.surface } },
        { Foreground = { Color = hacktober.text } },
        { Text = metrics_text() },
    })
end

-- The "copied" flash (set by the clipboard handler below) is prepended to the
-- metrics rather than given its own status slot. The right status is
-- right-aligned, so the metrics stay pinned to the right edge while the chip
-- flashes just to their left — on the right side of the bar, without shoving
-- the metrics around.
local flash_on = false

local function right_status()
    if not flash_on then
        return metrics_status()
    end
    return wezterm.format({
        { Background = { Color = hacktober.orange } },
        { Foreground = { Color = hacktober.bg } },
        { Attribute = { Intensity = "Bold" } },
        { Text = " copied " },
        { Attribute = { Intensity = "Normal" } },
        { Background = { Color = hacktober.bg } },
        { Text = "  " },
    }) .. metrics_status()
end

-- Clear the Claude Code notification flag (see dot_claude/executable_wezterm-notify.sh)
-- once its tab is actually viewed, reverting to the auto cwd-based title, then
-- repaint the right status (metrics, plus the copied flash when active).
wezterm.on("update-status", function(window)
    local tab = window:active_tab()
    if tab then
        local title = tab:get_title()
        if title and title:find("^🔔") then
            tab:set_title("")
        end
    end
    window:set_right_status(right_status())
end)

-- Clipboard indicator. WezTerm has no clipboard event, so every binding that
-- copies emits an event itself; the handler flashes a chip on the right (just
-- left of the metrics, see right_status) rather than raising a desktop
-- notification, which would pile up in the OS tray at one entry per copy.
local COPIED_FLASH_SECONDS = 1.0
-- Bumped per flash so a stale call_after can't clear a newer flash early.
local copied_generation = 0

-- Paint the chip now and schedule its clear. Painting straight from the event
-- (not waiting for the next update-status tick) is what makes the flash prompt.
local function start_flash(window)
    copied_generation = copied_generation + 1
    local this_flash = copied_generation
    flash_on = true
    pcall(function()
        window:set_right_status(right_status())
    end)
    wezterm.time.call_after(COPIED_FLASH_SECONDS, function()
        if copied_generation == this_flash then
            flash_on = false
            pcall(function()
                window:set_right_status(right_status())
            end)
        end
    end)
end

-- Unconditional: emitted only by actions that always copy something (copy-mode
-- yank, double/triple-click word/line select). No selection check — which also
-- dodges a race where the just-created selection isn't yet readable here.
wezterm.on("copied", function(window)
    start_flash(window)
end)

-- Guarded: the streak-1 mouse binding fires on every left-click, and
-- Ctrl+Shift+C with nothing selected copies nothing, so these confirm a live
-- selection first. Reading it back is reliable here (the selection predates the
-- event), unlike the mouse-select paths above.
wezterm.on("copied-if-selection", function(window, pane)
    local ok, sel = pcall(function()
        return window:get_selection_text_for_pane(pane)
    end)
    if ok and sel and #sel > 0 then
        start_flash(window)
    end
end)

-- Behaviour
-- The right status only repaints when the tab bar is recomputed on this tick,
-- so the stock 1000ms makes the "copied" flash appear
-- up to a second late (and linger as long again). This bounds both to 100ms, at
-- the cost of running format-tab-title 10x more often. The metric values are
-- cached to ~1s regardless (see metrics_text), so this only affects the flash.
config.status_update_interval = 100
config.scrollback_lines = 10000
config.audible_bell = "Disabled"
config.enable_kitty_keyboard = true

-- Leader (mirrors tmux C-a prefix)
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

-- Wrap a copy action so it also flashes the indicator. Ctrl+Shift+C copies
-- nothing when there's no selection, so it uses the guarded event; EmitEvent
-- runs after the copy, while the selection is still live for the handler.
local function copy_and_flash(dest)
    return act.Multiple({ act.CopyTo(dest), act.EmitEvent("copied-if-selection") })
end

-- Double/triple-click always select something, so they flash unconditionally
-- via the plain "copied" event (no selection read to race against).
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
    -- Reorder: move the active tab left/right rather than just switching focus.
    { key = "n", mods = "LEADER|SHIFT", action = act.MoveTabRelative(1) },
    { key = "p", mods = "LEADER|SHIFT", action = act.MoveTabRelative(-1) },
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

-- Jump straight to a tab: LEADER + 1..8 (ActivateTab is 0-indexed); LEADER + 9
-- always lands on the last tab (tmux behaviour), regardless of tab count.
for i = 1, 8 do
    table.insert(config.keys, {
        key = tostring(i),
        mods = "LEADER",
        action = act.ActivateTab(i - 1),
    })
end
table.insert(config.keys, { key = "9", mods = "LEADER", action = act.ActivateTab(-1) })

-- Copy mode's `y` (LEADER [ above). Assigning key_tables.copy_mode replaces the
-- whole table, so start from the defaults and patch just the yank entry.
-- wezterm.gui is absent in the mux server, which also loads this file.
if wezterm.gui then
    local copy_mode = wezterm.gui.default_key_tables().copy_mode
    for _, entry in ipairs(copy_mode) do
        if entry.key == "y" and entry.mods == "NONE" then
            -- Yank always has a selection, so it flashes via the unconditional
            -- "copied" event; CopyTo before Close so the copy still happens.
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
            act.EmitEvent("copied-if-selection"),
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
