"""apt, on Linux.

`apt-get` and never `apt`, which has no stable command line. The plan sets
DEBIAN_FRONTEND=noninteractive for every step (see plan.py).
"""

from __future__ import annotations

from pathlib import Path

from . import tools
from .runner import StepContext

# Where a repository's signing key and its source line go.
KEYRINGS = Path("/etc/apt/keyrings")
SOURCES = Path("/etc/apt/sources.list.d")


def installed(context: StepContext, package: str) -> bool:
    return context.succeeds(["dpkg", "-s", package])


def update(context: StepContext) -> None:
    tools.sudo(context, ["apt-get", "update"])


def install(context: StepContext, *packages: object) -> None:
    tools.sudo(context, ["apt-get", "install", "-y", *packages])


def architecture(context: StepContext) -> str:
    """The architecture as dpkg names it: amd64, arm64."""
    return context.capture(["dpkg", "--print-architecture"]) or ""
