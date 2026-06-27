.PHONY: fmt fmt-ci lint lint-sh lint-lua lint-actions lint-zsh lint-toml deps

BOLD_BLUE := \033[1;34m
RESET     := \033[0m

all: fmt lint

deps:
	@printf '$(BOLD_BLUE)[installing dev deps]$(RESET)\n'
	@brew install stylua shfmt shellcheck luarocks actionlint taplo
	@luarocks install luacheck

fmt:
	@printf '$(BOLD_BLUE)[formatting]$(RESET)\n'
	@stylua .
	@shfmt -ln bash -i 4 -ci -w scripts/*.sh

fmt-ci:
	@printf '$(BOLD_BLUE)[checking format]$(RESET)\n'
	@stylua --check .
	@shfmt -ln bash -i 4 -ci -d scripts/*.sh

lint: lint-sh lint-lua lint-actions lint-zsh lint-toml

lint-toml:
	@printf '$(BOLD_BLUE)[linting TOML]$(RESET)\n'
	@find . -name '*.toml' -not -path './.git/*' | RUST_LOG=warn xargs taplo lint

lint-actions:
	@printf '$(BOLD_BLUE)[linting GitHub Actions]$(RESET)\n'
	@actionlint

lint-zsh:
	@printf '$(BOLD_BLUE)[linting zsh templates]$(RESET)\n'
	@for f in home/dot_zshrc.tmpl home/dot_fzf.zsh.tmpl home/*.sh.tmpl; do \
		[ -f "$$f" ] || continue; \
		sed 's/{{[^{}]*}}//g' "$$f" | shellcheck --shell=bash --severity=error -; \
	done

lint-sh:
	@printf '$(BOLD_BLUE)[linting shell]$(RESET)\n'
	@shellcheck --external-sources --shell bash --enable all scripts/*.sh

lint-lua:
	@printf '$(BOLD_BLUE)[linting lua]$(RESET)\n'
	@files=$$(find home -name '*.lua'); \
	if [ -n "$$files" ]; then luacheck -q $$files --globals vim; else echo "No Lua files to lint."; fi
