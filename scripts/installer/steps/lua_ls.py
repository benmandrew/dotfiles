"""lua-language-server: Homebrew on macOS, the release tree on Linux."""

from __future__ import annotations

import os
import shutil

from .. import pins, release, tools
from ..runner import Step, StepContext

NAME = "lua-language-server"
PIN = "LUA_LS_VERSION"
_ARCH = {"aarch64": "linux-arm64"}


def install(context: StepContext) -> None:
    darwin = context.host.system == "Darwin"
    # Run rather than looked up on PATH: the launcher is a script, which is
    # still there after the tree it starts has gone.
    if context.succeeds([NAME, "--version"]):
        if not context.upgrade:
            context.log(f"{NAME} already installed; skipping")
            return
        context.log(f"Upgrading {NAME}")
        verb = "upgrade"
    else:
        context.log(f"Installing {NAME}")
        verb = "install"
    if darwin:
        context.run(["brew", verb, NAME])
        tools.require_runs(context, NAME)
        return

    tag = pins.pinned_tag(context, PIN)
    if context.upgrade and context.which(NAME) is not None:
        current = context.capture([NAME, "--version"], quiet=True) or ""
        if current == tag:
            context.log(f"{NAME} {tag} already at latest; skipping")
            return

    arch = _ARCH.get(context.host.machine, "linux-x64")
    # No checksum manifest: LuaLS publishes the tarballs alone.
    archive = release.download(context, pins.repository(PIN), tag, f"{NAME}-{tag}-{arch}.tar.gz")

    # Extracted beside the live tree and swapped in, so an interrupted upgrade
    # leaves the old one whole. Staged in ~/.local/opt rather than in scratch
    # space, so the renames stay on one filesystem.
    tree = context.home / ".local" / "opt" / NAME
    staged = tree.with_name(f"{NAME}.new")
    old = tree.with_name(f"{NAME}.old")
    for leftover in (staged, old):
        shutil.rmtree(leftover, ignore_errors=True)
    staged.mkdir(parents=True)
    release.unpack(context, archive, staged)
    if tree.is_dir():
        tree.rename(old)
    staged.rename(tree)
    shutil.rmtree(old, ignore_errors=True)

    link = tools.local_bin(context) / NAME
    pending = link.with_name(f".{NAME}.new")
    if pending.is_symlink() or pending.exists():
        pending.unlink()
    pending.symlink_to(tree / "bin" / NAME)
    os.replace(pending, link)
    tools.note_shadowed(context, NAME, link)
    tools.require_runs(context, link)


STEPS = (Step("install_lua_ls", install),)
