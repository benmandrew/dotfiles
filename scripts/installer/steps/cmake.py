"""CMake: Homebrew on macOS, Kitware's self-extracting installer on Linux."""

from __future__ import annotations

from pathlib import Path

from .. import brew, github, pins, release, tools
from ..runner import Step, StepContext

PIN = "CMAKE_VERSION"
# Where the Linux installer puts it.
PREFIX = Path("/usr/local")
_ARCH = {"aarch64": "linux-aarch64"}


def _current(context: StepContext) -> str | None:
    """The version of the cmake on PATH, or None when there is none."""
    if context.which("cmake") is None:
        return None
    # `cmake version 4.4.3`, on the first line.
    words = (context.capture(["cmake", "--version"]) or "").partition("\n")[0].split()
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

    if context.upgrade:
        version = github.latest_tag(context, pins.UPSTREAM[PIN]).removeprefix("v")
        if current == version:
            context.log(f"cmake {current} already at latest; skipping")
            return
        context.log(f"Upgrading cmake to {version}")
    else:
        version = required
        if current is None:
            context.log(f"Installing cmake {version}")
        elif tools.version_gte(current, required):
            context.log(f"cmake {current} already satisfies >= {required}; skipping")
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
    target = PREFIX / "bin" / "cmake"
    tools.note_shadowed(context, "cmake", target)
    tools.require_runs(context, target)


STEPS = (Step("install_cmake", install),)
