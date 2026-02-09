local function warn_missing(name)
    vim.notify("Telescope config skipped: missing " .. name, vim.log.levels.WARN)
end

local ok, builtin = pcall(require, "telescope.builtin")
if not ok then
    warn_missing("telescope.builtin")
    return
end

vim.keymap.set("n", "<leader>pf", builtin.find_files, {})
vim.keymap.set("n", "<C-p>", builtin.git_files, {})
vim.keymap.set("n", "<leader>ps", function()
    builtin.grep_string({ search = vim.fn.input("Grep > ") })
end)
