"""zsh completion functions for the tools that can print their own.

These tools ship their completion nowhere useful. The step runs after every
other one, since it calls each binary. The output goes to the user
site-functions directory that home/dot_zshrc.tmpl prepends to fpath.

A tool whose completion is already installed system-wide is skipped rather than
shadowed, so a later `brew upgrade` keeps ownership of it. delta is the
exception that motivated this: nothing ships a _delta, and zsh's bundled _sccs
registers the name `delta` for SCCS, so without a generated one git-delta
completes SCCS flags.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from ..runner import Step, StepContext

# Each command, and the arguments that make it print a zsh completion script.
GENERATORS = (
    ("uv", ("generate-shell-completion", "zsh")),
    ("uvx", ("--generate-shell-completion", "zsh")),
    ("fd", ("--gen-completions", "zsh")),
    ("delta", ("--generate-completion", "zsh")),
    ("rustup", ("completions", "zsh")),
    ("atuin", ("gen-completions", "--shell", "zsh")),
    ("typst", ("completions", "zsh")),
    ("chezmoi", ("completion", "zsh")),
)
# Where zsh looks by default. Homebrew links a completion function here for
# most of its formulae; the same tool installed from a release tarball on Linux
# comes with nothing.
SYSTEM_DIRECTORIES = (
    Path("/opt/homebrew/share/zsh/site-functions"),
    Path("/usr/local/share/zsh/site-functions"),
    Path("/usr/share/zsh/site-functions"),
    Path("/usr/share/zsh/vendor-completions"),
)


def _installed_system_wide(command: str) -> bool:
    return any(os.path.exists(directory / f"_{command}") for directory in SYSTEM_DIRECTORIES)


def _generate(context: StepContext, argv: list[str], out: Path) -> bool:
    """Write what a generator prints to `out`, and say whether it printed anything.

    Through a temporary file: a generator that fails half way would otherwise
    leave a truncated function that breaks completion for that command until
    the next run.
    """
    partial = out.with_name(f"{out.name}.tmp")
    try:
        with partial.open("wb") as handle:
            done = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=handle,
                stderr=subprocess.DEVNULL,
                env=context.env,
                check=False,
            )
        if done.returncode == 0 and partial.stat().st_size > 0:
            partial.replace(out)
            return True
    except OSError:
        pass
    partial.unlink(missing_ok=True)
    return False


def install_zsh_completions(context: StepContext) -> None:
    data = context.env.get("XDG_DATA_HOME") or f"{context.home}/.local/share"
    directory = Path(data) / "zsh/site-functions"
    directory.mkdir(parents=True, exist_ok=True)

    generated = 0
    for command, arguments in GENERATORS:
        if context.which(command) is None or _installed_system_wide(command):
            continue
        if _generate(context, [command, *arguments], directory / f"_{command}"):
            generated += 1
        else:
            context.log(f"Could not generate zsh completion for {command}; skipping")
    context.log(f"Generated {generated} zsh completion function(s) in {directory}")

    # compinit caches the command-to-function map in the dump and rereads fpath
    # only when the dump is stale. Drop it so the next shell picks the new
    # functions up instead of waiting out the 24-hour timer in .zshrc.
    zdotdir = Path(context.env.get("ZDOTDIR") or context.home)
    for dump in (".zcompdump", ".zcompdump.zwc"):
        (zdotdir / dump).unlink(missing_ok=True)


STEPS = (Step("install_zsh_completions", install_zsh_completions),)
