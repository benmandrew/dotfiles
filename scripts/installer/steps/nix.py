"""Nix, and nix-direnv with the bash it needs on macOS."""

from __future__ import annotations

import os
import pwd
import re
import shutil
from pathlib import Path

from .. import fetch, pins, shell, tools
from ..runner import Step, StepContext, StepFailed
from ..sudo import sudo_command

INSTALL_URL = "https://nixos.org/nix/install"
# Where a multi-user install keeps nix, whether or not PATH has it.
DEFAULT_NIX = Path("/nix/var/nix/profiles/default/bin/nix")
SYSTEM_CONF = Path("/etc/nix/nix.conf")
# What puts nix on PATH, the first that exists winning. The user's own profile
# comes after these.
PROFILE_SCRIPTS = (
    Path("/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"),
    Path("/etc/profile.d/nix.sh"),
)

_FLAKES = re.compile(r"^\s*(extra-)?experimental-features.*\bflakes\b", re.MULTILINE)

PIN = "NIX_DIRENV_VERSION"
# nix-direnv is one file. Upstream attaches nothing to a release, so there is
# no digest to ask GitHub for; its README gives this hash of the file at the
# pinned tag, in base64, for direnv's `source_url`. It moves with the pin.
DIRENVRC_SHA256 = "856e8d0b5247b9edc88d9377b8333a97a2363cc69abaa7760fb857609d597ebe"
DIRENVRC_URL = "https://raw.githubusercontent.com/{repository}/{tag}/direnvrc"
_DIRENVRC_VERSION = re.compile(r"^NIX_DIRENV_VERSION=(\S+)$", re.MULTILINE)

# What direnvrc loads. $HOME is for direnv's bash to expand.
SOURCE_LINE = "source $HOME/.local/share/nix-direnv/direnvrc"
# The nix to use where PATH has none, as under an editor started outside a
# login shell. The nixpkgs build this step used to install had one patched in.
FALLBACK_LINE = f"NIX_DIRENV_FALLBACK_NIX=${{NIX_DIRENV_FALLBACK_NIX:-{DEFAULT_NIX}}}"
# The line that loaded the nixpkgs build, however it spelt the home directory.
_PROFILE_SOURCE = re.compile(r"\s*(?:source|\.)\s+\S*\.nix-profile/share/nix-direnv/direnvrc\s*")


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def enable_nix_flakes(context: StepContext) -> None:
    """Only a fallback for a machine that has not run `chezmoi apply`, whose
    nix.conf turns flakes on."""
    conf = context.home / ".config" / "nix" / "nix.conf"
    if _FLAKES.search(_read(conf)):
        return
    context.log("Enabling Nix flakes")
    conf.parent.mkdir(parents=True, exist_ok=True)
    with conf.open("a") as handle:
        handle.write("extra-experimental-features = nix-command flakes\n")


def source_nix_profile(context: StepContext) -> None:
    """Put an installed nix on PATH for the rest of the run.

    Called only when nix is installed but absent from PATH, which is what a
    macOS update that rewrites /etc/zshrc leaves behind.

    This used to source /etc/bashrc, where the macOS nix installer appends its
    block. That file is an interactive-shell rc: line 16 is `if [ -z "$PS1" ]`,
    and PS1 is unset in a non-interactive bash, so `set -u` killed the run on
    the spot and printed nothing at all. Source the profile scripts the block
    loads instead; they are written to be sourced from anywhere and reference
    nothing unguarded.

    The daemon script exports __ETC_PROFILE_NIX_SOURCED and returns early when
    it is already set, so a caller that inherited the variable with a PATH that
    has since lost the profile directory would get a silent no-op. Clear it
    first, since reaching here means PATH needs rebuilding whatever the
    variable says.
    """
    own = context.home / ".nix-profile" / "etc" / "profile.d" / "nix.sh"
    for candidate in (*PROFILE_SCRIPTS, own):
        if candidate.is_file() and os.access(candidate, os.R_OK):
            shell.source(context, candidate, unset=("__ETC_PROFILE_NIX_SOURCED",))
            return


def configure_nix_trusted_user(context: StepContext) -> None:
    """Add the installing user to the daemon's trusted-users.

    min-free, max-free, auto-optimise-store, extra-substituters and the like in
    ~/.config/nix/nix.conf are "restricted settings": the multi-user daemon
    silently ignores them from anyone not listed in /etc/nix/nix.conf's
    trusted-users, which defaults to root alone. Trusting the user is what
    makes the chezmoi-managed nix.conf take effect.
    """
    user = pwd.getpwuid(os.geteuid()).pw_name
    trusted = re.compile(rf"^\s*(extra-)?trusted-users\s*=.*\b{re.escape(user)}\b", re.MULTILINE)
    if trusted.search(_read(SYSTEM_CONF)):
        return
    context.log(f"Adding {user} to Nix trusted-users")
    tools.sudo_write(context, SYSTEM_CONF, f"extra-trusted-users = {user}\n", append=True)
    if context.host.system == "Darwin":
        tools.sudo(context, ["launchctl", "kickstart", "-k", "system/org.nixos.nix-daemon"])
    else:
        tools.sudo(context, ["systemctl", "restart", "nix-daemon"])


