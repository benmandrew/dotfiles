.PHONY: fmt lint

all: fmt lint

fmt:
	stylua .
	shfmt -ln bash -i 4 -ci -w *.sh

lint:
	shellcheck --external-sources --shell bash --enable all *.sh
