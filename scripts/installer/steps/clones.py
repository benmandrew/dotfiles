"""Tools that are a git clone: the zsh plugins, fzf and the tmux plugin manager."""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import partial
from pathlib import Path

from .. import tools
from ..runner import Step, StepContext


@dataclass(frozen=True)
class Clone:
    """A repository the shell config sources straight from its clone."""

    step: str
    name: str
    # Under XDG_DATA_HOME.
    directory: str
    url: str
    branch: str
    shallow: bool = True


CLONES = (
    Clone(
        "install_zinit",
        "zinit",
        "zinit/zinit.git",
        "https://github.com/zdharma-continuum/zinit.git",
        "main",
        shallow=False,
    ),
    Clone(
        "install_fzf_tab", "fzf-tab", "fzf-tab", "https://github.com/Aloxaf/fzf-tab.git", "master"
    ),
    Clone(
        "install_zsh_autosuggestions",
        "zsh-autosuggestions",
        "zsh-autosuggestions",
        "https://github.com/zsh-users/zsh-autosuggestions.git",
        "master",
    ),
    # fzf-git.sh binds git objects (branches, tags, hashes, remotes, stashes)
    # onto fzf pickers. Clone-and-source, like fzf-tab, so the clone is all the
    # step does; the shell config sources it.
    Clone(
        "install_fzf_git",
        "fzf-git.sh",
        "fzf-git.sh",
        "https://github.com/junegunn/fzf-git.sh.git",
        "main",
    ),
)

FZF_URL = "https://github.com/junegunn/fzf.git"
TPM_URL = "https://github.com/tmux-plugins/tpm"


def _data_home(context: StepContext) -> Path:
    return Path(context.env.get("XDG_DATA_HOME") or context.home / ".local" / "share")


def install(context: StepContext, clone: Clone) -> None:
    directory = _data_home(context) / clone.directory
    if (directory / ".git").is_dir():
        if not context.upgrade:
            context.log(f"{clone.name} already installed; skipping")
            return
        context.log(f"Upgrading {clone.name}")
        tools.ensure_user_owns(context, directory)
        tools.safe_git(context, directory, "fetch", "origin")
        tools.safe_git(context, directory, "reset", "--hard", f"origin/{clone.branch}")
        return
    context.log(f"Installing {clone.name}")
    directory.parent.mkdir(parents=True, exist_ok=True)
    depth = ["--depth", "1"] if clone.shallow else []
    context.run(["git", "clone", *depth, clone.url, str(directory)])


def _fzf_binary(context: StepContext, root: Path) -> None:
    """Have fzf's installer fetch the binary, touching no shell config."""
    context.run([str(root / "install"), "--bin", "--no-update-rc", "--no-bash", "--no-fish"])
    tools.note_shadowed(context, "fzf", root / "bin" / "fzf")
    tools.require_runs(context, root / "bin" / "fzf")


def install_fzf(context: StepContext) -> None:
    root = context.home / ".fzf"
    if context.which("fzf") is not None:
        if not context.upgrade:
            context.log("fzf already installed; skipping")
            return
        context.log("Upgrading fzf")
        # An fzf from somewhere else, a package manager's say, is left alone.
        if root.is_dir():
            tools.ensure_user_owns(context, root)
            tools.safe_git(context, root, "pull")
            _fzf_binary(context, root)
        return
    context.log("Installing fzf")
    if root.is_dir():
        context.log("fzf already cloned; skipping")
    else:
        context.run(["git", "clone", "--depth", "1", FZF_URL, str(root)])
    _fzf_binary(context, root)


def install_tmux_plugins(context: StepContext) -> None:
    tools.require_command(context, "git")
    tpm = context.home / ".tmux" / "plugins" / "tpm"
    if tpm.is_dir():
        if context.upgrade:
            context.log("Upgrading tmux plugin manager (tpm)")
            tools.ensure_user_owns(context, tpm)
            tools.safe_git(context, tpm, "fetch", "origin")
            tools.safe_git(context, tpm, "reset", "--hard", "origin/master")
        else:
            context.log("tmux plugin manager (tpm) already installed; skipping")
    else:
        context.log("Installing tmux plugin manager (tpm)")
        tpm.parent.mkdir(parents=True, exist_ok=True)
        context.run(["git", "clone", TPM_URL, str(tpm)])

    # Cloning tpm installs no plugin: tpm's own binding does that, and nothing
    # here ever pressed it, so every machine had ~/.tmux/plugins holding tpm
    # alone and tmux-sensible's settings were never applied. install_plugins
    # reads the @plugin lines out of the tmux config and is a no-op once they
    # are all cloned, so it can run on every install. It needs no server and
    # skips tpm itself.
    #
    # It does need a tmux.conf that sources tpm, though: it reads
    # TMUX_PLUGIN_MANAGER_PATH out of the running config and aborts with
    # "Tmux Plugin Manager not configured in tmux.conf" when there is none.
    # The install scripts run before `chezmoi apply`, so on a fresh machine
    # ~/.tmux.conf does not exist yet and there are no @plugin lines to act
    # on, which is what failed CI run 33694339533. Skipping is the whole
    # answer: with no config there is nothing to install, and the next run
    # after chezmoi apply picks the plugins up.
    install_plugins = tpm / "bin" / "install_plugins"
    if not os.access(install_plugins, os.X_OK):
        return
    try:
        config = (context.home / ".tmux.conf").read_text(errors="replace")
    except OSError:
        config = ""
    if "tpm/tpm" not in config:
        context.log(
            "No ~/.tmux.conf sourcing tpm yet; skipping plugin install (re-run after chezmoi apply)"
        )
        return
    context.log("Installing tmux plugins")
    context.run([str(install_plugins)])


STEPS = (
    *(Step(clone.step, partial(install, clone=clone)) for clone in CLONES),
    Step("install_fzf", install_fzf),
    Step("install_tmux_plugins", install_tmux_plugins),
)
