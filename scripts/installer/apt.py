"""apt, on Linux.

`apt-get` and never `apt`, which has no stable command line. The plan sets
DEBIAN_FRONTEND=noninteractive for every step (see plan.py).
"""

from __future__ import annotations

from pathlib import Path

from . import fetch, tools
from .runner import StepContext, StepFailed

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


def keyserver_url(fingerprint: str) -> str:
    """Where Ubuntu's keyserver serves the key with this fingerprint."""
    return f"https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x{fingerprint}"


def add_ppa(
    context: StepContext, label: str, fingerprint: str, archive: str, codename: str, slug: str
) -> None:
    """Trust a Launchpad PPA's key and add its archive, then refresh the index.

    The key comes from the keyserver, which TLS alone authenticates, so the
    caller pins the fingerprint Launchpad reports for the archive. The keyring
    and source list are named `slug`.gpg and `slug`.list.
    """
    scratch = context.tmpdir()
    armored = scratch / "key.asc"
    fetch.download(context, keyserver_url(fingerprint), armored)
    # Check the key that came back is the pinned one before apt is told to
    # trust everything it signs.
    if fingerprint not in key_fingerprints(context, armored):
        raise StepFailed(f"{label} key does not carry the pinned fingerprint")
    tools.sudo(context, ["mkdir", "-p", "-m", "755", KEYRINGS])
    binary = scratch / f"{slug}.gpg"
    context.run(["gpg", "--output", str(binary), "--dearmor", str(armored)])
    keyring = KEYRINGS / f"{slug}.gpg"
    tools.sudo(context, ["install", "-m", "644", binary, keyring])
    arch = context.capture(["dpkg", "--print-architecture"])
    if arch is None:
        raise StepFailed
    tools.sudo_write(
        context,
        SOURCES / f"{slug}.list",
        f"deb [arch={arch} signed-by={keyring}] {archive} {codename} main\n",
    )
    update(context)
