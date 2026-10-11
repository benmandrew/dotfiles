"""opam, its root, and the two OCaml tools the Neovim config expects."""

from __future__ import annotations

import os
import time
from pathlib import Path

from .. import brew, pins, release, tools
from ..runner import Step, StepContext, StepFailed

OCAML_TOOLS = ("ocaml-lsp-server", "ocamlformat")

# Where zlib.h may be on a Mac, in the order tried. The SDK that `xcrun`
# reports goes between these two pairs.
ZLIB_INCLUDES = (Path("/opt/homebrew/opt/zlib/include"), Path("/usr/local/opt/zlib/include"))
CLT_INCLUDE = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include")


def _install_linux_binary(context: StepContext) -> None:
    arch = "arm64" if context.host.machine == "aarch64" else "x86_64"
    # opam signs its binaries with a detached GPG signature rather than
    # publishing a checksum manifest, and verifying one needs the opam release
    # key imported first, so this download is unverified.
    tag = pins.pinned_tag(context, "OPAM_VERSION")
    version = tag.removeprefix("v")
    if (
        context.upgrade
        and context.which("opam") is not None
        and context.capture(["opam", "--version"], quiet=True) == version
    ):
        context.log(f"opam {version} already at latest; skipping")
        return
    binary = release.download(
        context, pins.repository("OPAM_VERSION"), tag, f"opam-{version}-{arch}-linux"
    )
    # Renamed over the live binary, so a failed or truncated download leaves
    # the old opam working.
    target = tools.install_binary(context, binary, "opam")
    tools.note_shadowed(context, "opam", target)
    tools.require_runs(context, target)


def _sandboxing_works(context: StepContext) -> bool:
    return context.succeeds(
        ["bwrap", "--bind", "/", "/", "--dev-bind", "/dev", "/dev", "--proc", "/proc", "true"]
    )


def install_opam(context: StepContext) -> None:
    present = context.which("opam") is not None
    if tools.announce(context, "opam", present):
        if context.host.system == "Darwin":
            brew.install_or_upgrade(context, "opam", present)
            tools.require_runs(context, "opam")
        else:
            _install_linux_binary(context)

    # Initialise the opam root. A ~/.opam that opam cannot read is an
    # interrupted init, which opam will not redo in place, so it is moved
    # aside rather than skipped.
    root = context.home / ".opam"
    if (root / "config").is_file() and context.succeeds(["opam", "switch", "list"]):
        context.log("opam already initialised; skipping opam init")
    else:
        if root.exists():
            aside = root.with_name(f".opam.broken.{time.strftime('%Y%m%d%H%M%S')}")
            context.log(f"{root} is unusable; moving it to {aside} and initialising afresh")
            root.rename(aside)
        flags = ["--bare", "--yes", "--no-setup"]
        if not _sandboxing_works(context):
            context.log(
                "bwrap sandboxing unavailable (container/VM);"
                " initialising opam with --disable-sandboxing"
            )
            flags.append("--disable-sandboxing")
        context.run(["opam", "init", *flags])

    install_ocaml_tools(context)


def _macos_c_search_path(context: StepContext) -> Path | None:
    """Where a C header lives on a Mac whose active developer directory does
    not carry it.

    `xcode-select -p` can point at a nix-provided apple-sdk, as it does on the
    machine this was written on, at .../apple-sdk-14.4, and those SDKs ship a
    subset of the headers a Command Line Tools SDK does. zlib.h is one of the
    missing ones, so /usr/bin/cc cannot preprocess `#include <zlib.h>` at all,
    and any opam package with a C stub needing it fails to build. Homebrew's
    keg-only zlib is preferred because it is the copy the rest of the machine
    already builds against; the CLT SDK is the fallback for a Mac without it.
    Setting SDKROOT does not help, since the CLT shim resolves its toolchain
    through xcode-select regardless.
    """
    sdk = context.capture(["xcrun", "--show-sdk-path"], quiet=True) or ""
    for candidate in (*ZLIB_INCLUDES, Path(f"{sdk}/usr/include"), CLT_INCLUDE):
        if (candidate / "zlib.h").is_file():
            return candidate
    return None


def _prepended(value: object, existing: str | None) -> str:
    return f"{value}{os.pathsep}{existing}" if existing else str(value)


def install_ocaml_tools(context: StepContext) -> None:
    """ocamllsp and ocamlformat, which the Neovim config enables and expects on
    PATH.

    They are opam packages, so they need a switch: `opam init --bare`
    deliberately creates none, and `opam install` into no switch fails.

    This installs into whichever `default` switch the machine already has,
    which is shared with whatever else the user keeps there. opam resolves the
    request against the whole switch, so it may recompile packages this step
    never asked for, and a build failing part way leaves opam rolling back the
    ones it had already removed. On 2 September 2026 camlzip failed on the
    missing zlib.h described above, and the rollback dropped alt-ergo and why3
    from the default switch. Hence the search path below, and hence failing the
    step loudly rather than continuing.
    """
    tools.require_command(context, "opam")

    if context.host.system == "Darwin":
        include = _macos_c_search_path(context)
        if include is None:
            raise StepFailed("No zlib.h on this Mac; opam packages with C stubs will not build")
        # Left in the environment for the steps that follow: a later build of
        # a C stub on this Mac wants the same two.
        env = context.env
        env["CPATH"] = _prepended(include, env.get("CPATH"))
        env["LIBRARY_PATH"] = _prepended(include.parent / "lib", env.get("LIBRARY_PATH"))

    switches = context.capture(["opam", "switch", "list", "--short"], quiet=True) or ""
    if "default" not in switches.splitlines():
        context.log("Creating the default opam switch")
        # --packages is required on both paths. `opam switch create <name>`
        # reads a bare name as a compiler specification, so `opam switch create
        # default --yes` looks for a compiler called "default" and exits with
        # "No compiler matching `default' found", which is what failed CI run
        # 33694339533 on a runner with no OCaml. ocaml-system reuses a compiler
        # already on the machine, the difference between seconds and a
        # from-source build; ocaml-base-compiler is that from-source build, and
        # is the only option where the machine has no ocamlc.
        compiler = "ocaml-system" if context.which("ocamlc") else "ocaml-base-compiler"
        context.run(["opam", "switch", "create", "default", f"--packages={compiler}", "--yes"])

    listing = ["opam", "list", "--switch", "default", "--installed", "--short"]
    installed = (context.capture(listing, quiet=True) or "").splitlines()
    missing = [package for package in OCAML_TOOLS if package not in installed]
    if missing:
        context.log(f"Installing {' '.join(missing)} into the default opam switch")
        context.run(["opam", "install", "--switch", "default", "--yes", *missing])
        return
    if not context.upgrade:
        context.log("ocaml-lsp-server and ocamlformat already installed; skipping")
        return
    context.log("Upgrading ocaml-lsp-server and ocamlformat")
    tools.retry_once(context, ["opam", "upgrade", "--switch", "default", "--yes", *OCAML_TOOLS])


STEPS = (Step("install_opam", install_opam),)
