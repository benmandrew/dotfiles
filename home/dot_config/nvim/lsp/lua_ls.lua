return {
    on_init = function(client)
        local path = client.workspace_folders[1].name
        if vim.uv.fs_stat(path .. "/.luarc.json") or vim.uv.fs_stat(path .. "/.luarc.jsonc") then
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
}
