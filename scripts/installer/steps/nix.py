"""Nix, and nix-direnv with the bash it needs on macOS."""

from __future__ import annotations

import os
import pwd
import re
from pathlib import Path

from .. import shell, tools
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

# What direnvrc loads. $HOME is for direnv's bash to expand.
SOURCE_LINE = "source $HOME/.nix-profile/share/nix-direnv/direnvrc"


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


def install_nix_direnv(context: StepContext) -> None:
    tools.require_command(context, "nix")
    _install_modern_bash(context)
    if _profile_has(context, "nix-direnv"):
        if context.upgrade:
            context.log("Upgrading nix-direnv")
            context.run(["nix", "profile", "upgrade", "nix-direnv"])
        else:
            context.log("nix-direnv already installed; skipping")
    else:
        context.log("Installing nix-direnv")
        context.run(["nix", "profile", "install", "nixpkgs#nix-direnv"])
    # The file the source line below loads. A profile entry whose package
    # failed to link would otherwise leave direnvrc sourcing nothing.
    if not (context.home / ".nix-profile" / "share" / "nix-direnv" / "direnvrc").is_file():
        raise StepFailed(
            "nix-direnv is not in the nix profile"
            " (~/.nix-profile/share/nix-direnv/direnvrc missing)"
        )
    direnvrc = context.home / ".config" / "direnv" / "direnvrc"
    if direnvrc.is_file() and "nix-direnv/direnvrc" in direnvrc.read_text(errors="replace"):
        return
    context.log("Wiring nix-direnv into direnvrc")
    direnvrc.parent.mkdir(parents=True, exist_ok=True)
    with direnvrc.open("a") as handle:
        handle.write(f"{SOURCE_LINE}\n")


STEPS = (
    Step("install_nix", install_nix),
    Step("install_nix_direnv", install_nix_direnv),
)
