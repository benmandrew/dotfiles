"""nix-direnv, and the bash it needs on macOS."""

from __future__ import annotations

import re

from .. import tools
from ..runner import Step, StepContext, StepFailed

# What direnvrc loads. $HOME is for direnv's bash to expand.
SOURCE_LINE = "source $HOME/.nix-profile/share/nix-direnv/direnvrc"


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


STEPS = (Step("install_nix_direnv", install_nix_direnv),)
