"""Doom Emacs: terminal Emacs, and Doom cloned to ~/.config/emacs.

Emacs comes from Homebrew on macOS, whose core formula has no GUI, and from
the nix profile on Linux, since Ubuntu 22.04's apt holds it at 27.1 and Doom
needs 29.1 to run as an editor. The Doom config itself is chezmoi's, in
~/.config/doom; run_onchange_after_sync-doom-emacs.sh.tmpl syncs it.
"""

from __future__ import annotations

from pathlib import Path

from .. import brew, tools
from ..runner import Step, StepContext, StepFailed
from .nix import profile_has

MIN_VERSION = "29.1"
DOOM_URL = "https://github.com/doomemacs/core"
NIX_PACKAGE = "emacs-nox"


def _version(context: StepContext, command: str) -> str:
    """The version `emacs --version` reports on its first line, "GNU Emacs 31.1"."""
    output = context.capture([command, "--version"], quiet=True) or ""
    words = output.partition("\n")[0].split()
    return words[2] if words[:2] == ["GNU", "Emacs"] and len(words) > 2 else ""


def _install_linux(context: StepContext) -> str:
    """Install Emacs and return the one Doom should run."""
    tools.require_command(context, "nix")
    emacs = context.home / ".nix-profile" / "bin" / "emacs"
    if profile_has(context, NIX_PACKAGE):
        if not context.upgrade:
            context.log("Emacs already installed; skipping")
            return str(emacs)
        context.log("Upgrading Emacs")
        context.run(["nix", "profile", "upgrade", NIX_PACKAGE])
    else:
        # An Emacs some other package manager put there is left alone when it
        # is new enough for Doom, and shadowed by the nix one when it is not.
        found = context.which("emacs")
        current = _version(context, found) if found else ""
        if current and tools.version_gte(current, MIN_VERSION):
            context.log(f"Emacs {current} already installed; skipping")
            return str(found)
        if current:
            context.log(f"Emacs {current} < {MIN_VERSION}; installing nixpkgs#{NIX_PACKAGE}")
        else:
            context.log(f"Installing Emacs from nixpkgs#{NIX_PACKAGE}")
        context.run(["nix", "profile", "install", f"nixpkgs#{NIX_PACKAGE}"])
    tools.note_shadowed(context, "emacs", emacs)
    tools.require_runs(context, emacs)
    return str(emacs)


def _install_doom(context: StepContext, emacs: str) -> None:
    tools.require_command(context, "git")
    root = Path(context.env.get("XDG_CONFIG_HOME") or context.home / ".config") / "emacs"
    doom = str(root / "bin" / "doom")
    # bin/doom runs $EMACS, or the first emacs on PATH, which on Linux can be
    # apt's 27.1 ahead of the nix one.
    env = {**context.env, "EMACS": emacs}
    # --force answers Doom's prompts, which a held step would leave unseen.
    if (root / ".git").is_dir():
        if not context.upgrade:
            context.log("Doom Emacs already installed; skipping")
            return
        context.log("Upgrading Doom Emacs")
        tools.ensure_user_owns(context, root)
        # Pulls Doom and its module source, then runs `doom sync -u`.
        context.run([doom, "--force", "upgrade"], env=env)
        return
    if root.exists():
        raise StepFailed(f"{root} exists but is not a git clone; move it aside for Doom")
    context.log("Installing Doom Emacs")
    root.parent.mkdir(parents=True, exist_ok=True)
    context.run(["git", "clone", "--depth", "1", DOOM_URL, str(root)])
    # `doom install` checks out the module source, a submodule the clone leaves
    # empty, and syncs. --no-config, since chezmoi owns ~/.config/doom and an
    # apply would raise a "has changed" prompt over Doom's template files.
    # --no-env, since a terminal Emacs inherits the shell's environment.
    context.run([doom, "--force", "install", "--no-config", "--no-env"], env=env)
    # Emacs started from ~/.emacs.d or ~/.emacs never reads ~/.config/emacs.
    for shadow in (context.home / ".emacs.d", context.home / ".emacs"):
        if shadow.exists():
            context.log(f"Note: {shadow} exists, so Emacs will load it in place of Doom")


def install(context: StepContext) -> None:
    if context.host.system == "Darwin":
        brew.formula(context, "emacs", "emacs")
        emacs = context.which("emacs") or "emacs"
    else:
        emacs = _install_linux(context)
    # The doom script is proved by the install or upgrade that just ran: any
    # other call writes a log under ~/.config/emacs/.local, which a probe must
    # not.
    _install_doom(context, emacs)


STEPS = (Step("install_doom_emacs", install),)
