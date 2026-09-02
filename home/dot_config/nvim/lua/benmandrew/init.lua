-- local global = vim.g
local o = vim.opt

o.number = true -- Print the line number in front of each line
o.relativenumber = true -- Show the line number relative to the line with the cursor in front of each line.
o.autoindent = true -- Copy indent from current line when starting a new line.
o.encoding = "UTF-8" -- Sets the character encoding used inside Vim.
o.ruler = true -- Show the line and column number of the cursor position, separated by a comma.
o.mouse = "a" -- Enable the use of the mouse. "a" you can use on all modes
o.title = true -- When on, the title of the window will be set to the value of 'titlestring'
o.clipboard = "unnamedplus" -- Yank/delete go to the system clipboard (pbcopy on macOS,
-- xclip/wl-copy on Linux, OSC 52 over SSH). See the black-hole maps in remap.lua.
o.termguicolors = true -- Catppuccin is a 24-bit palette; without this it degrades to 256 colours.

-- Four spaces everywhere. The defaults are hard tabs at width 8, which corrupts
-- this repo's own Lua on the first edit.
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.softtabstop = 4

o.undofile = true -- Persist undo across sessions; undotree sees only the current one otherwise.

o.ignorecase = true -- Search ignores case...
o.smartcase = true -- ...unless the pattern carries a capital.

o.signcolumn = "yes" -- Fixed width. "auto" makes gitsigns shift the text sideways on every edit.
o.updatetime = 250 -- The 4000 ms default lags gitsigns' current_line_blame by four seconds.
o.scrolloff = 8 -- Keep context above and below the cursor.
o.splitright = true
o.splitbelow = true
o.cursorline = true

-- Neovim 0.12's built-in completion, in place of nvim-cmp. 'autocomplete' opens
-- the menu as you type, drawing on the sources in 'complete'; the "o" flag is the
-- one that reaches the language server, through the 'omnifunc' the LSP client
-- installs. Without it the menu offers buffer words alone. The caps keep any one
-- source from filling the menu. vim.lsp.completion.enable() in the LspAttach
-- autocmd (see lazy.lua) is what makes accepting an item apply the server's
-- snippet expansion and additional edits.
o.autocomplete = true
o.complete = { ".^5", "w^5", "b^5", "u^5", "o" }
o.completeopt = { "menu", "menuone", "noselect", "popup", "fuzzy" }

-- virtual_text defaults to false on 0.11+, so without this diagnostics show as a
-- sign and an underline with no message until gl.
vim.diagnostic.config({
    virtual_text = { spacing = 2, prefix = "●" },
    underline = true,
    severity_sort = true, -- Errors win the sign column over warnings on a shared line.
    float = { border = "rounded", source = true },
})

require("benmandrew.remap")
require("benmandrew.lazy")
