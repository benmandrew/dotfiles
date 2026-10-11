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


def key_fingerprints(context: StepContext, key: Path) -> list[str]:
    """The fingerprints of every key in a file, armoured or not."""
    listing = context.capture(["gpg", "--show-keys", "--with-colons", str(key)], quiet=True) or ""
    fields = (line.split(":") for line in listing.splitlines() if line.startswith("fpr:"))
    return [line[9] for line in fields if len(line) > 9]


def architecture(context: StepContext) -> str:
    """The architecture as dpkg names it: amd64, arm64."""
    return context.capture(["dpkg", "--print-architecture"]) or ""
