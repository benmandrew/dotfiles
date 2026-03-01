.PHONY: fmt fmt-ci lint

all: fmt lint

fmt:
	stylua .
	shfmt -ln bash -i 4 -ci -w *.sh

fmt-ci:
	stylua --check .
	shfmt -ln bash -i 4 -ci -d *.sh

lint:
	shellcheck --external-sources --shell bash --enable all *.sh
	@files=$$(find home -name '*.lua'); \
    if [ -n "$$files" ]; then luacheck $$files --globals vim; else echo "No Lua files to lint."; fi
