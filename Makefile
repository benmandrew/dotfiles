.PHONY: fmt fmt-ci lint lint-sh lint-lua

all: fmt lint

fmt:
	stylua .
	shfmt -ln bash -i 4 -ci -w scripts/*.sh

fmt-ci:
	stylua --check .
	shfmt -ln bash -i 4 -ci -d scripts/*.sh

lint: lint-sh lint-lua

lint-sh:
	shellcheck --external-sources --shell bash --enable all scripts/*.sh

lint-lua:
	@files=$$(find home -name '*.lua'); \
    if [ -n "$$files" ]; then luacheck -q $$files --globals vim; else echo "No Lua files to lint."; fi
