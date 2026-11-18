"""zsh and fish completions for the tools that can print their own.

These tools ship their completion nowhere useful. The step runs after every
other one, since it calls each binary. zsh's go to the user site-functions
directory that home/dot_zshrc.tmpl prepends to fpath; fish's go to the user
vendor_completions.d, which fish puts on $fish_complete_path by default.

A tool whose completion is already installed system-wide is skipped rather than
shadowed, so a later `brew upgrade` keeps ownership of it. delta is the
exception that motivated this: nothing ships a _delta, and zsh's bundled _sccs
registers the name `delta` for SCCS, so without a generated one git-delta
completes SCCS flags.

fish 4 also embeds completions for uv, uvx, delta, rustup, typst and chezmoi
in its binary, where no directory check can see them. The generated ones still
go first on $fish_complete_path and win, which is the point: they come from the
installed version of each tool, not from fish's snapshot of it.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

from ..runner import Step, StepContext

# Each command, and the arguments that make it print a completion script. Every
# one takes the shell's name as its last argument.
GENERATORS = (
    ("uv", ("generate-shell-completion",)),
    ("uvx", ("--generate-shell-completion",)),
    ("fd", ("--gen-completions",)),
    ("delta", ("--generate-completion",)),
    ("rustup", ("completions",)),
    ("atuin", ("gen-completions", "--shell")),
    ("typst", ("completions",)),
    ("chezmoi", ("completion",)),
)


@dataclass(frozen=True)
class Shell:
    name: str
    # Under XDG_DATA_HOME.
    directory: str
    # The file a command's completion goes in, from the command's name.
    prefix: str
    suffix: str
    # How the log line counts what was written.
    noun: str


SHELLS = (
    Shell("zsh", "zsh/site-functions", "_", "", "zsh completion function(s)"),
    Shell("fish", "fish/vendor_completions.d", "", ".fish", "fish completion file(s)"),
)
# Where each shell looks by default. Homebrew links a completion here for most
# of its formulae; the same tool installed from a release tarball on Linux
# comes with nothing. fish's own completions directory counts too, since fish
# bundles completions for some of these tools.
SYSTEM_DIRECTORIES = {
    "zsh": (
        Path("/opt/homebrew/share/zsh/site-functions"),
        Path("/usr/local/share/zsh/site-functions"),
        Path("/usr/share/zsh/site-functions"),
        Path("/usr/share/zsh/vendor-completions"),
    ),
    "fish": (
        Path("/opt/homebrew/share/fish/vendor_completions.d"),
        Path("/usr/local/share/fish/vendor_completions.d"),
        Path("/usr/share/fish/vendor_completions.d"),
        Path("/usr/share/fish/completions"),
    ),
}


def _installed_system_wide(shell: Shell, command: str) -> bool:
    name = f"{shell.prefix}{command}{shell.suffix}"
    return any(os.path.exists(directory / name) for directory in SYSTEM_DIRECTORIES[shell.name])


def _generate(context: StepContext, argv: list[str], out: Path) -> bool:
    """Write what a generator prints to `out`, and say whether it printed anything.

    Through a temporary file: a generator that fails half way would otherwise
    leave a truncated script that breaks completion for that command until
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


def install_shell_completions(context: StepContext) -> None:
    data = Path(context.env.get("XDG_DATA_HOME") or f"{context.home}/.local/share")
    for shell in SHELLS:
        directory = data / shell.directory
        directory.mkdir(parents=True, exist_ok=True)
        generated = 0
        for command, arguments in GENERATORS:
            if context.which(command) is None or _installed_system_wide(shell, command):
                continue
            out = directory / f"{shell.prefix}{command}{shell.suffix}"
            if _generate(context, [command, *arguments, shell.name], out):
                generated += 1
            else:
                context.log(f"Could not generate {shell.name} completion for {command}; skipping")
        context.log(f"Generated {generated} {shell.noun} in {directory}")

    # compinit caches the command-to-function map in the dump and rereads fpath
    # only when the dump is stale. Drop it so the next shell picks the new
    # functions up instead of waiting out the 24-hour timer in .zshrc. fish
    # keeps no such cache and loads a completion file when first needed.
    zdotdir = Path(context.env.get("ZDOTDIR") or context.home)
    for dump in (".zcompdump", ".zcompdump.zwc"):
        (zdotdir / dump).unlink(missing_ok=True)


STEPS = (Step("install_shell_completions", install_shell_completions),)
