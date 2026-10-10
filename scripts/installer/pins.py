"""Pinned upstream versions, and the report behind `make pins`."""

from __future__ import annotations

import functools
import os
import re
import sys
from pathlib import Path

from . import fetch, github
from .console import Console
from .runner import Settings, StepContext, StepFailed

# The pins live in a file the bash steps source, so each has one home while
# both languages install from it. See the comment at the top of that file.
PINS_FILE = Path(__file__).resolve().parent.parent / "pins.sh"

_PIN = re.compile(r'([A-Z][A-Z0-9_]*_VERSION)="([^"$`\\]*)"')

# Where each pin's releases are published, as `owner/repo` on GitHub.
# `owner/repo:prefix` is a monorepo whose newest release may belong to another
# crate, so only tags starting with the prefix count (see github.latest_tag).
UPSTREAM = {
    "ATUIN_VERSION": "atuinsh/atuin",
    "BAT_VERSION": "sharkdp/bat",
    "BTOP_VERSION": "aristocratos/btop",
    "CARGO_AUDIT_VERSION": "rustsec/rustsec:cargo-audit/",
    "CARGO_FUZZ_VERSION": "rust-fuzz/cargo-fuzz",
    "CARGO_LLVM_COV_VERSION": "taiki-e/cargo-llvm-cov",
    "CARGO_NEXTEST_VERSION": "nextest-rs/nextest",
    "CMAKE_VERSION": "Kitware/CMake",
    "CROSS_VERSION": "cross-rs/cross",
    "DELTA_VERSION": "dandavison/delta",
    "DIFFTASTIC_VERSION": "Wilfred/difftastic",
    "ELAN_VERSION": "leanprover/elan",
    "EZA_VERSION": "eza-community/eza",
    "FD_VERSION": "sharkdp/fd",
    "GIT_ABSORB_VERSION": "tummychow/git-absorb",
    "GITLEAKS_VERSION": "gitleaks/gitleaks",
    "GLOW_VERSION": "charmbracelet/glow",
    "HYPERFINE_VERSION": "sharkdp/hyperfine",
    "LUA_LS_VERSION": "LuaLS/lua-language-server",
    "MOOR_VERSION": "walles/moor",
    "NEOVIM_VERSION": "neovim/neovim",
    "NERD_FONTS_VERSION": "ryanoasis/nerd-fonts",
    "OPAM_VERSION": "ocaml/opam",
    "RIPGREP_ALL_VERSION": "phiresky/ripgrep-all",
    "RIPGREP_VERSION": "BurntSushi/ripgrep",
    "SAMPLY_VERSION": "mstange/samply",
    "SCCACHE_VERSION": "mozilla/sccache",
    "TMUX_VERSION": "tmux/tmux",
    "TREEHOUSE_VERSION": "kunchenguid/treehouse",
    "TYPST_VERSION": "typst/typst",
    "ZOXIDE_VERSION": "ajeetdsouza/zoxide",
}

# Go publishes its current release as plain text rather than as a GitHub tag.
GO_PIN = "GO_VERSION"
GO_LATEST_URL = "https://go.dev/VERSION?m=text"


def parse(text: str) -> dict[str, str]:
    """The pins in the text of pins.sh."""
    found: dict[str, str] = {}
    for line in text.splitlines():
        match = _PIN.fullmatch(line)
        if match:
            found[match.group(1)] = match.group(2)
    return found


@functools.cache
def load() -> dict[str, str]:
    return parse(PINS_FILE.read_text())


def pin(name: str) -> str:
    return load()[name]


def repository(name: str) -> str:
    """The `owner/repo` a pin's releases are downloaded from."""
    return UPSTREAM[name].partition(":")[0]


def pinned_tag(context: StepContext, name: str) -> str:
    """The pinned tag, or the newest tag upstream publishes under --upgrade."""
    if context.upgrade:
        return github.latest_tag(context, UPSTREAM[name])
    return pin(name)


def _line(name: str, pinned: str, latest: str, reason: str = "") -> str:
    if not latest:
        note = f"(upstream unreachable: {reason})" if reason else "(upstream unreachable)"
    elif latest == pinned:
        note = "up to date"
    else:
        note = f"-> {latest}"
    return f"{name:<24} {pinned:<30} {note}"


def report(context: StepContext) -> list[str]:
    """Each pin beside the tag upstream publishes now.

    A line where the two differ is a pin that can be bumped.
    """
    pins = load()
    lines = []
    for name, repo in UPSTREAM.items():
        try:
            lines.append(_line(name, pins[name], github.latest_tag(context, repo)))
        except StepFailed as failure:
            lines.append(_line(name, pins[name], "", str(failure) or "unknown"))
    latest = context.capture([*fetch.CURL, GO_LATEST_URL], quiet=True) or ""
    lines.append(_line(GO_PIN, pins[GO_PIN], latest.partition("\n")[0]))
    return lines


def main() -> int:
    with open(os.devnull, "wb") as discard:
        context = StepContext(
            Console(sys.stderr.fileno()), Settings(), dict(os.environ), discard, False
        )
        try:
            for line in report(context):
                print(line)
        finally:
            context.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
