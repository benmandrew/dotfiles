local ok, wk = pcall(require, "which-key")
if not ok then
    vim.notify("which-key config skipped: plugin missing", vim.log.levels.WARN)
    return
end

wk.setup({})

-- Labels for existing binds so the popup reads in plain English. Press a prefix
-- (e.g. <leader>, then pause) to see these as a menu.
wk.add({
    -- Project / find (Telescope)
    { "<leader>p", group = "project" },
    { "<leader>pf", desc = "Find files" },
    { "<leader>pg", desc = "Live grep" },
    { "<leader>ps", desc = "Grep string (prompt)" },
    { "<leader>pb", desc = "Buffers" },
    { "<leader>pr", desc = "Resume last picker" },
    { "<leader>pv", desc = "File explorer (netrw)" },

    -- Git
    { "<leader>g", group = "git" },
    { "<leader>gs", desc = "Git status (fugitive)" },
    { "<leader>gd", desc = "Diff review (Diffview)" },
    { "<leader>gh", desc = "File history (current file)" },
    { "<leader>gH", desc = "File history (whole repo)" },
    { "<leader>gp", desc = "Preview hunk" },
    { "<leader>gb", desc = "Blame line" },
    { "<leader>gR", desc = "Reset hunk" },

    -- Harpoon
    { "<leader>a", desc = "Harpoon: add file" },
    { "<leader>1", desc = "Harpoon: file 1" },
    { "<leader>2", desc = "Harpoon: file 2" },
    { "<leader>3", desc = "Harpoon: file 3" },
    { "<leader>4", desc = "Harpoon: file 4" },

    -- Misc
    { "<leader>u", desc = "Undotree toggle" },

    -- Hunk / quickfix / diagnostic motions
    { "]c", desc = "Next git hunk" },
    { "[c", desc = "Previous git hunk" },
    { "]q", desc = "Next quickfix item" },
    { "[q", desc = "Previous quickfix item" },
    { "]d", desc = "Next diagnostic" },
    { "[d", desc = "Previous diagnostic" },
})
