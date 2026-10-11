"""Tools built from source on Linux: tmux and btop."""

from __future__ import annotations

import re
import shutil
from pathlib import Path

from .. import apt, brew, fetch, github, pins, tools
from ..runner import Step, StepContext, StepFailed

# 3.4, for the `hyperlinks` terminal feature dot_tmux.conf.tmpl sets; 3.3
# rejects the name, and tmux strips OSC 8 links without it.
TMUX_MIN = (3, 4)
TMUX = Path("/usr/local/bin/tmux")
BTOP_URL = "https://github.com/aristocratos/btop.git"

# Both builds run with a pruned PATH and an explicit compiler. direnv activates
# this repo's own flake for anyone running the installer from a shell sat in
# it, and pkgs.mkShell puts stdenv's gcc wrapper on PATH ahead of /usr/bin.
# That wrapper searches /nix/store alone for headers, so tmux's configure stops
# at "libevent not found" one line after the system pkg-config reported it
# present, and a btop link picks up nix's binutils and glibc beside the system
# g++ and fails on __isoc23_* symbols the older system glibc does not export.
SYSTEM_PATH = "/usr/local/bin:/usr/bin:/bin"

_VERSION = re.compile(r"\d+\.\d+\.\d+")
_FIRST_LETTER = re.compile(r"[A-Za-z]")
_LEADING_DIGITS = re.compile(r"\d+")


def _build_env(context: StepContext, compiler: str, path: str) -> dict[str, str]:
    return {**context.env, "PATH": SYSTEM_PATH, compiler: path}


def _tmux_word(context: StepContext) -> str:
    """The version `tmux -V` reports: `3.3a` out of `tmux 3.3a`."""
    words = (context.capture(["tmux", "-V"]) or "").split()
    return words[1] if len(words) > 1 else ""


def _number(text: str) -> int:
    digits = _LEADING_DIGITS.match(text)
    return int(digits.group()) if digits else 0


def install_tmux_from_source(context: StepContext) -> None:
    present = context.which("tmux") is not None
    if context.upgrade:
        version = github.latest_tag(context, pins.repository("TMUX_VERSION"))
        if present:
            word = _tmux_word(context)
            if word == version.removeprefix("v"):
                context.log(f"tmux {word} already at latest; skipping")
                return
            context.log(f"Upgrading tmux to {version}")
        else:
            context.log(f"Installing tmux {version}")
    else:
        version = pins.pin("TMUX_VERSION")
        if present:
            # Without the letter of a patch release: 3.3 out of 3.3a.
            current = _FIRST_LETTER.split(_tmux_word(context), maxsplit=1)[0]
            major, _, minor = current.partition(".")
            required = ".".join(map(str, TMUX_MIN))
            if (_number(major), _number(minor)) >= TMUX_MIN:
                context.log(f"tmux {current} already satisfies >= {required}; skipping")
                return
            context.log(f"tmux {current} < {required}; building from source")
        else:
            context.log("Installing tmux from source")

    scratch = context.tmpdir()
    tarball = scratch / f"tmux-{version}.tar.gz"
    fetch.download(
        context,
        f"https://github.com/tmux/tmux/releases/download/{version}/{tarball.name}",
        tarball,
    )
    context.run(["tar", "-C", str(scratch), "-xf", str(tarball)])
    source = scratch / f"tmux-{version}"
    env = _build_env(context, "CC", "/usr/bin/gcc")
    context.run(["./configure"], env=env, cwd=source)
    context.run(["make", f"-j{tools.cpu_count()}"], env=env, cwd=source)
    tools.sudo(context, ["make", "-C", source, "install"])
    tools.note_shadowed(context, "tmux", TMUX)
    tools.require_runs(context, TMUX, "-V")


