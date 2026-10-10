"""Steps that are still bash. This module goes when the last of them does."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

from .runner import Step, StepContext, StepFailed

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
SHIM = SCRIPTS_DIR / "legacy-step.sh"

# /bin/bash on every platform, where the old entry point took whichever bash
# came first on PATH. That is 3.2 on macOS, which the bash steps are written
# for, and a devShell bash 5 ahead of it on PATH would hide a slip.
BASH = "/bin/bash"

# Set for the bash step alone, and bash's own bookkeeping. None of it is the
# step's doing, so none of it is carried to the next step.
_NOT_CARRIED = frozenset({"DOTFILES_TERM_FD", "DOTFILES_UPGRADE", "_", "SHLVL", "PWD", "OLDPWD"})


def legacy(name: str, *args: str, interactive: bool = False, fatal: bool = False) -> Step:
    """A step that calls the bash function `name` with `args`."""

    def action(context: StepContext) -> None:
        run_legacy(context, name, args)

    return Step(name=name, action=action, args=args, interactive=interactive, fatal=fatal)


def run_legacy(context: StepContext, name: str, args: tuple[str, ...]) -> None:
    """Call one bash function in a bash of its own.

    The steps used to share one shell, so `brew shellenv`, the nix profile, and
    the PATH lines in install_uv and install_go reached every step after them.
    The shim writes the environment the function left behind, and the runner
    adopts it, which keeps that working across separate processes. A function
    that takes its shell down (`exit`, an unset variable under `set -u`) writes
    nothing, and the environment stays as it was.
    """
    handle, env_out = tempfile.mkstemp(prefix="dotfiles-env.")
    os.close(handle)
    try:
        env = dict(context.env)
        # Where the step's `log` and `err` write, its own stdout and stderr
        # being held in the step log.
        env["DOTFILES_TERM_FD"] = str(context.console.fd)
        env["DOTFILES_UPGRADE"] = "true" if context.settings.upgrade else ""
        status = context.call(
            [BASH, str(SHIM), env_out, name, *args],
            env=env,
            pass_fds=(context.console.fd,),
        )
        _adopt_environment(context.env, Path(env_out))
    finally:
        os.unlink(env_out)
    if status != 0:
        raise StepFailed


def _adopt_environment(env: dict[str, str], dump: Path) -> None:
    """Replace `env` in place with the `env -0` output in `dump`, if any."""
    data = dump.read_bytes()
    if not data:
        return
    carried: dict[str, str] = {}
    for entry in data.split(b"\0"):
        name, separator, value = entry.partition(b"=")
        if separator and name and os.fsdecode(name) not in _NOT_CARRIED:
            carried[os.fsdecode(name)] = os.fsdecode(value)
    env.clear()
    env.update(carried)
