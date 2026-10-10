"""Tools installed from a GitHub release: gitleaks, glow, ripgrep-all, moor, treehouse."""

from __future__ import annotations

from dataclasses import dataclass

from .. import brew, pins, release, tools
from ..runner import Step, StepContext, StepFailed


@dataclass(frozen=True)
class ReleaseTool:
    """A tool Homebrew has for macOS and upstream ships as a tarball for Linux.

    The templates take {tag}, the tag as published; {version}, the same with
    any leading `v` removed; and {arch}, this machine's entry in `arch`.
    """

    # The Homebrew formula, and what the log lines call the tool.
    name: str
    # The binary that answers for it.
    command: str
    pin: str
    asset: str
    # `uname -m` to the word the asset name uses for it.
    arch: dict[str, str]
    # The checksum manifest in the same release, where upstream publishes one.
    manifest: str | None = None
    # Every binary to take from the tarball, when `command` is not the only one.
    binaries: tuple[str, ...] = ()
    probe: tuple[str, ...] = ()

    def step(self) -> Step:
        name = f"install_{self.name.replace('-', '_')}"
        return Step(name, lambda context: install(context, self))


TOOLS = (
    ReleaseTool(
        name="gitleaks",
        command="gitleaks",
        pin="GITLEAKS_VERSION",
        # Go release naming, so the asset carries `x64` or `arm64` rather than
        # a Rust target triple.
        asset="gitleaks_{version}_linux_{arch}.tar.gz",
        arch={"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"},
        manifest="gitleaks_{version}_checksums.txt",
        probe=("version",),
    ),
    ReleaseTool(
        name="glow",
        command="glow",
        pin="GLOW_VERSION",
        asset="glow_{version}_Linux_{arch}.tar.gz",
        arch={"x86_64": "x86_64", "aarch64": "arm64"},
        manifest="checksums.txt",
    ),
    ReleaseTool(
        name="ripgrep-all",
        command="rga",
        pin="RIPGREP_ALL_VERSION",
        asset="ripgrep_all-{tag}-{arch}.tar.gz",
        # musl on x86_64 and gnu on aarch64 is upstream's own split; those are
        # the only two Linux assets published. No checksum manifest is
        # published alongside them.
        arch={
            "x86_64": "x86_64-unknown-linux-musl",
            "amd64": "x86_64-unknown-linux-musl",
            "aarch64": "aarch64-unknown-linux-gnu",
            "arm64": "aarch64-unknown-linux-gnu",
        },
        # rga is two binaries, not one: `rga` shells out to `rga-preproc` for
        # every adapter it runs, so installing the first alone gives a tool
        # that fails on the first PDF it meets. Only rga is probed, since
        # rga-preproc wants a file and exits 1 on --version.
        binaries=("rga", "rga-preproc"),
    ),
)


def _announce(context: StepContext, name: str, command: str) -> bool:
    """Say what is about to happen to a tool, or return False to skip it."""
    if context.which(command) is None:
        context.log(f"Installing {name}")
    elif context.upgrade:
        context.log(f"Upgrading {name}")
    else:
        context.log(f"{name} already installed; skipping")
        return False
    return True


def install(context: StepContext, tool: ReleaseTool) -> None:
    if context.host.system == "Darwin":
        brew.formula(context, tool.name, tool.command, *tool.probe)
        return
    if not _announce(context, tool.name, tool.command):
        return
    arch = tool.arch.get(context.host.machine)
    if arch is None:
        context.log(f"Unsupported arch {context.host.machine} for {tool.name} install; skipping")
        return

    tag = pins.pinned_tag(context, tool.pin)
    names = {"tag": tag, "version": tag.removeprefix("v"), "arch": arch}
    asset = tool.asset.format(**names)
    manifest = tool.manifest.format(**names) if tool.manifest else None
    archive = release.download(context, pins.repository(tool.pin), tag, asset, manifest)
    unpacked = release.unpack(context, archive)
    for name in tool.binaries or (tool.command,):
        binary = release.find_file(unpacked, name)
        if binary is None:
            raise StepFailed(f"No {name} binary inside {asset}")
        tools.install_binary(context, binary, name)
    target = tools.local_bin(context) / tool.command
    tools.note_shadowed(context, tool.command, target)
    tools.require_runs(context, target, *tool.probe)


def install_moor(context: StepContext) -> None:
    if context.host.system == "Darwin":
        brew.formula(context, "moor", "moor")
        return
    if not _announce(context, "moor", "moor"):
        return
    tag = pins.pinned_tag(context, "MOOR_VERSION")

    if context.host.machine == "aarch64":
        # No official arm64 binary; build from source. install_go ensures a
        # modern Go is available; GOTOOLCHAIN=auto downloads a newer toolchain
        # if go.mod requires one beyond what's installed.
        context.run(
            ["go", "install", f"github.com/walles/moor/v2/cmd/moor@{tag}"],
            env={**context.env, "GOTOOLCHAIN": "auto"},
        )
        gobin = context.capture(["go", "env", "GOBIN"])
        if gobin is None:
            raise StepFailed
        if not gobin:
            gobin = f"{context.capture(['go', 'env', 'GOPATH']) or ''}/bin"
        tools.note_shadowed(context, "moor", f"{gobin}/moor")
        tools.require_runs(context, f"{gobin}/moor")
        return

    # x86_64: the release asset is the binary itself. No checksum manifest is
    # published alongside it.
    binary = release.download(
        context, pins.repository("MOOR_VERSION"), tag, f"moor-{tag}-linux-amd64"
    )
    target = tools.install_binary(context, binary, "moor")
    tools.note_shadowed(context, "moor", target)
    tools.require_runs(context, target)


_GO_OS = {"Darwin": "darwin", "Linux": "linux"}
_GO_ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def install_treehouse(context: StepContext) -> None:
    """Not in brew, so the official release binary on every platform.

    The skip check comes before the tag resolves, so an install with nothing to
    do costs no network round trip.
    """
    current = ""
    if context.which("treehouse") is not None:
        words = (context.capture(["treehouse", "--version"], quiet=True) or "").split()
        current = words[-1] if words else ""
        if not context.upgrade:
            context.log(f"treehouse {current} already installed; skipping")
            return

    tag = pins.pinned_tag(context, "TREEHOUSE_VERSION")
    if current:
        if current == tag:
            context.log(f"treehouse {current} already at latest; skipping")
            return
        context.log(f"Upgrading treehouse to {tag}")
    else:
        context.log(f"Installing treehouse {tag}")

    host = context.host
    if host.system not in _GO_OS:
        context.log(f"Unsupported OS {host.system} for treehouse install; skipping")
        return
    if host.machine not in _GO_ARCH:
        context.log(f"Unsupported arch {host.machine} for treehouse install; skipping")
        return

    asset = f"treehouse-{tag}-{_GO_OS[host.system]}-{_GO_ARCH[host.machine]}.tar.gz"
    archive = release.download(
        context, pins.repository("TREEHOUSE_VERSION"), tag, asset, "checksums.txt"
    )
    binary = release.find_file(release.unpack(context, archive), "treehouse")
    if binary is None:
        raise StepFailed(f"No treehouse binary inside {asset}")
    target = tools.install_binary(context, binary, "treehouse")
    tools.note_shadowed(context, "treehouse", target)
    tools.require_runs(context, target)


STEPS = (
    *(tool.step() for tool in TOOLS),
    Step("install_moor", install_moor),
    Step("install_treehouse", install_treehouse),
)
