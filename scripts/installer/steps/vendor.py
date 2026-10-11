"""Tools whose vendor ships an install script: uv, Starship, direnv, Claude
Code, rtk and Tailscale.

Each script is downloaded and run from disk (see tools.run_downloaded).
"""

from __future__ import annotations

import os
from pathlib import Path

from .. import brew, tools
from ..runner import Step, StepContext, StepFailed

UV_URL = "https://astral.sh/uv/install.sh"
STARSHIP_URL = "https://starship.rs/install.sh"
DIRENV_URL = "https://direnv.net/install.sh"
CLAUDE_URL = "https://claude.ai/install.sh"
RTK_URL = "https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh"
TAILSCALE_URL = "https://tailscale.com/install.sh"

# Where Starship's installer put the binary before this step sent it to
# ~/.local/bin.
STALE_STARSHIP = Path("/usr/local/bin/starship")


def install_uv(context: StepContext) -> None:
    if context.which("uv") is not None:
        if not context.upgrade:
            context.log("uv already installed; skipping")
            return
        context.log("Upgrading uv")
        tools.retry_once(context, ["uv", "self", "update"])
        tools.require_runs(context, "uv")
        return
    context.log("Installing uv")
    tools.run_downloaded(context, UV_URL, ["sh"])
    # For the steps that follow, install_ansible_lint among them.
    local_bin = tools.local_bin(context)
    context.env["PATH"] = f"{local_bin}{os.pathsep}{context.env.get('PATH', '')}"
    tools.require_runs(context, local_bin / "uv")


def _remove_shadowing_starship(context: StepContext, managed: Path) -> None:
    """Delete the copy an earlier version of this step left in /usr/local/bin.

    A copy left in the old location is dead weight at best. ~/.local/bin now
    leads /usr/local/bin in the rendered zshrc, but only for shells started
    since that change, and anything reading the system PATH still finds the
    stale one first, so the managed binary gets installed and then ignored,
    silently, for as long as the old one exists. Remove it once the new one is
    in place, and only then.
    """
    if not STALE_STARSHIP.exists() or not os.access(managed, os.X_OK):
        return
    context.log(f"Removing stale {STALE_STARSHIP}, superseded by {managed}")
    if tools.sudo(context, ["rm", "-f", STALE_STARSHIP], check=False) != 0:
        context.log(f"Could not remove {STALE_STARSHIP}; it may still shadow the managed copy")


def install_starship(context: StepContext) -> None:
    if not tools.announce(context, "Starship", context.which("starship") is not None):
        return
    # The vendor installer defaults BIN_DIR to /usr/local/bin, which is
    # root:wheel 0755 on macOS, so its `test_writable` fails and it runs
    # `sudo -v`: a password prompt from a third-party script this one cannot
    # reach into. Every other bare binary these steps fetch already goes to
    # ~/.local/bin, so send starship there too and the step needs no privileges
    # at all.
    local_bin = tools.local_bin(context)
    tools.run_downloaded(context, STARSHIP_URL, ["sh"], "-y", "-b", str(local_bin))
    _remove_shadowing_starship(context, local_bin / "starship")
    tools.note_shadowed(context, "starship", local_bin / "starship")
    tools.require_runs(context, local_bin / "starship")


def install_direnv(context: StepContext) -> None:
    # Run it rather than find it: direnv's install.sh curls straight over the
    # existing binary, so an interrupted upgrade leaves a truncated executable.
    if not tools.announce(context, "direnv", context.succeeds(["direnv", "--version"])):
        return
    local_bin = tools.local_bin(context)
    tools.run_downloaded(
        context, DIRENV_URL, ["bash"], env={**context.env, "bin_path": str(local_bin)}
    )
    tools.note_shadowed(context, "direnv", local_bin / "direnv")
    tools.require_runs(context, local_bin / "direnv")


def install_claude_code(context: StepContext) -> None:
    target = context.home / ".local" / "bin" / "claude"
    found = context.which("claude")
    if found is None:
        context.log("Installing Claude Code")
        tools.run_downloaded(context, CLAUDE_URL, ["bash"])
        tools.note_shadowed(context, "claude", target)
        tools.require_runs(context, target)
        return
    if not context.upgrade:
        context.log("Claude Code already installed; skipping")
        return
    context.log("Upgrading Claude Code")
    # Use the native updater, not npm -g: npm would install a second copy under
    # /usr/lib/node_modules that shadows the native one on PATH. `claude
    # update` follows the recorded install method, so an npm install still
    # upgrades through npm, which has left the package's placeholder in place
    # of the native binary and exited 0. Name that layout, and fail the step
    # unless the upgraded binary runs.
    try:
        link = os.readlink(found)
    except OSError:
        link = ""
    if "/node_modules/" in link:
        context.log(
            f"Claude Code is an npm install ({link}); run 'claude install' to switch to the"
            " native build"
        )
    tools.retry_once(context, ["claude", "update"])
    tools.note_shadowed(context, "claude", target)
    try:
        tools.require_runs(context, "claude")
    except StepFailed as failure:
        context.console.err(str(failure))
        raise StepFailed("Reinstall Claude Code with https://claude.ai/install.sh") from None


def install_rtk(context: StepContext) -> None:
    if not tools.announce(context, "rtk", context.which("rtk") is not None):
        return
    tools.run_downloaded(context, RTK_URL, ["sh"])
    # The installer's default; RTK_INSTALL_DIR would move it.
    target = context.home / ".local" / "bin" / "rtk"
    tools.note_shadowed(context, "rtk", target)
    tools.require_runs(context, target)


def install_tailscale(context: StepContext) -> None:
    if context.host.system == "Darwin":
        present = brew.cask_installed(context, "tailscale")
        if tools.announce(context, "Tailscale", present):
            context.run(["brew", "upgrade" if present else "install", "--cask", "tailscale"])
        return
    if not tools.announce(context, "Tailscale", context.which("tailscale") is not None):
        return
    tools.run_downloaded(context, TAILSCALE_URL, ["sh"])
    # `version` prints the client's own version without asking tailscaled.
    tools.require_runs(context, "tailscale", "version")


STEPS = (
    Step("install_uv", install_uv),
    Step("install_starship", install_starship),
    Step("install_direnv", install_direnv),
    Step("install_claude_code", install_claude_code),
    Step("install_rtk", install_rtk),
    Step("install_tailscale", install_tailscale),
)
