vim.g.mapleader = " "
vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)

-- Quickfix navigation (walk grep hits sent from Telescope via <C-q>)
vim.keymap.set("n", "]q", vim.cmd.cnext)
vim.keymap.set("n", "[q", vim.cmd.cprev)
