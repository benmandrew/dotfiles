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
