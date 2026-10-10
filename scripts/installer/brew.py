"""Homebrew."""

from __future__ import annotations

from . import tools
from .runner import StepContext


def formula_installed(context: StepContext, name: str) -> bool:
    return context.succeeds(["brew", "list", "--formula", name])


def formula(context: StepContext, name: str, command: str, *probe: str) -> None:
    """Install a formula, or upgrade it under --upgrade, and prove `command` runs."""
    if formula_installed(context, name):
        if not context.upgrade:
            context.log(f"{name} already installed; skipping")
            return
        context.log(f"Upgrading {name}")
        context.run(["brew", "upgrade", name])
    else:
        context.log(f"Installing {name}")
        context.run(["brew", "install", name])
    tools.require_runs(context, command, *probe)