def _btop_version(context: StepContext) -> str:
    """The installed btop's version, or "" if it will not say.

    Matched out of the output rather than cut from a field, because
    `btop --version` wraps the number in bold (`btop version: ^[[1m1.4.4`),
    prints two more lines of compiler and make flags after it, and, built from
    the clone below, appends the commit it was built from, `1.4.4+0f398ab`. A
    field-splitting read picks up the escape and the suffix, so `--upgrade`
    never matched the pinned version and rebuilt every run.
    """
    found = _VERSION.search(context.capture(["btop", "--version"], quiet=True) or "")
    return found.group() if found else ""


def install_btop(context: StepContext) -> None:
    present = context.which("btop") is not None
    if context.host.system == "Darwin":
        if tools.announce(context, "btop", present):
            brew.install_or_upgrade(context, "btop", present)
            tools.require_runs(context, "btop")
        return

    # Linux: build from source, because neither packaged option can show GPU
    # metrics. apt (jammy/universe) is pinned at 1.2.3, which predates GPU
    # monitoring entirely (added in 1.3.0). The upstream release binaries are
    # newer but built STATIC=true, and btop's Makefile force-disables
    # GPU_SUPPORT for static builds since the NVIDIA/AMD backends dlopen their
    # vendor libraries. A stock source build turns GPU_SUPPORT on by default on
    # linux/x86_64 and resolves libnvidia-ml.so at runtime, so it needs no CUDA
    # toolkit at build time, just the driver already being present.
    #
    # The pin itself, even under --upgrade: releases after 1.4.4 need GCC 14,
    # and jammy ships GCC 11.
    version = pins.pin("BTOP_VERSION")

    # ~/.local/bin is appended after /usr/bin on PATH, so a leftover apt btop
    # would shadow the binary installed below.
    if apt.installed(context, "btop"):
        context.log("Removing apt btop (predates GPU support, and shadows ~/.local/bin)")
        tools.sudo(context, ["apt-get", "purge", "-y", "btop"])
        present = context.which("btop") is not None

    if present:
        current = _btop_version(context)
        if not context.upgrade:
            context.log(f"btop {current} already installed; skipping")
            return
        if current == version:
            context.log(f"btop {current} already at pinned version; skipping")
            return
        context.log(f"Upgrading btop to {version}")
    else:
        context.log(f"Installing btop {version}")

    # A shallow clone of the tag, rather than the release tarball this used to
    # fetch. codeload.github.com, the host every /archive/refs/tags/ URL
    # redirects to, rate-limits by source address and answers 429 to
    # unauthenticated requests from a busy or NAT'd one; a 17 August 2026
    # install got 429 on all six attempts while api.github.com, release assets
    # and git itself were all serving this machine normally. Cloning takes the
    # git endpoint instead, which is not on that budget, and --depth 1 fetches
    # the same one commit the tarball held.
    source = context.tmpdir() / "btop"
    clone = ["git", "clone", "--quiet", "--depth", "1", "--branch", f"v{version}"]
    if context.call([*clone, BTOP_URL, str(source)]) != 0:
        raise StepFailed(f"Failed to clone btop v{version}")
    context.run(
        ["make", "-C", str(source), f"-j{tools.cpu_count()}"],
        env=_build_env(context, "CXX", "/usr/bin/g++"),
    )
    target = tools.install_binary(context, source / "bin" / "btop", "btop")
    # The apt package supplied themes via /usr/share/btop/themes, which the
    # purge above removes; ship them to the user theme directory so theme
    # selection still works.
    themes = sorted((source / "themes").glob("*.theme"))
    if not themes:
        raise StepFailed(f"No themes in the btop v{version} source")
    theme_dir = context.home / ".config" / "btop" / "themes"
    theme_dir.mkdir(parents=True, exist_ok=True)
    for theme in themes:
        shutil.copyfile(theme, theme_dir / theme.name)
        (theme_dir / theme.name).chmod(0o644)
    tools.note_shadowed(context, "btop", target)
    tools.require_runs(context, target)


STEPS = (
    Step("install_tmux_from_source", install_tmux_from_source),
    Step("install_btop", install_btop),
)
