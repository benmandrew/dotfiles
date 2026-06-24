.PHONY: fmt fmt-ci lint lint-sh lint-lua

BOLD_BLUE := \033[1;34m
RESET     := \033[0m

all: fmt lint

fmt:
	@printf '$(BOLD_BLUE)[formatting]$(RESET)\n'
	@stylua .
	@shfmt -ln bash -i 4 -ci -w scripts/*.sh

fmt-ci:
	@printf '$(BOLD_BLUE)[checking format]$(RESET)\n'
	@stylua --check .
	@shfmt -ln bash -i 4 -ci -d scripts/*.sh

lint: lint-sh lint-lua

lint-sh:
	@printf '$(BOLD_BLUE)[linting shell]$(RESET)\n'
	@shellcheck --external-sources --shell bash --enable all scripts/*.sh

lint-lua:
	@printf '$(BOLD_BLUE)[linting lua]$(RESET)\n'
	@files=$$(find home -name '*.lua'); \
	if [ -n "$$files" ]; then luacheck -q $$files --globals vim; else echo "No Lua files to lint."; fi
