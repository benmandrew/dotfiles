"""What the steps share: proving a tool runs, placing a binary, sudo."""

from __future__ import annotations

import os
import re
import shutil
from collections.abc import Sequence
from pathlib import Path

from . import fetch
from .runner import StepContext, StepFailed
from .sudo import sudo_command

_LEADING_DIGITS = re.compile(r"\d+")

OS_RELEASE = Path("/etc/os-release")


def os_release(field: str) -> str:
    """A field of /etc/os-release without its quotes, or "" where it has none."""
    try:
        lines = OS_RELEASE.read_text(errors="replace").splitlines()
    except OSError:
        return ""
    for line in lines:
        name, separator, value = line.partition("=")
        if separator and name == field:
            return value.replace('"', "")
    return ""


def require_command(context: StepContext, command: str) -> None:
    """Fail the step unless `command` is on PATH."""
    if context.which(command) is None:
        raise StepFailed(f"Missing required command: {command}")


def retry_once(context: StepContext, argv: Sequence[str]) -> None:
    """Run a command, and once more if it fails.

    For vendor self-updaters, which fetch on their own rather than through
    fetch.download and its curl retries. On 14 September 2026 `rustup update`
    failed on one dropped download of a nightly component, rolled back cleanly,
    and succeeded when retried by hand. These updaters leave the old version in
    place on failure, so a second attempt is safe.
    """
    if context.call(argv) == 0:
        return
    context.log(f"{argv[0]} failed; retrying once")
    context.run(argv)


def announce(context: StepContext, label: str, present: bool) -> bool:
    """Say what is about to happen to a tool, or return False to skip it."""
    if not present:
        context.log(f"Installing {label}")
    elif context.upgrade:
        context.log(f"Upgrading {label}")
    else:
        context.log(f"{label} already installed; skipping")
        return False
    return True


def run_downloaded(
    context: StepContext,
    url: str,
    interpreter: Sequence[str],
    *args: str,
    env: dict[str, str] | None = None,
) -> None:
    """Fetch a vendor's install script and run it from disk.

    Never `curl | sh`: a download that fails half way would hand the shell half
    a script, and the fetch would skip the TLS floor and the retries that
    fetch.download sets.
    """
    script = context.tmpdir() / "install.sh"
    fetch.download(context, url, script)
    context.run([*interpreter, str(script), *args], env=env)


def load_cargo_env(context: StepContext) -> None:
    """Put cargo's bin directory on PATH, as sourcing ~/.cargo/env does."""
    if not (context.home / ".cargo" / "env").is_file():
        return
    cargo_bin = str(context.home / ".cargo" / "bin")
    path = context.env.get("PATH", "")
    if cargo_bin not in path.split(os.pathsep):
        context.env["PATH"] = f"{cargo_bin}{os.pathsep}{path}"


def npm_install_g(context: StepContext, *packages: str) -> None:
    """`npm install -g`, with npm's global prefix pinned to ~/.local.

    Pinned rather than trusting `npm prefix -g`. Homebrew's node points that at
    the versioned keg (Cellar/node/<version>), so globals installed there are
    orphaned by the next `brew upgrade node` while stale copies left in
    /opt/homebrew/lib/node_modules keep winning on PATH. ~/.local is
    version-independent and user-writable, so no sudo fallback either.
    """
    context.succeeds(["npm", "config", "set", "prefix", str(context.home / ".local")])
    context.run(["npm", "install", "-g", *packages])


def safe_git(context: StepContext, directory: Path, *args: str) -> None:
    """git in a clone, whoever owns it.

    safe_git and ensure_user_owns exist because upgrade paths for git-cloned
    tools (zinit, fzf, tpm) have hit repos owned by root, from an earlier sudo
    or CI run, which makes plain git refuse ("dubious ownership") or fail to
    write.
    """
    context.run(["git", "-c", f"safe.directory={directory}", "-C", str(directory), *args])


def ensure_user_owns(context: StepContext, directory: Path) -> None:
    """Take a directory back from another owner. See safe_git."""
    if not directory.is_dir() or directory.stat().st_uid == os.geteuid():
        return
    # By number, which chown takes as readily as a name and which an account
    # missing from the password database still has.
    sudo(context, ["chown", "-R", f"{os.geteuid()}:{os.getegid()}", directory], check=False)


def require_runs(
    context: StepContext, command: str | Path, *probe: str, env: dict[str, str] | None = None
) -> None:
    """Fail the step unless `command` runs.

    An installer's exit status says nothing about the binary it leaves behind.
    On 14 September 2026 `claude update` upgraded an npm install through npm,
    left the package's placeholder where the native binary belongs, and exited
    0; the step passed, its log was deleted, and the next `claude` failed. So
    every path that installs or upgrades an executable ends by running it. The
    probe must print and exit: no network, no GUI, nothing written.
    """
    probe = probe or ("--version",)
    if context.succeeds([str(command), *probe], env=env):
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


def cpu_count() -> int:
    """How many processors a build may use, as `nproc` counts them."""
    # macOS has no affinity mask to ask for.
    affinity = getattr(os, "sched_getaffinity", None)
    return len(affinity(0)) if affinity else os.cpu_count() or 1


def sudo(context: StepContext, argv: Sequence[object], *, check: bool = True) -> int:
    """Run a command as root, through the askpass helper when one is live.

    A non-zero exit fails the step unless `check` is off, and then it is
    returned.
    """
    status = context.call([*sudo_command(context.env), *map(str, argv)])
    if check and status != 0:
        raise StepFailed
    return status


def sudo_write(context: StepContext, path: Path, text: str, *, append: bool = False) -> None:
    """Write a root-owned file through `sudo tee`, failing the step if it cannot."""
    tee = ["tee", "-a"] if append else ["tee"]
    if context.feed([*sudo_command(context.env), *tee, str(path)], text) != 0:
        raise StepFailed


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
