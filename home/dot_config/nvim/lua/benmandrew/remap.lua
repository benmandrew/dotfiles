vim.g.mapleader = " "
vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)

-- Copy-on-select: releasing a mouse drag yanks the visual selection to the system
-- clipboard, matching terminal behaviour. 'mouse=a' means nvim swallows the drag, so
-- neither WezTerm's nor tmux's copy-on-select ever sees it.
vim.keymap.set("x", "<LeftRelease>", '"+y<LeftRelease>')

-- 'clipboard=unnamedplus' routes every delete through the system clipboard, so a
-- stray x wipes what you copied out of the browser. These send the destructive
-- cases to the black hole instead; plain d and c still yank, deliberately.
vim.keymap.set({ "n", "x" }, "<leader>d", '"_d')
vim.keymap.set("n", "x", '"_x')
-- No `p` remap to keep the register over a visual paste: the built-in visual P
-- already does that, and '"_dP' pasted in the wrong place at the end of a line.
