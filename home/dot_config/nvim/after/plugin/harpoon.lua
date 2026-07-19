local ok, harpoon = pcall(require, "harpoon")
if not ok then
    vim.notify("harpoon config skipped: plugin missing", vim.log.levels.WARN)
    return
end

harpoon:setup()

-- Pin the file you're on, then jump straight back to it later.
vim.keymap.set("n", "<leader>a", function()
    harpoon:list():add()
end)
-- Toggle the quick menu of pinned files.
vim.keymap.set("n", "<C-e>", function()
    harpoon.ui:toggle_quick_menu(harpoon:list())
end)

-- Jump directly to pinned file 1-4.
for i = 1, 4 do
    vim.keymap.set("n", "<leader>" .. i, function()
        harpoon:list():select(i)
    end)
end
