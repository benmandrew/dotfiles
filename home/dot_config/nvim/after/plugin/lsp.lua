local function warn_missing(name)
	vim.notify("LSP config skipped: missing " .. name, vim.log.levels.WARN)
end

local ok_lsp_zero, lsp_zero = pcall(require, "lsp-zero")
if not ok_lsp_zero then
	warn_missing("lsp-zero")
	return
end

local ok_lspconfig, lspconfig = pcall(require, "lspconfig")
if not ok_lspconfig then
	warn_missing("nvim-lspconfig")
	return
end

lsp_zero.on_attach(function(client, bufnr)
	-- see :help lsp-zero-keybindings
	-- to learn the available actions
	lsp_zero.default_keymaps({ buffer = bufnr })
end)

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
				-- Tell the language server which version of Lua you're using
				-- (most likely LuaJIT in the case of Neovim)
				version = "LuaJIT",
			},
			diagnostics = {
				globals = {
					"love",
					"require",
				},
			},
			-- Make the server aware of Neovim runtime files
			workspace = {
				checkThirdParty = false,
				library = {
					vim.env.VIMRUNTIME,
					-- Depending on the usage, you might want to add additional paths here.
					-- "${3rd}/luv/library"
					-- "${3rd}/busted/library",
				},
				-- or pull in all of 'runtimepath'. NOTE: this is a lot slower
				-- library = vim.api.nvim_get_runtime_file("", true)
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
