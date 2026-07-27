vim.g.mapleader = " "
vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)

-- Copy-on-select: releasing a mouse drag yanks the visual selection to the system
-- clipboard, matching terminal behaviour. 'mouse=a' means nvim swallows the drag, so
-- neither WezTerm's nor tmux's copy-on-select ever sees it.
vim.keymap.set("x", "<LeftRelease>", '"+y<LeftRelease>')

-- Quickfix navigation (walk grep hits sent from Telescope via <C-q>)
vim.keymap.set("n", "]q", vim.cmd.cnext)
vim.keymap.set("n", "[q", vim.cmd.cprev)
