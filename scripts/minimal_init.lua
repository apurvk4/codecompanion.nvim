vim.cmd([[let &rtp.=','.getcwd()]])
vim.cmd("set rtp+=deps/mini.nvim")
vim.cmd("set rtp+=deps/plenary.nvim")
vim.cmd("set rtp+=deps/nvim-treesitter")

if vim.fn.has("nvim-0.12") == 0 then
  local version = vim.version()
  error(("CodeCompanion tests require Neovim 0.12 or later; selected binary is %d.%d.%d"):format(
    version.major,
    version.minor,
    version.patch
  ))
end

if vim.fn.executable("tree-sitter") ~= 1 then
  error("CodeCompanion tests require the tree-sitter CLI (Arch-based Linux: sudo pacman -S tree-sitter-cli)")
end

-- Ensure mini.test is available
require("mini.test").setup()

-- Ensure consistent rendering
vim.o.termguicolors = true
vim.o.background = "dark"
vim.cmd("colorscheme default")

-- Install and setup Tree-sitter
require("nvim-treesitter").setup({
  install_dir = "deps/parsers",
})

local ok, err_or_ok = require("nvim-treesitter")
  .install({
    "lua",
    "make",
    "markdown",
    "markdown_inline",
    "yaml",
  }, { summary = true, max_jobs = 2 })
  :wait(1800000)

if not ok then
  error("Could not install required Tree-sitter parsers: " .. tostring(err_or_ok))
end

vim.treesitter.language.register("markdown", "codecompanion")

-- No test may reach the network. Anything that needs a response must stub the
-- layer it calls, be that the HTTP client's static methods or the adapter itself
local curl = require("codecompanion.utils.curl")
for _, method in ipairs({ "get", "post", "request", "get_sync", "post_sync", "request_sync" }) do
  curl[method] = function(opts)
    error(string.format("Test attempted a real HTTP request: %s %s", method:upper(), tostring(opts.url)))
  end
end
