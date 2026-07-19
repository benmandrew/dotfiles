local ok, _ = pcall(require, "diffview")
if not ok then
    vim.notify("diffview config skipped: plugin missing", vim.log.levels.WARN)
    return
end

-- Review a whole changeset (e.g. everything an agent just touched) as a file
-- tree of side-by-side diffs. <leader>gd opens; `q` or :DiffviewClose exits.
vim.keymap.set("n", "<leader>gd", vim.cmd.DiffviewOpen)
vim.keymap.set("n", "<leader>gh", function()
    vim.cmd.DiffviewFileHistory("%")
end)
vim.keymap.set("n", "<leader>gH", vim.cmd.DiffviewFileHistory)
