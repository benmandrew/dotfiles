local function warn_missing(name)
    vim.notify("LSP config skipped: missing " .. name, vim.log.levels.WARN)
end

local ok_lsp_zero, lsp_zero = pcall(require, "lsp-zero")
if not ok_lsp_zero then
    warn_missing("lsp-zero")
    return
end

lsp_zero.on_attach(function(_client, bufnr)
    lsp_zero.default_keymaps({ buffer = bufnr })
end)

-- local original_notify = vim.notify
-- vim.notify = function(msg, ...)
--   if type(msg) == "string" and msg:lower():match("`require%('lspconfig'%)` \"framework\" is deprecated") then
--     return
--   end
--   if type(msg) == "string" and msg:lower():match("require%('lspconfig'%) \"framework\" is deprecated") then
--     return
--   end
--   original_notify(msg, ...)
-- end
local lspconfig = require("lspconfig")

lspconfig.bashls.setup({})
lspconfig.rust_analyzer.setup({})
lspconfig.ocamllsp.setup({})
lspconfig.lua_ls.setup({
    on_init = function(client)
        local path = client.workspace_folders[1].name
        if vim.loop.fs_stat(path .. "/.luarc.json") or vim.loop.fs_stat(path .. "/.luarc.jsonc") then
            return
        end
        client.config.settings.Lua = vim.tbl_deep_extend("force", client.config.settings.Lua, {
            runtime = {
                version = "LuaJIT",
            },
            diagnostics = {
                globals = { "love", "require" },
            },
            workspace = {
                checkThirdParty = false,
                library = {
                    vim.env.VIMRUNTIME,
                },
            },
        })
    end,
    settings = {
        Lua = {
            workspace = {
                userThirdParty = { os.getenv("HOME") .. ".local/share/LuaAddons/love2d/library" },
                checkThirdParty = "Apply",
            },
        },
    },
})
