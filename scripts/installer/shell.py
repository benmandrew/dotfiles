"""Taking on the environment a shell script sets up."""

from __future__ import annotations

from collections.abc import Collection
from pathlib import Path

from .runner import StepContext, StepFailed

# /bin/bash on every platform. The scripts sourced here are the nix profile
# and `brew shellenv`, both written for whichever shell the user has.
BASH = "/bin/bash"

# The sourcing shell's own bookkeeping, which says nothing about the script.
_SHELLS_OWN = frozenset({"_", "SHLVL", "PWD", "OLDPWD"})


def source(context: StepContext, script: Path, *, unset: Collection[str] = ()) -> None:
    """Source `script` and make the environment it leaves the steps' own.

    The steps used to be functions in one bash, where sourcing the nix profile
    or `brew shellenv` changed PATH for every step after it. A Python step has
    no shell to source into, so a bash of its own sources the script and prints
    its environment, NUL separated since a value may hold a newline. `unset`
    names variables to drop before the script runs.
    """
    env = {name: value for name, value in context.env.items() if name not in unset}
    # The script's own output goes to stderr, which leaves stdout to `env`.
    dump = context.capture([BASH, "-c", '. "$1" >&2; env -0', "bash", str(script)], env=env)
    if dump is None:
        raise StepFailed(f"Could not source {script}")
    carried: dict[str, str] = {}
    for entry in dump.split("\0"):
        name, separator, value = entry.partition("=")
        if separator and name and name not in _SHELLS_OWN:
            carried[name] = value
    kept = {name: context.env[name] for name in _SHELLS_OWN if name in context.env}
    context.env.clear()
    context.env.update(carried)
    context.env.update(kept)
