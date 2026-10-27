all: format docs test

NVIM ?= nvim
TREE_SITTER ?= tree-sitter
LUACHECK ?= $(or $(shell command -v luacheck 2>/dev/null),deps/luacheck/bin/luacheck)

.PHONY: check_lint_env check_test_env lint

docs: deps/panvimdoc
	@echo Generating Docs...
	@pandoc \
		--metadata="project:codecompanion" \
		--metadata="vimversion:NVIM v0.11" \
		--metadata="titledatepattern:%Y %B %d" \
		--metadata="toc:true" \
		--metadata="incrementheadinglevelby:0" \
		--metadata="treesitter:true" \
		--metadata="dedupsubheadings:true" \
		--metadata="ignorerawblocks:true" \
		--metadata="docmapping:false" \
		--metadata="docmappingproject:true" \
		--lua-filter scripts/panvimdoc-code-groups.lua \
		--lua-filter deps/panvimdoc/scripts/include-files.lua \
		--lua-filter deps/panvimdoc/scripts/skip-blocks.lua \
		--lua-filter scripts/panvimdoc-cleanup.lua \
		-t deps/panvimdoc/scripts/panvimdoc.lua \
		scripts/vimdoc.md \
		-o doc/codecompanion.txt

format:
	@echo Formatting...
	@stylua tests/ lua/ -f ./stylua.toml

lint: check_lint_env
	@echo Linting...
	@$(LUACHECK) lua/

check_lint_env:
	@command -v "$(LUACHECK)" >/dev/null || { echo "luacheck executable not found: $(LUACHECK) (install with: luarocks install luacheck)"; exit 1; }

test: deps check_test_env
	@echo Testing...
	LC_ALL=C $(NVIM) --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run()"

test_file: deps check_test_env
	@echo Testing File...
	LC_ALL=C $(NVIM) --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

check_test_env:
	@command -v "$(NVIM)" >/dev/null || { echo "Neovim executable not found: $(NVIM)"; exit 1; }
	@$(NVIM) --headless --noplugin -u NONE -c 'lua if vim.fn.has("nvim-0.12") == 0 then print("CodeCompanion tests require Neovim 0.12 or later") vim.cmd.cquit(1) else vim.cmd.quit() end'
	@command -v "$(TREE_SITTER)" >/dev/null || { echo "Tree-sitter CLI is required (Arch/CachyOS: sudo pacman -S tree-sitter-cli)"; exit 1; }

deps: deps/plenary.nvim deps/nvim-treesitter deps/mini.nvim deps/panvimdoc
	@echo Pulling...

deps/plenary.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim.git $@

deps/nvim-treesitter:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter.git $@

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

deps/panvimdoc:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/kdheepak/panvimdoc --branch v4.0.1 $@
