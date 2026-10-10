"""What the steps share: proving a tool runs, placing a binary, sudo."""

from __future__ import annotations

import os
import re
import shutil
from collections.abc import Sequence
from pathlib import Path

from .runner import StepContext, StepFailed
from .sudo import sudo_command

_LEADING_DIGITS = re.compile(r"\d+")


def require_runs(context: StepContext, command: str | Path, *probe: str) -> None:
    """Fail the step unless `command` runs.

    An installer's exit status says nothing about the binary it leaves behind.
    On 14 September 2026 `claude update` upgraded an npm install through npm,
    left the package's placeholder where the native binary belongs, and exited
    0; the step passed, its log was deleted, and the next `claude` failed. So
    every path that installs or upgrades an executable ends by running it. The
    probe must print and exit: no network, no GUI, nothing written.
    """
    probe = probe or ("--version",)
    if context.succeeds([str(command), *probe]):
        return
    resolved = context.which(str(command)) or "not on PATH"
    raise StepFailed(
        f"{command} does not run after installing ({resolved}; probed with '{' '.join(probe)}')"
    )


def note_shadowed(context: StepContext, command: str, target: str | Path) -> None:
    """Say so when another copy of `command` comes before `target` on PATH.

    A step that installs to a fixed path can still lose to a copy from a
    different install method, which then answers for the tool on every call.
    Name that copy rather than delete it: unlike the old starship in
    /usr/local/bin, it may belong to a package manager. Nothing is said when
    the command is not on PATH at all, as on a machine that has not run
    chezmoi apply.
    """
    found = context.which(command)
    if found is not None and found != str(target):
        context.log(
            f"Note: {command} on PATH is {found}, which shadows the copy just installed at {target}"
        )


def version_gte(current: str, required: str) -> bool:
    """Whether `current` is at least `required`, comparing major.minor.patch."""

    def parts(version: str) -> tuple[int, ...]:
        numbers = []
        for field in version.split(".")[:3]:
            digits = _LEADING_DIGITS.match(field)
            numbers.append(int(digits.group()) if digits else 0)
        return tuple(numbers + [0] * (3 - len(numbers)))

    return parts(current) >= parts(required)


def sudo(context: StepContext, argv: Sequence[str]) -> None:
    """Run a command as root, through the askpass helper when one is live."""
    context.run([*sudo_command(context.env), *argv])


def local_bin(context: StepContext) -> Path:
    """~/.local/bin, created if need be."""
    directory = context.home / ".local" / "bin"
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def install_binary(context: StepContext, source: Path, name: str) -> Path:
    """Put an executable in ~/.local/bin as `name`, and return where it went.

    Copied beside the destination and renamed over it, so a copy of the tool
    that is running keeps the file it started from.
    """
    target = local_bin(context) / name
    pending = target.with_name(f".{name}.new")
    shutil.copyfile(source, pending)
    os.chmod(pending, 0o755)
    os.replace(pending, target)
    return target
