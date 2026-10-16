-- Keybinding cheatsheet. wezterm.lua declares each binding through a sheet's
-- bind helpers, which record a group and a description beside the entry
-- WezTerm sees. The sheet then serves two views of the same rows: a fuzzy
-- picker (LEADER ?) that runs the chosen action, and an HTML page that adds
-- WezTerm's own defaults, read from wezterm.gui at the moment it is written.
local wezterm = require("wezterm")
local act = wezterm.action

local M = {}
M.__index = M

local KEY_NAMES = {
    LeftArrow = "←",
    RightArrow = "→",
    UpArrow = "↑",
    DownArrow = "↓",
    Escape = "Esc",
}

-- default_keys() spells some keys as the character they send. These are named
-- before the shift rule below, which would otherwise take a tab for punctuation.
local CHAR_NAMES = {
    ["\t"] = "Tab",
    ["\r"] = "Enter",
    ["\27"] = "Esc",
    ["\127"] = "Backspace",
    ["\8"] = "Backspace",
    [" "] = "Space",
}

function M.new(opts)
    return setmetatable({
        rows = {},
        leader = opts.leader,
        macos = opts.macos,
    }, M)
end

-- One keystroke in tmux notation: C-a, M-x, S-Tab, C-S-c, R for shift+r.
-- default_keys() spells keys as mapped:x or phys:X, and an uppercase letter
-- with no SHIFT is the same key as shift plus the lowercase one, so both are
-- folded first. Shift on a single punctuation character is dropped, since the
-- character already says it (`?`, not `S-/`).
function M:stroke(key, mods)
    key = key:gsub("^mapped:", ""):gsub("^phys:", "")
    key = CHAR_NAMES[key] or key
    local set = {}
    for m in (mods or ""):gmatch("%u+") do
        set[m] = true
    end
    set.NONE, set.LEADER = nil, nil
    if key:match("^%u$") then
        key, set.SHIFT = key:lower(), true
    end
    if set.SHIFT and utf8.len(key) == 1 then
        if not key:match("^%a$") then
            set.SHIFT = nil
        elseif not (set.CTRL or set.ALT or set.SUPER) then
            key, set.SHIFT = key:upper(), nil
        end
    end
    local prefix = (set.SUPER and (self.macos and "Cmd-" or "Super-") or "")
        .. (set.CTRL and "C-" or "")
        .. (set.ALT and "M-" or "")
        .. (set.SHIFT and "S-" or "")
    return prefix .. (KEY_NAMES[key] or key)
end

-- The whole chord as a list of strokes, the leader first where there is one.
function M:chord(key, mods)
    local strokes = {}
    if (mods or ""):find("LEADER") then
        table.insert(strokes, self:stroke(self.leader.key, self.leader.mods))
    end
    table.insert(strokes, self:stroke(key, mods))
    return strokes
end

-- A row is { group, desc, binds = { {key, mods}... }, action?, key_table?,
-- keys? }. keys overrides the chords drawn from binds, for a row that stands
-- for a run of bindings (LEADER 1 to 8) and would otherwise list each one.
function M:add(row)
    if not row.keys then
        row.keys = {}
        for _, b in ipairs(row.binds) do
            table.insert(row.keys, self:chord(b.key, b.mods))
        end
    end
    table.insert(self.rows, row)
end

