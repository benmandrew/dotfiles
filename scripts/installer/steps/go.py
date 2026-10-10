"""Go, on Linux. macOS gets Go through Homebrew when something needs it."""

from __future__ import annotations

import os
import re
from pathlib import Path

from .. import fetch, pins, release, tools
from ..runner import Step, StepContext, StepFailed

# Where the toolchain goes.
GO_ROOT = Path("/usr/local/go")
MIN_MINOR = 21

_ARCH = {"x86_64": "amd64", "aarch64": "arm64"}
_MINOR = re.compile(r".*go1\.([0-9]+)", re.DOTALL)


def _local(context: StepContext) -> dict[str, str]:
    """The environment with GOTOOLCHAIN=local.

    Without it a go.mod in the working directory asking for a newer Go would
    have `go version` download that one and report it.
    """
    return {**context.env, "GOTOOLCHAIN": "local"}


def _latest(context: StepContext) -> str:
    """The current release, as go.dev names it: `go1.24.2`.

    The status is checked: a bare curl left an empty version behind, which then
    built a tarball name of `.linux-amd64.tar.gz` and fetched a 404 page under
    it.
    """
    output = context.capture([*fetch.CURL, pins.GO_LATEST_URL])
    if output is None:
        raise StepFailed("Could not read the current Go release from go.dev")
    latest = output.partition("\n")[0]
    if not latest:
        raise StepFailed("go.dev returned no version")
    return latest


def install(context: StepContext) -> None:
    # GO_ROOT is checked directly rather than through PATH: a distro-packaged
    # /usr/bin/go can shadow the toolchain this step installs, making every run
    # think it needs to upgrade.
    owned = GO_ROOT / "bin" / "go"
    go: str | None = None
    if os.access(owned, os.X_OK):
        go = str(owned)
    elif context.which("go") is not None:
        go = "go"
    version_output = ""
    if go is not None:
        version_output = context.capture([go, "version"], env=_local(context)) or ""
        found = _MINOR.match(version_output)
        minor = int(found.group(1)) if found else 0
        if minor >= MIN_MINOR:
            if not context.upgrade:
                context.log(f"Go 1.{minor} already installed; skipping")
                return
            context.log("Upgrading Go")
        else:
            context.log(f"Go 1.{minor} < 1.{MIN_MINOR}; upgrading to latest stable")
    else:
        context.log("Installing Go")

    arch = _ARCH.get(context.host.machine)
    if arch is None:
        context.log(f"Unsupported arch {context.host.machine} for Go install; skipping")
        return

    # Pinned like every other toolchain here. Under --upgrade the current
    # release comes from go.dev.
    latest = pins.pin(pins.GO_PIN)
    if context.upgrade:
        latest = _latest(context)
        # `go version` prints "go version go1.24.2 linux/amd64". Only the
        # toolchain this step owns counts, so a distro go of the same version
        # does not stop GO_ROOT being installed.
        words = version_output.split() if go == str(owned) else []
        if len(words) > 2 and words[2] == latest:
            context.log(f"Go {latest} already at latest; skipping")
            return

    tarball = f"{latest}.linux-{arch}.tar.gz"
    archive = context.tmpdir() / tarball
    fetch.download_verified(
        context,
        f"https://go.dev/dl/{tarball}",
        archive,
        f"https://dl.google.com/go/{tarball}.sha256",
    )

    # Unpacked beside the live toolchain and swapped, rather than deleting
    # first: an extract that fails after `rm -rf /usr/local/go` used to leave
    # the machine with no Go at all, and the tar was unchecked.
    staged = release.unpack(context, archive) / "go"
    if not os.access(staged / "bin" / "go", os.X_OK):
        raise StepFailed(f"No go binary inside {tarball}; upstream layout changed")
    old = GO_ROOT.with_name(f"{GO_ROOT.name}.old")
    tools.sudo(context, ["rm", "-rf", old], check=False)
    if GO_ROOT.is_dir():
        tools.sudo(context, ["mv", GO_ROOT, old])
    if tools.sudo(context, ["mv", staged, GO_ROOT], check=False) != 0:
        tools.sudo(context, ["mv", old, GO_ROOT], check=False)
        raise StepFailed("Could not move the new Go into place")
    tools.sudo(context, ["rm", "-rf", old], check=False)
    # For the steps that follow, moor's `go install` among them.
    context.env["PATH"] = f"{GO_ROOT / 'bin'}{os.pathsep}{context.env.get('PATH', '')}"
    tools.require_runs(context, owned, "version", env=_local(context))


STEPS = (Step("install_go", install),)
