return {
    on_init = function(client)
        -- No workspace folder when a single file is opened outside a project, so
        -- indexing [1] unguarded raised ON_INIT_CALLBACK_ERROR on every such buffer.
        local folder = client.workspace_folders and client.workspace_folders[1]
        if
            folder and (vim.uv.fs_stat(folder.name .. "/.luarc.json") or vim.uv.fs_stat(folder.name .. "/.luarc.jsonc"))
        then
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
                userThirdParty = { os.getenv("HOME") .. "/.local/share/LuaAddons/love2d/library" },
                checkThirdParty = "Apply",
            },
        },
    },
}
