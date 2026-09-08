.PHONY: all clean test fmt fmt-ci lint lint-sh lint-lua lint-actions lint-zsh lint-toml lint-typos lint-make lint-templates lint-secrets lint-secrets-history deps hooks pins

BOLD_BLUE := \033[1;34m
RESET     := \033[0m

# Every shell script in the tree, split by dialect. shfmt and shellcheck both
# need telling which one they are reading, and the two sets disagree: scripts/
# is bash, and so are the hook under dot_claude and the chezmoi run_ scripts at
# the root of home/, while everything chezmoi deploys into ~/.local/bin and
# ~/.config/tmux is #!/bin/sh. Twelve of these were formatted and linted by
# nothing at all, because both targets globbed scripts/*.sh alone.
INSTALL_SCRIPTS := $(wildcard scripts/*.sh)
# The run_ glob stops short of the .sh.tmpl siblings on purpose: those are
# chezmoi templates, and neither tool can read one until it is rendered.
DEPLOYED_BASH   := $(wildcard home/dot_claude/*.sh) $(wildcard home/run_*.sh)
# The git hook is bash and was in no glob here, so nothing read it: it carried
# an SC2054 from the day it was written, in the one file whose job is to stop
# exactly that reaching a commit.
REPO_BASH       := .githooks/pre-commit
DEPLOYED_SH     := $(wildcard home/dot_local/bin/executable_*) \
                   $(wildcard home/dot_config/tmux/*.sh)

BASH_SCRIPTS := $(INSTALL_SCRIPTS) $(DEPLOYED_BASH) $(REPO_BASH)
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

lint: lint-sh lint-lua lint-actions lint-zsh lint-toml lint-typos lint-make lint-templates lint-secrets

# gitleaks was pinned, installed by both platform scripts and checked for by
# verify-install.sh, and then run against nothing: it appeared in no target
# here, in no hook and in no workflow. This is the working tree, which is what
# a local run wants to know about — 625 KB in 51 ms, so it costs nothing to
# have in `lint`. --redact so a finding names the file and the rule without
# printing the secret into a CI log a wider audience can read.
lint-secrets:
	@printf '$(BOLD_BLUE)[scanning for secrets]$(RESET)\n'
	@gitleaks dir . --no-banner --redact

# History, which the tree scan cannot see: a secret committed and then deleted
# leaves nothing on disk and stays in every clone. Kept out of `lint` because
# it needs the full history, and a shallow checkout would report clean without
# having looked. CI runs it from a fetch-depth 0 checkout.
lint-secrets-history:
	@printf '$(BOLD_BLUE)[scanning history for secrets]$(RESET)\n'
	@gitleaks git . --no-banner --redact

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

# The unrendered pass, which reads what a rendering cannot: sed deletes the
# {{ ... }} and leaves both arms of an OS branch in place, so the darwin side
# is still read on a Linux CI runner. The cost is that the result is not valid
# shell, hence --severity=error. lint-templates is the other half; see the
# header of scripts/lint-templates.sh for the division.
lint-zsh:
	@printf '$(BOLD_BLUE)[linting zsh templates]$(RESET)\n'
	@for f in home/dot_zshrc.tmpl home/dot_fzf.zsh.tmpl home/*.sh.tmpl home/.chezmoitemplates/*.sh.tmpl; do \
		[ -f "$$f" ] || continue; \
		sed 's/{{[^{}]*}}//g' "$$f" | shellcheck --shell=bash --severity=error -; \
	done

lint-sh:
	@printf '$(BOLD_BLUE)[linting shell]$(RESET)\n'
	@shellcheck --external-sources --shell bash --enable all $(INSTALL_SCRIPTS) $(REPO_BASH)
	@shellcheck --external-sources --shell bash --enable all $(DEPLOYED_EXCLUDE) $(DEPLOYED_BASH)
	@shellcheck --external-sources --shell sh --enable all $(DEPLOYED_EXCLUDE) $(DEPLOYED_SH)

# Renders every template and lints each rendering with the real linter for the
# language it produces. This absorbed the old lint-ssh target, which rendered
# one template by hand in a mktemp-and-trap dance and — lacking --source —
# would have rendered a different file on a CI runner than the one shipped.
lint-templates:
	@printf '$(BOLD_BLUE)[linting rendered templates]$(RESET)\n'
	@./scripts/lint-templates.sh

lint-lua:
	@printf '$(BOLD_BLUE)[linting lua]$(RESET)\n'
	@files=$$(find home -name '*.lua'); \
	if [ -n "$$files" ]; then luacheck -q $$files --globals vim; else echo "No Lua files to lint."; fi
