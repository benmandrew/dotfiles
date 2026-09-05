.PHONY: all clean test fmt fmt-ci lint lint-sh lint-lua lint-actions lint-zsh lint-toml lint-typos lint-make lint-ssh deps hooks pins

BOLD_BLUE := \033[1;34m
RESET     := \033[0m

# Every shell script in the tree, split by dialect. shfmt and shellcheck both
# need telling which one they are reading, and the two sets disagree: scripts/
# is bash, and so are the hook under dot_claude and the chezmoi run_ scripts at
# the root of home/, while everything chezmoi deploys into ~/.local/bin and
# ~/.config/tmux is #!/bin/sh. Twelve of these were formatted and linted by
# nothing at all, because both targets globbed scripts/*.sh alone.
#
# executable_ai-commit-msg is excluded: the executable_ prefix is chezmoi's,
# but the file is a uv single-file Python script.
INSTALL_SCRIPTS := $(wildcard scripts/*.sh)
# The run_ glob stops short of the .sh.tmpl siblings on purpose: those are
# chezmoi templates, and neither tool can read one until it is rendered.
DEPLOYED_BASH   := $(wildcard home/dot_claude/*.sh) $(wildcard home/run_*.sh)
DEPLOYED_SH     := $(filter-out home/dot_local/bin/executable_ai-commit-msg,$(wildcard home/dot_local/bin/executable_*)) \
                   $(wildcard home/dot_config/tmux/*.sh)

BASH_SCRIPTS := $(INSTALL_SCRIPTS) $(DEPLOYED_BASH)
SH_SCRIPTS   := $(DEPLOYED_SH)

# scripts/ is held to the whole of shellcheck's optional set. The deployed
# scripts are not, yet: they were written before either target looked at them
# and none of them uses the brace-everywhere or [[ ]] conventions scripts/ does,
# so the three checks that only say so are named here rather than left to block
# every commit. Everything that finds a bug — masked exit statuses, unquoted
# expansions, the rest of the optional set — applies to them in full. Dropping
# an exclusion is a mechanical pass over the file it names.
DEPLOYED_EXCLUDE := --exclude SC2250,SC2249,SC2292

all: fmt lint

clean:

test: lint

hooks:
	@printf '$(BOLD_BLUE)[installing git hooks]$(RESET)\n'
	@git config core.hooksPath .githooks

# The devShell in flake.nix is the source of truth for the formatters and
# linters, and this only makes sure it is built so the first `nix develop` is
# not also the first download. The brew list that used to live here had already
# drifted from the flake — luacheck from luarocks in one, lua54Packages.luacheck
# in the other — and failed outright on Linux, while every entry point in this
# repository is already `nix develop --command make`.
deps:
	@printf '$(BOLD_BLUE)[building dev shell]$(RESET)\n'
	@nix develop --command true

# Each pinned tool version in scripts/install-common.sh beside the tag upstream
# publishes now. A line showing an arrow is a pin that can be bumped by hand.
pins:
	@printf '$(BOLD_BLUE)[checking pinned versions]$(RESET)\n'
	@bash -c '. scripts/install-common.sh && print_pin_updates'

fmt:
	@printf '$(BOLD_BLUE)[formatting]$(RESET)\n'
	@stylua .
	@shfmt -ln bash -i 4 -ci -w $(BASH_SCRIPTS)
	@shfmt -ln posix -i 4 -ci -w $(SH_SCRIPTS)

fmt-ci:
	@printf '$(BOLD_BLUE)[checking format]$(RESET)\n'
	@stylua --check .
	@shfmt -ln bash -i 4 -ci -d $(BASH_SCRIPTS)
	@shfmt -ln posix -i 4 -ci -d $(SH_SCRIPTS)

lint: lint-sh lint-lua lint-actions lint-zsh lint-toml lint-typos lint-make lint-ssh

lint-make:
	@printf '$(BOLD_BLUE)[linting Makefile]$(RESET)\n'
	@checkmake Makefile

lint-typos:
	@printf '$(BOLD_BLUE)[checking spelling]$(RESET)\n'
	@typos

# -print0/-0 so a path with a space in it stays one argument, and -r so xargs
# runs nothing rather than running taplo over the whole directory when the find
# comes back empty. RUST_LOG is set on xargs, not taplo, but env vars propagate
# to the child process xargs spawns, so it still silences taplo's noisy
# info-level logs.
lint-toml:
	@printf '$(BOLD_BLUE)[linting TOML]$(RESET)\n'
	@find . -name '*.toml' -not -path './.git/*' -print0 | RUST_LOG=warn xargs -0 -r taplo lint

lint-actions:
	@printf '$(BOLD_BLUE)[linting GitHub Actions]$(RESET)\n'
	@actionlint

lint-zsh:
	@printf '$(BOLD_BLUE)[linting zsh templates]$(RESET)\n'
	@for f in home/dot_zshrc.tmpl home/dot_fzf.zsh.tmpl home/*.sh.tmpl home/.chezmoitemplates/*.sh.tmpl; do \
		[ -f "$$f" ] || continue; \
		sed 's/{{[^{}]*}}//g' "$$f" | shellcheck --shell=bash --severity=error -; \
	done

lint-sh:
	@printf '$(BOLD_BLUE)[linting shell]$(RESET)\n'
	@shellcheck --external-sources --shell bash --enable all $(INSTALL_SCRIPTS)
	@shellcheck --external-sources --shell bash --enable all $(DEPLOYED_EXCLUDE) $(DEPLOYED_BASH)
	@shellcheck --external-sources --shell sh --enable all $(DEPLOYED_EXCLUDE) $(DEPLOYED_SH)

# The template renders to a temporary file the linter then reads. mktemp rather
# than a fixed /tmp path, and a trap rather than a trailing rm, because make
# abandons the target as soon as the linter exits non-zero and the cleanup line
# never ran.
lint-ssh:
	@printf '$(BOLD_BLUE)[linting ssh config]$(RESET)\n'
	@tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT INT TERM; \
		chezmoi execute-template < home/private_dot_ssh/private_config.tmpl > "$$tmp"; \
		sshconfig-lint --config "$$tmp"

lint-lua:
	@printf '$(BOLD_BLUE)[linting lua]$(RESET)\n'
	@files=$$(find home -name '*.lua'); \
	if [ -n "$$files" ]; then luacheck -q $$files --globals vim; else echo "No Lua files to lint."; fi
