"""Neovim: Homebrew on macOS, the release tree in /opt on Linux."""

from __future__ import annotations

import os
import re
from pathlib import Path

from .. import brew, github, pins, release, tools
from ..runner import Step, StepContext, StepFailed

PIN = "NEOVIM_VERSION"
# Neovim 0.12, for the built-in completion the config uses.
MIN_VERSION = "0.12.0"
# Where the Linux tree goes.
OPT = Path("/opt")


def _install_macos(context: StepContext) -> None:
    if brew.formula_installed(context, "neovim"):
        if context.upgrade:
            context.log("Upgrading Neovim")
            context.run(["brew", "upgrade", "neovim"])
        else:
            context.log("Neovim already installed; skipping")
        return
    context.log("Installing Neovim")
    context.run(["brew", "install", "neovim"])


def install(context: StepContext) -> None:
    if context.host.system == "Darwin":
        _install_macos(context)
        return

    machine = context.host.machine
    name = f"nvim-linux-{'arm64' if machine == 'aarch64' else machine}"
    tree = OPT / name
    nvim = tree / "bin" / "nvim"
    tag = pins.pinned_tag(context, PIN)

    # The first line of `nvim --version` is "NVIM v0.12.5", or for a nightly
    # "NVIM v0.13.0-dev-123+gabcdef", whose suffix version_gte cannot read.
    probe = str(nvim) if os.access(nvim, os.X_OK) else context.which("nvim")
    current = bare = ""
    if probe is not None:
        output = context.capture([probe, "--version"], quiet=True) or ""
        words = output.partition("\n")[0].split()
        current = words[1] if len(words) > 1 else ""
        bare = re.split("[-+]", current.removeprefix("v"), maxsplit=1)[0]

    if bare and tools.version_gte(bare, MIN_VERSION):
        if not context.upgrade:
            context.log(f"Neovim {current} already installed; skipping")
            return
        if probe == str(nvim) and current == tag:
            context.log(f"Neovim {current} already at latest; skipping")
            return
        context.log(f"Upgrading Neovim {current} to {tag}")
    elif current:
        context.log(f"Neovim {current} < {MIN_VERSION}; installing {tag}")
    else:
        context.log(f"Installing Neovim {tag}")

    # The 0.12.5 release carries no shasum.txt, so the tarball is checked
    # against the digest GitHub records for it instead.
    asset = f"{name}.tar.gz"
    archive = context.tmpdir() / asset
    github.download_verified(context, pins.repository(PIN), tag, asset, archive)
    # Unpacked before the old tree goes, so a bad tarball leaves Neovim working.
    unpacked = release.unpack(context, archive) / name
    if not os.access(unpacked / "bin" / "nvim", os.X_OK):
        raise StepFailed(f"No bin/nvim inside {asset}; upstream layout changed")
    tools.sudo(context, ["rm", "-rf", tree])
    tools.sudo(context, ["mv", unpacked, tree])
    tools.sudo(context, ["chown", "-R", "root:root", tree])
    tools.note_shadowed(context, "nvim", nvim)
    tools.require_runs(context, nvim, "--version")


STEPS = (Step("install_neovim_if_missing", install),)
