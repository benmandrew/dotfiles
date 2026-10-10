#!/bin/bash
# shellcheck disable=SC2034  # read by whatever sources this, and by installer/pins.py

# Pinned upstream versions. The bash steps source this file and the Python
# steps parse it, so every line that sets a pin is NAME_VERSION="value" and
# nothing else: no expansion, no command, no trailing comment.
#
# Ten steps used to resolve their tag through github_latest_tag on every run, so
# two machines provisioned months apart came up with different builds of every
# tool, and an upstream release that breaks something landed on whichever
# machine happened to be provisioned next. A normal run installs the versions
# below instead.
#
# --upgrade ignores the pins and takes whatever upstream calls latest, which is
# also how a pin gets bumped: `make pins` prints each constant beside the tag
# upstream publishes now, and the ones that differ are edited in here by hand.
# Pinning is also what makes checksum verification worth anything, since a
# floating tag has no fixed content to check against.
#
# Each value is the tag exactly as upstream publishes it -- some carry a leading
# `v`, some do not, and nextest-rs prefixes the crate name -- so the call sites
# strip what they need rather than the constants guessing.
ATUIN_VERSION="v18.21.0"
BAT_VERSION="v0.26.1"
CARGO_AUDIT_VERSION="cargo-audit/v0.22.2"
CARGO_FUZZ_VERSION="0.13.2"
CARGO_LLVM_COV_VERSION="v0.9.1"
CARGO_NEXTEST_VERSION="cargo-nextest-0.9.143"
CMAKE_VERSION="v4.4.3"
CROSS_VERSION="v0.2.5"
DELTA_VERSION="0.19.2"
DIFFTASTIC_VERSION="0.71.0"
ELAN_VERSION="v4.2.4"
EZA_VERSION="v0.23.5"
FD_VERSION="v10.5.0"
GIT_ABSORB_VERSION="0.9.0"
GITLEAKS_VERSION="v8.30.1"
GLOW_VERSION="v3.0.0"
GO_VERSION="go1.27.1"
HYPERFINE_VERSION="v1.20.0"
LUA_LS_VERSION="3.19.1"
MOOR_VERSION="v2.18.0"
NEOVIM_VERSION="v0.12.5"
NERD_FONTS_VERSION="v3.5.1"
OPAM_VERSION="2.5.2"
RIPGREP_ALL_VERSION="v0.10.10"
RIPGREP_VERSION="15.2.0"
SAMPLY_VERSION="samply-v0.13.1"
SCCACHE_VERSION="v0.17.0"
TREEHOUSE_VERSION="v2.3.0"
TYPST_VERSION="v0.15.1"
ZOXIDE_VERSION="v0.10.0"

# btop is pinned for a reason of its own rather than for reproducibility: >=
# 1.4.5 uses std::ranges::to, which needs GCC 14, and jammy ships GCC 11. Bump
# it once the oldest target distro has a new enough compiler.
BTOP_VERSION="1.4.4"

# tmux is built from source, and the build is the slowest step in the run, so
# this deliberately lags upstream rather than tracking it.
TMUX_VERSION="3.6b"
