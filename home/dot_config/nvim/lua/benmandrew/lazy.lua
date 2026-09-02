local fn = vim.fn

local lazypath = fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
    fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable",
        lazypath,
    })
end

vim.opt.rtp:prepend(lazypath)

-- Every spec loads on a key, a command or an event. An after/plugin/ file would
-- require() the plugin during startup and defeat all of it.
require("lazy").setup({
    {
        "nvim-telescope/telescope.nvim",
        cmd = "Telescope",
        dependencies = {
            "nvim-lua/plenary.nvim",
            {
                -- C sorter; the pure-Lua one is slow on a large tree. `cond` keeps it
                -- off the runtime path when `make` is absent and the build never ran,
                -- so telescope falls back rather than erroring on load_extension.
                "nvim-telescope/telescope-fzf-native.nvim",
                build = "make",
                cond = function()
                    return fn.executable("make") == 1
                end,
            },
        },
        keys = {
            {
                "<leader>pf",
                function()
                    require("telescope.builtin").find_files()
                end,
            },
            {
                "<C-p>",
                function()
                    require("telescope.builtin").git_files()
                end,
            },
            {
                "<leader>pg",
                function()
                    require("telescope.builtin").live_grep()
                end,
            },
            {
                "<leader>pb",
                function()
                    require("telescope.builtin").buffers()
                end,
            },
            {
                "<leader>pr",
                function()
                    require("telescope.builtin").resume()
                end,
            },
            {
                "<leader>ps",
                function()
                    require("telescope.builtin").grep_string({ search = fn.input("Grep > ") })
                end,
            },
        },
        config = function()
            local telescope = require("telescope")
            telescope.setup({})
            pcall(telescope.load_extension, "fzf")
        end,
    },
    {
        "catppuccin/nvim",
        name = "catppuccin",
        priority = 1000,
        config = function()
            require("catppuccin").setup({})
            vim.cmd.colorscheme("catppuccin-mocha")
        end,
    },
    {
        "nvim-treesitter/nvim-treesitter",
        lazy = false,
        build = ":TSUpdate",
        config = function()
            require("nvim-treesitter.configs").setup({
                -- A list of parser names, or "all" (the five listed parsers should always be installed)
                ensure_installed = {
                    "ocaml",
                    "javascript",
                    "python",
                    "rust",
                    "c",
                    "lua",
                    "vim",
                    "vimdoc",
                    "query",
                },

                -- Install parsers synchronously (only applied to `ensure_installed`)
                sync_install = false,

                -- Automatically install missing parsers when entering buffer
                -- Recommendation: set to false if you don't have `tree-sitter` CLI installed locally
                auto_install = true,

                highlight = {
                    enable = true,

                    -- Setting this to true will run `:h syntax` and tree-sitter at the same time.
                    -- Set this to `true` if you depend on 'syntax' being enabled (like for indentation).
                    -- Using this option may slow down your editor, and you may see some duplicate highlights.
                    -- Instead of true it can also be a list of languages
                    additional_vim_regex_highlighting = false,
                },
            })
        end,
    },
    {
        "mbbill/undotree",
        cmd = { "UndotreeToggle", "UndotreeShow", "UndotreeFocus" },
        keys = { { "<leader>u", vim.cmd.UndotreeToggle } },
    },
    {
        "tpope/vim-fugitive",
        cmd = { "Git", "G", "Gdiffsplit", "Gread", "Gwrite", "Gclog" },
        keys = { { "<leader>gs", vim.cmd.Git } },
    },
    {
        "neovim/nvim-lspconfig",
        -- Wanted for its bundled per-server configs under lsp/ alone; enabling goes
        -- through the native 0.11+ vim.lsp.enable, not lspconfig's own .setup{}.
        event = { "BufReadPre", "BufNewFile" },
        config = function()
            vim.api.nvim_create_autocmd("LspAttach", {
                callback = function(args)
                    local opts = { buffer = args.buf }
                    -- gri/grr/grn/gra/gO are 0.11 defaults and are deliberately not
                    -- re-bound here. Descriptions live in the which-key block below.
                    vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
                    vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
                    vim.keymap.set("n", "gD", vim.lsp.buf.declaration, opts)
                    vim.keymap.set("n", "go", vim.lsp.buf.type_definition, opts)
                    vim.keymap.set("n", "gs", vim.lsp.buf.signature_help, opts)
                    vim.keymap.set("n", "<F2>", vim.lsp.buf.rename, opts)
                    vim.keymap.set("n", "<F3>", function()
                        vim.lsp.buf.format({ async = true })
                    end, opts)
                    vim.keymap.set("n", "<F4>", vim.lsp.buf.code_action, opts)
                    vim.keymap.set("n", "gl", vim.diagnostic.open_float, opts)
                    vim.keymap.set("n", "[d", function()
                        vim.diagnostic.jump({ count = -1, float = true })
                    end, opts)
                    vim.keymap.set("n", "]d", function()
                        vim.diagnostic.jump({ count = 1, float = true })
                    end, opts)

                    -- Neovim 0.12's own completion, in place of nvim-cmp. The menu
                    -- itself comes from 'autocomplete' plus the "o" flag in 'complete'
                    -- (see benmandrew/init.lua); this call is what makes accepting an
                    -- item run the server's snippet expansion and additional text
                    -- edits. No autotrigger: 'autocomplete' already asks the server on
                    -- every keystroke, so the trigger characters only duplicate the
                    -- request and the menu flickers back to an unfiltered list between
                    -- the two. Confirmed by driving nvim over a pseudo-terminal.
                    vim.lsp.completion.enable(true, args.data.client_id, args.buf)
                end,
            })

            vim.lsp.enable({
                "bashls",
                "clangd",
                "lua_ls",
                "ocamllsp",
                "rust_analyzer",
            })
        end,
    },
    {
        "stevearc/conform.nvim",
        event = "BufWritePre",
        cmd = { "ConformInfo", "FormatToggle" },
        keys = {
            {
                "<leader>f",
                function()
                    require("conform").format({ async = true })
                end,
                mode = { "n", "x" },
            },
            { "<leader>tf", "<cmd>FormatToggle<cr>" },
        },
        opts = {
            formatters_by_ft = {
                lua = { "stylua" },
                sh = { "shfmt" },
                bash = { "shfmt" }, -- No zsh: shfmt does not parse it.
                c = { "clang_format" },
                cpp = { "clang_format" },
                python = { "ruff_organize_imports", "ruff_format" },
                toml = { "taplo" },
                ocaml = { "ocamlformat" },
            },
            formatters = {
                -- Match `make fmt`, which runs shfmt -i 4 -ci.
                shfmt = { prepend_args = { "-ci" } },
            },
            -- Fall through to the language server where the formatter binary is not
            -- installed, so a missing tool costs formatting quality rather than erroring.
            default_format_opts = { lsp_format = "fallback" },
            format_on_save = function(bufnr)
                if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
                    return nil
                end
                return { timeout_ms = 500 }
            end,
        },
        config = function(_, opts)
            require("conform").setup(opts)
            -- :FormatToggle for this buffer, :FormatToggle! for the session.
            vim.api.nvim_create_user_command("FormatToggle", function(args)
                if args.bang then
                    vim.g.disable_autoformat = not vim.g.disable_autoformat
                else
                    vim.b.disable_autoformat = not vim.b.disable_autoformat
                end
            end, { bang = true, desc = "Toggle format-on-save" })
        end,
    },
    {
        "lewis6991/gitsigns.nvim",
        event = { "BufReadPre", "BufNewFile" },
        config = function()
            local gitsigns = require("gitsigns")

            -- ]c and [c are the real diff motions. Take them over only outside a
            -- diff window, where they would otherwise do nothing.
            local function nav_hunk(direction)
                return function()
                    if vim.wo.diff then
                        vim.cmd.normal({ direction == "next" and "]c" or "[c", bang = true })
                    else
                        gitsigns.nav_hunk(direction)
                    end
                end
            end

            gitsigns.setup({
                on_attach = function(bufnr)
                    local opts = { buffer = bufnr }

                    -- Jump between changed hunks
                    vim.keymap.set("n", "]c", nav_hunk("next"), opts)
                    vim.keymap.set("n", "[c", nav_hunk("prev"), opts)

                    -- Inspect / accept / reject an individual hunk without leaving the buffer
                    vim.keymap.set("n", "<leader>gp", gitsigns.preview_hunk, opts)
                    vim.keymap.set("n", "<leader>gb", gitsigns.blame_line, opts)
                    vim.keymap.set("n", "<leader>gR", gitsigns.reset_hunk, opts)
                end,
            })
        end,
    },
    {
        -- Review a whole changeset (e.g. everything an agent just touched) as a file
        -- tree of side-by-side diffs. <leader>gd opens; `q` or :DiffviewClose exits.
        "sindrets/diffview.nvim",
        dependencies = { "nvim-lua/plenary.nvim" },
        cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
        keys = {
            { "<leader>gd", vim.cmd.DiffviewOpen },
            {
                "<leader>gh",
                function()
                    vim.cmd.DiffviewFileHistory("%")
                end,
            },
            { "<leader>gH", vim.cmd.DiffviewFileHistory },
        },
    },
    {
        -- Pin the file you're on, then jump straight back to it later.
        "ThePrimeagen/harpoon",
        branch = "harpoon2",
        dependencies = { "nvim-lua/plenary.nvim" },
        keys = function()
            -- <C-e> is scroll-down-one-line and stays that way; the menu is on <leader>h.
            local keys = {
                {
                    "<leader>a",
                    function()
                        require("harpoon"):list():add()
                    end,
                },
                {
                    "<leader>h",
                    function()
                        local harpoon = require("harpoon")
                        harpoon.ui:toggle_quick_menu(harpoon:list())
                    end,
                },
            }
            for i = 1, 4 do
                table.insert(keys, {
                    "<leader>" .. i,
                    function()
                        require("harpoon"):list():select(i)
                    end,
                })
            end
            return keys
        end,
        config = function()
            require("harpoon"):setup()
        end,
    },
    {
        "folke/which-key.nvim",
        event = "VeryLazy",
        config = function()
            local wk = require("which-key")
            wk.setup({})

            -- Labels for existing binds so the popup reads in plain English. Press a prefix
            -- (e.g. <leader>, then pause) to see these as a menu. Registered here rather
            -- than as keymap descs so the LSP entries appear before a server attaches.
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
                { "<leader>h", desc = "Harpoon: quick menu" },
                { "<leader>1", desc = "Harpoon: file 1" },
                { "<leader>2", desc = "Harpoon: file 2" },
                { "<leader>3", desc = "Harpoon: file 3" },
                { "<leader>4", desc = "Harpoon: file 4" },

                -- Formatting
                { "<leader>f", desc = "Format buffer", mode = { "n", "x" } },
                { "<leader>t", group = "toggle" },
                { "<leader>tf", desc = "Toggle format-on-save (buffer)" },

                -- Misc
                { "<leader>u", desc = "Undotree toggle" },
                { "<leader>d", desc = "Delete to black hole", mode = { "n", "x" } },

                -- LSP (buffer-local, live once a server attaches)
                { "K", desc = "Hover documentation" },
                { "gd", desc = "Go to definition" },
                { "gD", desc = "Go to declaration" },
                { "go", desc = "Go to type definition" },
                { "gs", desc = "Signature help" },
                { "gl", desc = "Show diagnostic float" },
                { "<F2>", desc = "Rename symbol" },
                { "<F3>", desc = "Format buffer (LSP)" },
                { "<F4>", desc = "Code action" },

                -- LSP defaults shipped by Neovim 0.11
                { "gr", group = "lsp" },
                { "grr", desc = "References" },
                { "gri", desc = "Implementations" },
                { "grn", desc = "Rename symbol" },
                { "gra", desc = "Code action" },
                { "grt", desc = "Type definition" },
                { "gO", desc = "Document symbols" },

                -- Hunk / diagnostic motions
                { "]c", desc = "Next git hunk" },
                { "[c", desc = "Previous git hunk" },
                { "]d", desc = "Next diagnostic" },
                { "[d", desc = "Previous diagnostic" },
            })
        end,
    },
})
