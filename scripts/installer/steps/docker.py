"""Docker: Docker Desktop on macOS, Docker's own apt repository on Linux."""

from __future__ import annotations

from pathlib import Path

from .. import apt, brew, fetch, tools
from ..runner import Step, StepContext, StepFailed

# Docker's own repository rather than Ubuntu's docker.io, which lags upstream
# and ships no buildx or compose plugins. The layout matches Docker's install
# guide: an ASCII-armoured key in /etc/apt/keyrings/docker.asc and a deb822
# docker.sources, so a machine set up by hand from that guide is a no-op here.
PACKAGES = (
    "docker-ce",
    "docker-ce-cli",
    "containerd.io",
    "docker-buildx-plugin",
    "docker-compose-plugin",
)
# Docker's release signing key, as download.docker.com/linux/ubuntu/gpg serves
# it. Pinned because the key is fetched over TLS with nothing else to check it.
KEY_FINGERPRINT = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
CASK = "docker-desktop"
# Where the cask links the client.
DESKTOP_CLI = "/usr/local/bin/docker"
SYSTEMD = Path("/run/systemd/system")


def _install_macos(context: StepContext) -> None:
    # Docker Desktop: macOS has no native container runtime, and the cask links
    # the docker CLI and compose plugin into /usr/local. The daemon runs only
    # once the app has been opened and its licence accepted, which cannot be
    # scripted, so only the client is probed.
    if not brew.cask_installed(context, CASK):
        context.log("Installing Docker Desktop")
        context.run(["brew", "install", "--cask", CASK])
        context.log("Open Docker.app once to start the engine and accept its licence")
    elif context.upgrade:
        context.log("Upgrading Docker Desktop")
        context.run(["brew", "upgrade", "--cask", CASK])
    else:
        context.log("Docker Desktop already installed; skipping")
        return
    tools.require_runs(context, DESKTOP_CLI, "--version")


def _add_repository(context: StepContext, distro: str, codename: str) -> None:
    keyring = apt.KEYRINGS / "docker.asc"
    sources = apt.SOURCES / "docker.sources"
    if not keyring.is_file():
        context.log("Adding Docker's apt signing key")
        key = context.tmpdir() / "docker.asc"
        fetch.download(context, f"https://download.docker.com/linux/{distro}/gpg", key)
        if KEY_FINGERPRINT not in apt.key_fingerprints(context, key):
            raise StepFailed("Docker's apt key does not carry the pinned fingerprint")
        tools.sudo(context, ["mkdir", "-p", "-m", "755", apt.KEYRINGS])
        tools.sudo(context, ["install", "-m", "644", key, keyring])
    if not sources.is_file():
        context.log("Adding Docker's apt repository")
        tools.sudo_write(
            context,
            sources,
            f"Types: deb\nURIs: https://download.docker.com/linux/{distro}\n"
            f"Suites: {codename}\nComponents: stable\nSigned-By: {keyring}\n",
        )


def install_docker(context: StepContext) -> None:
    if context.host.system == "Darwin":
        _install_macos(context)
        return

    distro = tools.os_release("ID")
    codename = tools.os_release("VERSION_CODENAME")
    # UBUNTU_CODENAME wins, so a derivative such as Mint resolves to the Ubuntu
    # suite Docker actually publishes.
    ubuntu_codename = tools.os_release("UBUNTU_CODENAME")
    if ubuntu_codename:
        distro, codename = "ubuntu", ubuntu_codename
    elif distro != "debian":
        context.log(f"Docker: no apt repository for {distro or 'this distro'}; skipping")
        return
    if not codename:
        context.log("Docker: no release codename in /etc/os-release; skipping")
        return
    _add_repository(context, distro, codename)

    missing = [package for package in PACKAGES if not apt.installed(context, package)]
    if context.upgrade:
        context.log("Upgrading Docker")
        wanted = list(PACKAGES)
    elif missing:
        context.log(f"Installing Docker packages: {' '.join(missing)}")
        wanted = missing
    else:
        context.log("Docker packages already installed; skipping")
        wanted = []
    if wanted:
        apt.update(context)
        apt.install(context, *wanted)
        tools.require_runs(context, "docker", "--version")

    # The docker group grants root-equivalent access to the daemon's socket.
    # Opting into this step is the consent for that on this machine.
    user = context.capture(["id", "-un"])
    groups = context.capture(["id", "-nG", user]) if user else None
    if not user or groups is None:
        raise StepFailed
    if "docker" not in groups.split():
        context.log(f"Adding {user} to the docker group; log out and back in for it to apply")
        tools.sudo(context, ["usermod", "-aG", "docker", user])

    # Containers and WSL often run without systemd, where the unit cannot be
    # enabled and the daemon is started some other way.
    if not SYSTEMD.is_dir():
        context.log("Docker: systemd is not running; not enabling docker.service")
        return
    if not context.succeeds(["systemctl", "is-enabled", "--quiet", "docker.service"]):
        context.log("Enabling docker.service")
        tools.sudo(context, ["systemctl", "enable", "--now", "docker.service"])


STEPS = (Step("install_docker", install_docker),)
