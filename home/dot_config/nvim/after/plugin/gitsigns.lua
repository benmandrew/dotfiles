local ok, gitsigns = pcall(require, "gitsigns")
if not ok then
    vim.notify("gitsigns config skipped: plugin missing", vim.log.levels.WARN)
    return
end

gitsigns.setup({
    on_attach = function(bufnr)
        local opts = { buffer = bufnr }

        -- Jump between changed hunks
        vim.keymap.set("n", "]c", function()
            gitsigns.nav_hunk("next")
        end, opts)
        vim.keymap.set("n", "[c", function()
            gitsigns.nav_hunk("prev")
        end, opts)

        -- Inspect / accept / reject an individual hunk without leaving the buffer
        vim.keymap.set("n", "<leader>gp", gitsigns.preview_hunk, opts)
        vim.keymap.set("n", "<leader>gb", gitsigns.blame_line, opts)
        vim.keymap.set("n", "<leader>gR", gitsigns.reset_hunk, opts)
    end,
})