-- Bind into `keys` (config.keys, or a key table's list) and record the row.
function M:bind(keys, group, key, mods, action, desc)
    table.insert(keys, { key = key, mods = mods, action = action })
    self:add({
        group = group,
        desc = desc,
        binds = { { key = key, mods = mods } },
        action = action,
    })
end

local function join_keys(alternatives)
    local out = {}
    for _, strokes in ipairs(alternatives) do
        table.insert(out, table.concat(strokes, " "))
    end
    return table.concat(out, " / ")
end

local function pad(s, width)
    return s .. string.rep(" ", math.max(1, width - utf8.len(s)))
end

-- Warn about any binding in config.keys or a key table of our own that no
-- row describes, so a raw table.insert cannot slip past the cheatsheet.
-- copy_mode and search_mode are WezTerm's tables and the page lists them.
function M:check(config)
    local seen = {}
    for _, row in ipairs(self.rows) do
        for _, b in ipairs(row.binds) do
            seen[(row.key_table or "") .. " " .. table.concat(self:chord(b.key, b.mods), " ")] = true
        end
    end
    local function walk(name, entries)
        for _, e in ipairs(entries) do
            local chord = table.concat(self:chord(e.key, e.mods), " ")
            if not seen[(name or "") .. " " .. chord] then
                wezterm.log_warn("cheatsheet: no description for " .. (name and name .. " " or "") .. chord)
            end
        end
    end
    walk(nil, config.keys or {})
    for name, entries in pairs(config.key_tables or {}) do
        if name ~= "copy_mode" and name ~= "search_mode" then
            walk(name, entries)
        end
    end
end

-- Picker colours, the page's: gold keys, body-text descriptions, muted groups.
local PICKER = { keys = "#ebc587", desc = "#c9c9c9", group = "#ac9166", accent = "#d08949" }

local function label(keys, desc, group, desc_colour)
    return wezterm.format({
        { Foreground = { Color = PICKER.keys } },
        { Text = pad(keys, 22) },
        { Foreground = { Color = desc_colour or PICKER.desc } },
        { Text = pad(desc, 46) },
        { Foreground = { Color = PICKER.group } },
        { Attribute = { Italic = true } },
        { Text = group },
    })
end

-- The picker lists the main table's rows; key-table rows only make sense
-- inside their table. Choosing a row runs its action, so the sheet doubles as
-- a command palette for anything whose key has been forgotten.
function M:picker()
    return wezterm.action_callback(function(window, pane)
        local choices, actions = {}, {}
        for i, row in ipairs(self.rows) do
            if not row.key_table then
                table.insert(choices, {
                    id = tostring(i),
                    label = label(join_keys(row.keys), row.desc, row.group),
                })
                actions[tostring(i)] = row.action
            end
        end
        table.insert(choices, {
            id = "html",
            label = label("", "Open the full cheatsheet in a browser", "", PICKER.accent),
        })
        window:perform_action(
            act.InputSelector({
                title = "Keys",
                fuzzy = true,
                fuzzy_description = wezterm.format({
                    { Foreground = { Color = PICKER.accent } },
                    { Text = "Key, action or group: " },
                }),
                choices = choices,
                action = wezterm.action_callback(function(win, p, id)
                    if id == "html" then
                        self:open_html(win)
                    elseif id and actions[id] then
                        win:perform_action(actions[id], p)
                    end
                end),
            }),
            pane
        )
    end)
end

-- Default actions as a sentence: { ActivateTabRelative = 1 } reads
-- "Activate tab relative 1". CopyMode is implied by its table, so dropped.
local function words(name)
    return (name:gsub("_", " "):gsub("(%l)(%u)", function(a, b)
        return a .. " " .. b:lower()
    end))
end

local function describe_action(a)
    if type(a) == "string" then
        return words(a)
    elseif type(a) ~= "table" then
        return tostring(a)
    end
    if a[1] ~= nil then
        local parts = {}
        for _, v in ipairs(a) do
            table.insert(parts, describe_action(v))
        end
        return table.concat(parts, ", ")
    end
    local k, v = next(a)
    if k == nil or next(a, k) ~= nil then
        return ""
    end
    if k == "ActivateTab" then
        return v < 0 and "Go to the last tab" or ("Go to tab " .. (v + 1))
    end
    local rest = describe_action(v)
    if k == "CopyMode" then
        return rest
    end
    return words(k) .. (rest ~= "" and " " .. rest:sub(1, 1):lower() .. rest:sub(2) or "")
end

-- Defaults are filed by the first word of the action's name.
local DEFAULT_GROUPS = {
    { "Tab", "Tabs" },
    { "Pane", "Panes" },
    { "Split", "Panes" },
    { "Copy", "Clipboard" },
    { "Paste", "Clipboard" },
    { "Font", "Font size" },
    { "Scroll", "Scrollback" },
    { "Search", "Scrollback" },
    { "Window", "Window" },
    { "FullScreen", "Window" },
    { "Hide", "Window" },
}

local function default_group(action)
    local name = type(action) == "string" and action or next(action) or ""
    for _, g in ipairs(DEFAULT_GROUPS) do
        if name:find(g[1]) then
            return g[2]
        end
    end
    return "Other"
end

-- WezTerm's defaults the config leaves in force, merged so one action lists
-- every chord that reaches it. A chord any row of ours binds is overridden.
function M:defaults()
    local ours = {}
    for _, row in ipairs(self.rows) do
        for _, b in ipairs(row.binds) do
            ours[(row.key_table or "") .. " " .. table.concat(self:chord(b.key, b.mods), " ")] = true
        end
    end
    local rows, by_action = {}, {}
    local function take(key_table, group_of, entries)
        for _, e in ipairs(entries) do
            local chord = table.concat(self:chord(e.key, e.mods), " ")
            if not ours[(key_table or "") .. " " .. chord] then
                local desc = describe_action(e.action)
                local id = (key_table or "") .. " " .. wezterm.to_string(e.action)
                local row = by_action[id]
                if not row then
                    row = { group = group_of(e.action), desc = desc, keys = {}, seen = {} }
                    by_action[id] = row
                    table.insert(rows, row)
                end
                if not row.seen[chord] then
                    row.seen[chord] = true
                    table.insert(row.keys, { chord })
                end
            end
        end
    end
    take(nil, default_group, wezterm.gui.default_keys())
    local tables = wezterm.gui.default_key_tables()
    local leader = self:stroke(self.leader.key, self.leader.mods)
    take("copy_mode", function()
        return "Copy mode, after " .. leader .. " ["
    end, tables.copy_mode)
    take("search_mode", function()
        return "Search mode"
    end, tables.search_mode)
    local rank = {}
    for i, g in ipairs(DEFAULT_GROUPS) do
        rank[g[2]] = rank[g[2]] or i
    end
    rank.Other = #DEFAULT_GROUPS + 1
    table.sort(rows, function(a, b)
        local ra, rb = rank[a.group] or 99, rank[b.group] or 99
        if ra ~= rb then
            return ra < rb
        elseif a.group ~= b.group then
            return a.group < b.group
        end
        return a.desc < b.desc
    end)
    return rows
end

local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function render_groups(rows, class)
    local order, groups = {}, {}
    for _, row in ipairs(rows) do
        if not groups[row.group] then
            groups[row.group] = {}
            table.insert(order, row.group)
        end
        table.insert(groups[row.group], row)
    end
    local out = {}
    for _, name in ipairs(order) do
        table.insert(out, '<section class="card ' .. class .. '"><h2>' .. escape(name) .. "</h2><table>")
        for _, row in ipairs(groups[name]) do
            local alts = {}
            for _, strokes in ipairs(row.keys) do
                local kbd = {}
                for _, s in ipairs(strokes) do
                    table.insert(kbd, "<kbd>" .. escape(s) .. "</kbd>")
                end
                table.insert(alts, '<span class="alt">' .. table.concat(kbd, " ") .. "</span>")
            end
            table.insert(
                out,
                "<tr><th>"
                    .. table.concat(alts, ' <span class="or">or</span> ')
                    .. "</th><td>"
                    .. escape(row.desc)
                    .. "</td></tr>"
            )
        end
        table.insert(out, "</table></section>")
    end
    return table.concat(out, "\n")
end

-- Palette and type from benmandrew.com: Libertinus Serif over a near-black
-- ground, Iosevka Slab for keys, burnt-orange accents. The site's fonts send
-- no CORS header, so a page opened from disk falls back down the same stacks.
local STYLE = [[
:root {
  color-scheme: dark;
  --bg: #141414; --surface: #191918; --border: #464444; --text: #c9c9c9;
  --muted: #ac9166; --heading: #f1eee7; --accent: #d08949; --accent-hi: #ebc587;
  --code-bg: #1d1b18; --code-edge: #2c2925;
  --serif: "Libertinus Serif", Georgia, "Times New Roman", serif;
  --mono: "Iosevka Slab Extended", "JetBrains Mono", ui-monospace, Menlo, monospace;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font-family: var(--serif); font-size: 1.1rem;
}
header {
  background: var(--surface); padding: 14px 16px;
  display: flex; flex-wrap: wrap; gap: .75rem 1.5rem; align-items: center;
}
header h1 { margin: 0; font-size: 1.25rem; font-weight: 400; color: var(--heading); }
header p { margin: 0; color: var(--muted); font-size: .9rem; flex: 1; }
input {
  background: var(--bg); color: var(--text); border: 1px solid var(--border); border-radius: 4px;
  font: inherit; font-size: 1rem; padding: .35rem .6rem; width: 16rem; max-width: 100%;
}
input:focus-visible { outline: 2px solid var(--heading); outline-offset: 2px; }
main { max-width: 96rem; margin: 0 auto; padding: 2rem 16px 6rem; }
main > h2 { font-weight: 400; color: var(--heading); margin: 0 0 1rem; }
main > h2 + .grid { margin-bottom: 3rem; }
.bar {
  display: inline-block; width: 8px; height: 1.4rem; margin-left: .3em; vertical-align: middle;
  background: repeating-linear-gradient(90deg, currentColor 8px, currentColor 10px,
    transparent 11px, transparent 16px);
}
.grid { columns: 22rem; column-gap: 1rem; }
.card {
  break-inside: avoid; background: var(--surface); border: 1px solid var(--border);
  border-radius: 4px; padding: .9rem 1rem; margin: 0 0 1rem;
}
.card h2 { margin: 0 0 .5rem; font-size: 1.15rem; font-weight: 700; color: var(--accent); }
.card.default h2 { color: var(--muted); }
table { border-collapse: collapse; width: 100%; table-layout: fixed; }
th, td {
  text-align: left; vertical-align: baseline; padding: .3rem 0;
  border-top: 1px solid var(--code-edge);
}
tr:first-child th, tr:first-child td { border-top: 0; }
th { font-weight: 400; padding-right: 1rem; width: 40%; }
.card.mine th { width: 9.5rem; }
.alt { white-space: nowrap; }
.card.default td { color: var(--muted); }
kbd {
  font-family: var(--mono); font-size: .8rem; color: var(--accent-hi);
  background: var(--code-bg); border: 1px solid var(--code-edge); border-radius: .3em; padding: .1em .4em;
}
.or { color: var(--muted); font-size: .8rem; }
.hidden { display: none; }
]]

local SCRIPT = [[
const q = document.querySelector("input");
q.addEventListener("input", () => {
  const terms = q.value.toLowerCase().split(/\s+/).filter(Boolean);
  for (const card of document.querySelectorAll(".card")) {
    const group = card.querySelector("h2").textContent.toLowerCase();
    let shown = 0;
    for (const tr of card.querySelectorAll("tr")) {
      const text = group + " " + tr.textContent.toLowerCase();
      const hit = terms.every(t => text.includes(t));
      tr.classList.toggle("hidden", !hit);
      shown += hit;
    }
    card.classList.toggle("hidden", shown === 0);
  }
});
document.addEventListener("keydown", e => {
  if (e.key === "/" && document.activeElement !== q) { e.preventDefault(); q.focus(); }
  if (e.key === "Escape") { q.value = ""; q.dispatchEvent(new Event("input")); q.blur(); }
});
]]

function M:html()
    local leader = self:stroke(self.leader.key, self.leader.mods)
    return table.concat({
        '<!doctype html><html lang="en"><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>WezTerm keys</title><style>" .. STYLE .. "</style>",
        "<header><h1>WezTerm keys</h1><p>Leader is <kbd>" .. escape(leader) .. "</kbd>. Written " .. os.date(
            "%Y-%m-%d %H:%M"
        ) .. " from wezterm.lua.</p>",
        '<input type="search" placeholder="Filter  ( / )" aria-label="Filter bindings"></header>',
        '<main><h2>Mine<span class="bar"></span></h2><div class="grid">',
        render_groups(self.rows, "mine"),
        '</div><h2>WezTerm defaults<span class="bar"></span></h2><div class="grid">',
        render_groups(self:defaults(), "default"),
        "</div></main><script>" .. SCRIPT .. "</script></html>",
    }, "\n")
end

-- Snap confinement keeps Ubuntu's Firefox out of every dot-directory in the
-- home directory, ~/.cache included, so where the snap is installed the page
-- goes in the one folder it can read. Looked up when the page is written,
-- rather than on every config load.
local function page_path()
    local snap = wezterm.glob(wezterm.home_dir .. "/snap/firefox/common")[1]
    local dir = snap or os.getenv("XDG_CACHE_HOME") or (wezterm.home_dir .. "/.cache")
    return dir .. "/wezterm-keys.html"
end

function M:open_html(window)
    local path = page_path()
    local f, err = io.open(path, "w")
    if not f then
        window:toast_notification("wezterm", "Cannot write " .. path .. ": " .. tostring(err), nil, 4000)
        return
    end
    f:write(self:html())
    f:close()
    wezterm.open_with("file://" .. path)
end

return M
