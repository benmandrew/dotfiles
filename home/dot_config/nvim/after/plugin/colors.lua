local ok, catppuccin = pcall(require, "catppuccin")
if not ok then
    vim.notify("Colorscheme not applied: missing catppuccin", vim.log.levels.WARN)
    return
end

catppuccin.setup({})
pcall(vim.cmd.colorscheme, "catppuccin-mocha")
