"""fish on Linux, from the fish-shell PPA where the distro's is too old."""

from __future__ import annotations

import re
from pathlib import Path

from .. import apt, tools
from ..runner import Step, StepContext, StepFailed

# fish is the login shell, and home/dot_config/fish is written for fish 4.
# jammy's apt holds 3.3.1 and stays there for the life of the release. The
# fish-shell team publishes 4.x for the supported Ubuntu series in its own PPA.
FISH_MIN_VERSION = "4.0"
# Launchpad reports this as signing_key_fingerprint for
# ~fish-shell/+archive/ubuntu/release-4. Pinned because the keyserver
# apt.add_ppa fetches it from is authenticated by TLS alone.
FISH_PPA_FINGERPRINT = "88421E703EDC7AF54967DED473C9FCC9E2BB48DA"
KEY_URL = apt.keyserver_url(FISH_PPA_FINGERPRINT)
ARCHIVE = "https://ppa.launchpadcontent.net/fish-shell/release-4/ubuntu"
# The one install_login_shell takes on Linux. Checked by path, since a fish
# first on PATH, from a nix profile or a devShell, says nothing about whether
# this one exists.
FISH = Path("/usr/bin/fish")

# fish prints "fish, version 4.0.2"; a pre-release can drop the patch number.
_VERSION = re.compile(r"\d+\.\d+(?:\.\d+)?")


def _version(context: StepContext) -> str:
    """The installed fish's version, or "" where there is none."""
    found = _VERSION.search(context.capture([str(FISH), "--version"], quiet=True) or "")
    return found.group() if found else ""


def install_fish(context: StepContext) -> None:
    version = _version(context)
    if version and tools.version_gte(version, FISH_MIN_VERSION) and not context.upgrade:
        context.log(f"fish {version} is at least {FISH_MIN_VERSION}; skipping")
        return
    # A PPA is an Ubuntu construct, and the archive only builds for supported
    # series. Anything else keeps whatever fish the distro ships.
    codename = tools.os_release("VERSION_CODENAME")
    if tools.os_release("ID") != "ubuntu" or not codename:
        context.log(f"not Ubuntu; keeping fish {version or '(absent)'} as the distro ships it")
        return

    context.log(f"Installing fish from the fish-shell PPA (distro fish is {version or 'absent'})")
    apt.add_ppa(context, "fish-shell PPA", FISH_PPA_FINGERPRINT, ARCHIVE, codename, "fish-ppa")
    apt.install(context, "fish")
    # apt can succeed and still leave the old fish, when the PPA has no build
    # for this series or a pin holds the distro's one.
    version = _version(context)
    if not version or not tools.version_gte(version, FISH_MIN_VERSION):
        raise StepFailed(
            f"fish is {version or 'absent'} after installing from the PPA;"
            f" need at least {FISH_MIN_VERSION}"
        )
    # --version answers without starting the interpreter, so also run a
    # command, with no config, as the login shell will.
    tools.require_runs(context, FISH, "--no-config", "-c", "exit 0")
    context.log(f"fish is now {version}")


STEPS = (Step("install_fish", install_fish),)
