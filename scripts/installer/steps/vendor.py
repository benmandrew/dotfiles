"""Tools whose vendor ships an install script: uv, direnv, Claude Code and
Tailscale.

Each script is downloaded and run from disk (see tools.run_downloaded).
"""

from __future__ import annotations

import os

from .. import brew, tools
from ..runner import Step, StepContext, StepFailed

UV_URL = "https://astral.sh/uv/install.sh"
DIRENV_URL = "https://direnv.net/install.sh"
CLAUDE_URL = "https://claude.ai/install.sh"
TAILSCALE_URL = "https://tailscale.com/install.sh"


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
    Step("install_direnv", install_direnv),
    Step("install_claude_code", install_claude_code),
    Step("install_tailscale", install_tailscale),
)
