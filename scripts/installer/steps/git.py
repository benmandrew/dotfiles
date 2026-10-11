"""git on Linux, from the git-core PPA where the distro's is too old."""

from __future__ import annotations

import re

from .. import apt, fetch, tools
from ..runner import Step, StepContext, StepFailed

# Ubuntu freezes git's upstream version at release and backports fixes only, so
# jammy is on 2.34.1 and stays there for the life of the release. That is old
# enough to matter for the config this repo deploys: zdiff3 for
# merge.conflictStyle arrived in 2.35, rebase.updateRefs in 2.38 and
# push.autoSetupRemote in 2.37, and dot_gitconfig.tmpl sets all three. The
# git-core PPA is maintained by the Debian git packagers, tracks upstream
# releases, and publishes amd64 and arm64 for every supported series.
GIT_MIN_VERSION = "2.35.0"
# Launchpad reports this for ~git-core/+archive/ubuntu/ppa. Pinned because the
# keyserver below is authenticated by TLS alone.
GIT_CORE_PPA_FINGERPRINT = "F911AB184317630C59970973E363C90F8F1B6217"
KEY_URL = f"https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x{GIT_CORE_PPA_FINGERPRINT}"
KEYRING = "git-core-ppa.gpg"
SOURCE_LIST = "git-core-ppa.list"

_VERSION = re.compile(r"\d+\.\d+\.\d+")


def _version(context: StepContext) -> str:
    """The installed git's version, or "" where there is none."""
    found = _VERSION.search(context.capture(["git", "--version"], quiet=True) or "")
    return found.group() if found else ""


def install_git(context: StepContext) -> None:
    version = _version(context)
    if version and tools.version_gte(version, GIT_MIN_VERSION) and not context.upgrade:
        context.log(f"git {version} is at least {GIT_MIN_VERSION}; skipping")
        return
    # A PPA is an Ubuntu construct, and the archive only builds for supported
    # series. Anything else keeps whatever git the distro ships.
    codename = tools.os_release("VERSION_CODENAME")
    if tools.os_release("ID") != "ubuntu" or not codename:
        context.log(f"not Ubuntu; keeping git {version or '(absent)'} as the distro ships it")
        return

    context.log(f"Installing git from the git-core PPA (distro git is {version or 'absent'})")
    scratch = context.tmpdir()
    armored = scratch / "key.asc"
    fetch.download(context, KEY_URL, armored)
    # Check the key that came back is the pinned one before apt is told to
    # trust everything it signs.
    if GIT_CORE_PPA_FINGERPRINT not in apt.key_fingerprints(context, armored):
        raise StepFailed("git-core PPA key does not carry the pinned fingerprint")
    tools.sudo(context, ["mkdir", "-p", "-m", "755", apt.KEYRINGS])
    binary = scratch / KEYRING
    context.run(["gpg", "--output", str(binary), "--dearmor", str(armored)])
    keyring = apt.KEYRINGS / KEYRING
    tools.sudo(context, ["install", "-m", "644", binary, keyring])
    arch = context.capture(["dpkg", "--print-architecture"])
    if arch is None:
        raise StepFailed
    tools.sudo_write(
        context,
        apt.SOURCES / SOURCE_LIST,
        f"deb [arch={arch} signed-by={keyring}]"
        f" https://ppa.launchpadcontent.net/git-core/ppa/ubuntu {codename} main\n",
    )
    apt.update(context)
    apt.install(context, "git")
    # apt can succeed and still leave the old git, when the PPA has no build
    # for this series or a pin holds the distro's one.
    version = _version(context)
    if not version or not tools.version_gte(version, GIT_MIN_VERSION):
        raise StepFailed(
            f"git is {version or 'absent'} after installing from the PPA;"
            f" need at least {GIT_MIN_VERSION}"
        )
    context.log(f"git is now {version}")


STEPS = (Step("install_git", install_git),)