def install_nix(context: StepContext) -> None:
    on_path = context.which("nix") is not None
    if on_path or os.access(DEFAULT_NIX, os.X_OK):
        # PATH may miss an existing install under a non-login shell, as in
        # Ansible's command module, so source the profile scripts to put nix
        # on PATH for the rest of the run.
        if not on_path:
            source_nix_profile(context)
        if not context.upgrade:
            context.log("Nix already installed; skipping")
            enable_nix_flakes(context)
            configure_nix_trusted_user(context)
            return
        context.log("Upgrading Nix")
        tools.retry_once(context, [*sudo_command(context.env), "-i", "nix", "upgrade-nix"])
    else:
        context.log("Installing Nix")
        tools.run_downloaded(context, INSTALL_URL, ["sh"], "--daemon", "--yes")
        source_nix_profile(context)
    enable_nix_flakes(context)
    configure_nix_trusted_user(context)
    tools.require_runs(context, "nix")


def _profile_has(context: StepContext, package: str) -> bool:
    """Whether the user's nix profile holds a nixpkgs package of that name."""
    listing = context.capture(["nix", "profile", "list"], quiet=True) or ""
    entry = re.compile(rf"Flake attribute:\s+legacyPackages\.[^.]+\.{re.escape(package)}")
    return any(entry.fullmatch(line) for line in listing.splitlines())


def _install_modern_bash(context: StepContext) -> None:
    # nix-direnv requires bash >= 4.4; macOS ships bash 3.2 (GPLv2-only) as
    # /bin/bash.
    if context.host.system != "Darwin":
        return
    tools.require_command(context, "nix")
    bash = context.home / ".nix-profile" / "bin" / "bash"
    if _profile_has(context, "bash"):
        if not context.upgrade:
            context.log("Modern bash already installed; skipping")
            return
        context.log("Upgrading bash")
        context.run(["nix", "profile", "upgrade", "bash"])
    else:
        context.log("Installing modern bash (nix-direnv requires >= 4.4)")
        context.run(["nix", "profile", "install", "nixpkgs#bash"])
    tools.require_runs(context, bash)


def _installed_version(direnvrc: Path) -> str:
    """The version a nix-direnv file declares, or "" if it is not one."""
    found = _DIRENVRC_VERSION.search(_read(direnvrc))
    return found.group(1) if found else ""


def _fetch_direnvrc(context: StepContext, tag: str, target: Path) -> None:
    fetched = context.tmpdir() / "direnvrc"
    url = DIRENVRC_URL.format(repository=pins.repository(PIN), tag=tag)
    fetch.download(context, url, fetched)
    # Only the pinned tag has a known hash. --upgrade takes whatever tag is
    # newest, so that file is checked for its version line alone.
    if tag == pins.pin(PIN):
        fetch.check_sha256(fetched, DIRENVRC_SHA256, "direnvrc")
    declared = _installed_version(fetched)
    if declared != tag:
        raise StepFailed(f"{url} is not nix-direnv {tag} (it declares '{declared}')")
    target.parent.mkdir(parents=True, exist_ok=True)
    # Copied beside the target and renamed over it, so direnv never loads half
    # a file. The scratch directory may be on another filesystem.
    pending = target.with_name(f"{target.name}.tmp")
    shutil.copyfile(fetched, pending)
    pending.replace(target)


def _wire(context: StepContext) -> None:
    """Make direnvrc load the downloaded file.

    A line loading the nixpkgs build, which this step installed until October
    2026, is replaced where it stands, so whatever the user wrote around it
    keeps its order.
    """
    direnvrc = context.home / ".config" / "direnv" / "direnvrc"
    lines = _read(direnvrc).splitlines()
    stale = [line for line in lines if _PROFILE_SOURCE.fullmatch(line)]
    if SOURCE_LINE in lines and not stale:
        return
    block = [] if SOURCE_LINE in lines else [FALLBACK_LINE, SOURCE_LINE]
    wired: list[str] = []
    for line in lines:
        if line not in stale:
            wired.append(line)
        elif block:
            wired.extend(block)
            block = []
    if stale:
        context.log("Pointing direnvrc at the downloaded nix-direnv")
    else:
        context.log("Wiring nix-direnv into direnvrc")
    wired.extend(block)
    direnvrc.parent.mkdir(parents=True, exist_ok=True)
    pending = direnvrc.with_name(f"{direnvrc.name}.tmp")
    pending.write_text("".join(f"{line}\n" for line in wired))
    pending.replace(direnvrc)


def install_nix_direnv(context: StepContext) -> None:
    """nix-direnv, as upstream's direnvrc at the pinned tag.

    `nix profile install nixpkgs#nix-direnv` fetched and unpacked the whole
    nixpkgs flake to install this one file, 18 seconds of a 109-second CI
    install job, and took whichever version nixpkgs-unstable held that day.
    """
    tools.require_command(context, "nix")
    _install_modern_bash(context)
    target = context.home / ".local" / "share" / "nix-direnv" / "direnvrc"
    current = _installed_version(target)
    if current and not context.upgrade:
        context.log(f"nix-direnv {current} already installed; skipping")
    else:
        tag = pins.pinned_tag(context, PIN)
        if current == tag:
            context.log(f"nix-direnv {current} already at latest; skipping")
        else:
            verb = "Upgrading nix-direnv to" if current else "Installing nix-direnv"
            context.log(f"{verb} {tag}")
            _fetch_direnvrc(context, tag, target)
    _wire(context)
    # Last, once nothing in direnvrc loads the profile's copy.
    if _profile_has(context, "nix-direnv"):
        context.log("Removing nix-direnv from the nix profile")
        context.run(["nix", "profile", "remove", "nix-direnv"])


STEPS = (
    Step("install_nix", install_nix),
    Step("install_nix_direnv", install_nix_direnv),
)
