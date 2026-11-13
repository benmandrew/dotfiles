"""Ghostty, the terminal window around tmux."""

from __future__ import annotations

from pathlib import Path

from .. import tools
from ..runner import Step, StepContext

CASK = "ghostty"
# The cask links manpages and completions but no binary, so the command is
# reached inside the app it moves to /Applications.
APP_BIN = Path("/Applications/Ghostty.app/Contents/MacOS/ghostty")
SNAP = "ghostty"
# Where snapd links a snap's commands. A login shell puts it on PATH through
# /etc/profile.d, which the installer's environment may not have read yet.
SNAP_BIN = Path("/snap/bin")
# A CLI action: it prints and exits without opening a window.
PROBE = "+version"


def install_ghostty(context: StepContext) -> None:
    if context.host.system == "Darwin":
        present = APP_BIN.exists()
        if not tools.announce(context, "Ghostty", present):
            return
        context.run(["brew", "upgrade" if present else "install", "--cask", CASK])
        tools.require_runs(context, APP_BIN, PROBE)
        return

    if not (context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")):
        context.log("Ghostty: no display session detected; skipping on headless Linux")
        return
    # Ghostty publishes no Linux packages. Ubuntu carries it from 26.04 only, and
    # the community debs (mkasberg/ghostty-ubuntu) build for 26.04 and later, so
    # the snap is the one source that covers jammy, on amd64 and arm64 alike.
    # Ken VanDine maintains it, built with Ghostty's own scripts. The nixpkgs
    # build fails to start outside NixOS without an OpenGL shim.
    snapped = SNAP_BIN / "ghostty"
    present = snapped.exists()
    if not present and context.which("ghostty") is not None:
        context.log("Ghostty installed outside snap; skipping")
        return
    if context.which("snap") is None:
        context.log("Ghostty: snapd not installed; skipping")
        return
    if not tools.announce(context, "Ghostty", present):
        return
    if present:
        tools.sudo(context, ["snap", "refresh", SNAP])
    else:
        # Classic confinement: the terminal has to reach the whole home
        # directory and run any program on the system.
        tools.sudo(context, ["snap", "install", SNAP, "--classic"])
    tools.require_runs(context, snapped, PROBE)


STEPS = (Step("install_ghostty", install_ghostty),)
