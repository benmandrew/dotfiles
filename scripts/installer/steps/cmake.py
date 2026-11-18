"""CMake: Homebrew on macOS, Kitware's self-extracting installer on Linux."""

from __future__ import annotations

from pathlib import Path

from .. import brew, github, pins, release, tools
from ..runner import Step, StepContext

PIN = "CMAKE_VERSION"
# Where the Linux installer puts it.
PREFIX = Path("/usr/local")
_ARCH = {"aarch64": "linux-aarch64"}


def _current(context: StepContext, command: str | Path = "cmake") -> str | None:
    """The version `command` reports, or None when there is no such command."""
    if context.which(str(command)) is None:
        return None
    # `cmake version 4.4.3`, on the first line.
    words = (context.capture([str(command), "--version"]) or "").partition("\n")[0].split()
    return words[2] if len(words) > 2 else ""


def install(context: StepContext) -> None:
    required = pins.pin(PIN).removeprefix("v")
    current = _current(context)

    if context.host.system == "Darwin":
        if not context.upgrade and current is not None:
            if tools.version_gte(current, required):
                context.log(f"cmake {current} already satisfies >= {required}; skipping")
                return
            context.log(f"cmake {current} < {required}; upgrading")
        elif context.upgrade:
            context.log("Upgrading cmake")
        else:
            context.log("Installing cmake")
        verb = "upgrade" if brew.formula_installed(context, "cmake") else "install"
        context.run(["brew", verb, "cmake"])
        tools.require_runs(context, "cmake")
        return

    # Guard the copy this step installs, when there is one. Another copy earlier
    # on PATH, such as pip's in ~/.local/bin, would otherwise reinstall cmake
    # on every run without ever changing the version on PATH.
    target = PREFIX / "bin" / "cmake"
    owned = context.which(str(target)) is not None
    if owned:
        current = _current(context, target)

    if context.upgrade:
        version = github.latest_tag(context, pins.UPSTREAM[PIN]).removeprefix("v")
        if current == version:
            context.log(f"cmake {current} already at latest; skipping")
            if owned:
                tools.note_shadowed(context, "cmake", target)
            return
        context.log(f"Upgrading cmake to {version}")
    else:
        version = required
        if current is None:
            context.log(f"Installing cmake {version}")
        elif tools.version_gte(current, required):
            context.log(f"cmake {current} already satisfies >= {required}; skipping")
            if owned:
                tools.note_shadowed(context, "cmake", target)
            return
        else:
            context.log(f"cmake {current} < {required}; installing {version}")

    arch = _ARCH.get(context.host.machine, "linux-x86_64")
    installer = release.download(
        context,
        pins.repository(PIN),
        f"v{version}",
        f"cmake-{version}-{arch}.sh",
        f"cmake-{version}-SHA-256.txt",
    )
    tools.sudo(context, ["sh", str(installer), f"--prefix={PREFIX}", "--skip-license"])
    tools.note_shadowed(context, "cmake", target)
    tools.require_runs(context, target)


STEPS = (Step("install_cmake", install),)
