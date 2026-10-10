"""Rust tools: a prebuilt release binary where upstream ships one, else `cargo install`.

The first seven tools here were compiled from source until August 2026. On the
CI runner that cost 5m21s of a 7m36s install run (eza 67s, bat 79s, delta 75s,
fd 36s, rg 22s, hyperfine 22s, zoxide 20s) and the same wait lands on any new
machine. All seven publish prebuilt binaries on their GitHub releases, so the
tarball is fetched instead and cargo is kept only as the fallback.
"""

from __future__ import annotations

import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

from .. import brew, pins, release, tools
from ..runner import Step, StepContext, StepFailed

MUSL_X86 = "x86_64-unknown-linux-musl"
MUSL_ARM = "aarch64-unknown-linux-musl"
GNU_ARM = "aarch64-unknown-linux-gnu"
MAC_ARM = "aarch64-apple-darwin"
MAC_X86 = "x86_64-apple-darwin"
MAC_FAT = "universal-apple-darwin"


@dataclass(frozen=True)
class CargoTool:
    """One tool's release assets.

    The release assets agree on nothing. eza leaves the version out of the file
    name entirely; fd, bat and hyperfine keep the tag's leading `v`; ripgrep,
    delta and zoxide strip it. Some unpack a bare binary, others a versioned
    directory. So the name is per-tool data ({tag} is the tag as published,
    {version} the same with the crate name and any leading `v` removed, and
    {triple} the Rust target triple) and the binary is found by searching the
    unpacked tree rather than by a path that would have to be spelled out seven
    different ways.
    """

    command: str
    pin: str
    asset: str
    # This tool's platform coverage: only triples upstream actually publishes
    # are named, so a platform absent from the list falls back to `cargo
    # install`. eza is the one that does on macOS, shipping no asset for it.
    triples: tuple[str, ...]
    # The crate `cargo install` takes, where it is not named after the command.
    crate: str = ""
    # The checksum file in the same release, for the upstreams that publish
    # one, which is the minority. {asset} in it stands for the asset name
    # already expanded.
    checksum: str | None = None


TOOLS = {
    tool.command: tool
    for tool in (
        CargoTool("eza", "EZA_VERSION", "eza_{triple}.tar.gz", (MUSL_X86, GNU_ARM)),
        CargoTool(
            "fd",
            "FD_VERSION",
            "fd-{tag}-{triple}.tar.gz",
            (MUSL_X86, MUSL_ARM, MAC_ARM),
            crate="fd-find",
        ),
        CargoTool("bat", "BAT_VERSION", "bat-{tag}-{triple}.tar.gz", (MUSL_X86, MUSL_ARM, MAC_ARM)),
        CargoTool(
            "rg",
            "RIPGREP_VERSION",
            "ripgrep-{version}-{triple}.tar.gz",
            (MUSL_X86, MUSL_ARM, MAC_ARM),
            crate="ripgrep",
            checksum="{asset}.sha256",
        ),
        CargoTool(
            "delta",
            "DELTA_VERSION",
            "delta-{version}-{triple}.tar.gz",
            (MUSL_X86, GNU_ARM, MAC_ARM),
            crate="git-delta",
        ),
        CargoTool(
            "hyperfine",
            "HYPERFINE_VERSION",
            "hyperfine-{tag}-{triple}.tar.gz",
            (MUSL_X86, GNU_ARM, MAC_ARM),
        ),
        CargoTool(
            "zoxide",
            "ZOXIDE_VERSION",
            "zoxide-{version}-{triple}.tar.gz",
            (MUSL_X86, MUSL_ARM, MAC_ARM),
        ),
        CargoTool(
            "difft",
            "DIFFTASTIC_VERSION",
            "difft-{version}-{triple}.tar.gz",
            (MUSL_X86, GNU_ARM, MAC_ARM, MAC_X86),
            crate="difftastic",
        ),
        CargoTool(
            "sccache",
            "SCCACHE_VERSION",
            "sccache-{tag}-{triple}.tar.gz",
            (MUSL_X86, MUSL_ARM, MAC_ARM, MAC_X86),
            checksum="{asset}.sha256",
        ),
        # Upstream publishes one fat macOS binary rather than a per-arch pair,
        # which is why universal-apple-darwin is in the triple list at all.
        CargoTool(
            "cargo-nextest",
            "CARGO_NEXTEST_VERSION",
            "{tag}-{triple}.tar.gz",
            (MUSL_X86, MUSL_ARM, MAC_FAT),
            checksum="{tag}-{triple}.sha256",
        ),
        # The five install_cargo_extras tools, built from source until October
        # 2026 at 389s of an 1,086s cold CI run, cargo-audit alone 164s.
        # rustsec/rustsec is a monorepo whose newest release may belong to
        # another crate (cvss/v3.0.0 when this was written), so its entry in
        # pins.UPSTREAM carries a tag prefix for github.latest_tag to filter on.
        CargoTool(
            "cargo-audit",
            "CARGO_AUDIT_VERSION",
            "cargo-audit-{triple}-v{version}.tgz",
            (MUSL_X86, GNU_ARM, MAC_ARM, MAC_X86),
        ),
        CargoTool(
            "cargo-llvm-cov",
            "CARGO_LLVM_COV_VERSION",
            "cargo-llvm-cov-{triple}.tar.gz",
            (MUSL_X86, MUSL_ARM, MAC_ARM, MAC_X86),
        ),
        CargoTool(
            "samply",
            "SAMPLY_VERSION",
            "samply-{triple}.tar.xz",
            (MUSL_X86, GNU_ARM, MAC_ARM, MAC_X86),
            checksum="{asset}.sha256",
        ),
        # x86_64 only, so ARM machines keep the cargo fallback for these two.
        CargoTool(
            "cargo-fuzz",
            "CARGO_FUZZ_VERSION",
            "cargo-fuzz-{version}-{triple}.tar.gz",
            (MUSL_X86, MAC_X86),
        ),
        CargoTool("cross", "CROSS_VERSION", "cross-{triple}.tar.gz", (MUSL_X86, MAC_X86)),
        # No aarch64 asset for either platform, so an ARM machine takes the
        # cargo fallback; git-absorb is a small crate and builds in seconds.
        CargoTool(
            "git-absorb",
            "GIT_ABSORB_VERSION",
            "git-absorb-{version}-{triple}.tar.gz",
            (MUSL_X86, MAC_X86),
        ),
        # .tar.xz, which tar -xf detects on its own. No checksum manifest is
        # published; the binary sits in a typst-<triple>/ directory.
        CargoTool(
            "typst",
            "TYPST_VERSION",
            "typst-{triple}.tar.xz",
            (MUSL_X86, MUSL_ARM, MAC_ARM, MAC_X86),
            crate="typst-cli",
        ),
    )
}

# Target triples for a machine, best first. musl leads gnu wherever a tool
# offers both, for the reason install_atuin sets out at length: upstream builds
# the gnu binaries against a newer glibc than the oldest distro here ships, and
# they die at the dynamic linker before main() runs. None of these tools is
# allocator-bound, so the static build costs nothing that matters.
_LINUX_X86 = (MUSL_X86, "x86_64-unknown-linux-gnu")
_LINUX_ARM = (MUSL_ARM, GNU_ARM)
_HOST_TRIPLES = {
    ("Linux", "x86_64"): _LINUX_X86,
    ("Linux", "amd64"): _LINUX_X86,
    ("Linux", "aarch64"): _LINUX_ARM,
    ("Linux", "arm64"): _LINUX_ARM,
    ("Darwin", "arm64"): (MAC_ARM, MAC_FAT),
    ("Darwin", "aarch64"): (MAC_ARM, MAC_FAT),
    ("Darwin", "x86_64"): (MAC_X86, MAC_FAT),
}

# Where a package puts a zsh completion function for everyone on the machine.
SYSTEM_COMPLETION_DIRS = (
    Path("/opt/homebrew/share/zsh/site-functions"),
    Path("/usr/local/share/zsh/site-functions"),
    Path("/usr/share/zsh/site-functions"),
    Path("/usr/share/zsh/vendor-completions"),
)

_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def _triple(context: StepContext, tool: CargoTool) -> str | None:
    """The best triple `tool` publishes for this machine, or None for a source build."""
    candidates = _HOST_TRIPLES.get((context.host.system, context.host.machine), ())
    return next((triple for triple in candidates if triple in tool.triples), None)


def _probe(command: str) -> tuple[str, ...]:
    """The arguments that make `command` print its version.

    A cargo subcommand run directly takes its own name first, as cargo passes
    it; cargo-llvm-cov rejects a bare --version. The other cargo-* tools here
    accept both forms.
    """
    if command.startswith("cargo-"):
        return (command.removeprefix("cargo-"), "--version")
    return ("--version",)


def _installed_version(context: StepContext, command: str) -> str:
    """The first x.y.z in `command`'s version output, or "" when there is none.

    Matched with a regex rather than by field, because the tools disagree
    there too: eza prints a bare `v0.23.5`, rg and eza print several lines, and
    some wrap the number in escape sequences.
    """
    output = context.capture([command, *_probe(command)], quiet=True)
    found = _VERSION.search(output or "")
    return found.group() if found else ""


def _load_cargo_env(context: StepContext) -> None:
    """Put cargo's bin directory on PATH, as sourcing ~/.cargo/env does."""
    if not (context.home / ".cargo" / "env").is_file():
        return
    cargo_bin = str(context.home / ".cargo" / "bin")
    path = context.env.get("PATH", "")
    if cargo_bin not in path.split(os.pathsep):
        context.env["PATH"] = f"{cargo_bin}{os.pathsep}{path}"


def _install_from_source(context: StepContext, tool: CargoTool) -> None:
    _load_cargo_env(context)
    if context.which("cargo") is None:
        raise StepFailed("Missing required command: cargo")
    # --locked builds against the dependency versions the crate was published
    # with, taken from the Cargo.lock it ships, rather than re-resolving every
    # dependency to the newest semver-compatible release. eza is what made this
    # necessary. It pins `palette = "=0.7.5"`, palette itself takes
    # `palette_derive = "0.7"`, and an unlocked resolve therefore pairs the 0.7.5
    # library with the 0.7.7 derive macro. That macro generates references to
    # `crate::lms` and `xyz::meta`, modules which only exist from 0.7.6, so the
    # build dies with 34 E0433s and takes the step with it. Every CI install job
    # between 13 and 18 August 2026 failed there. The shipped lockfile pairs
    # 0.7.5 with palette_derive 0.7.6, and `cargo install eza --locked` then
    # builds in 43s. Every crate installed through here ships a Cargo.lock,
    # which is what --locked needs.
    context.run(["cargo", "install", "--locked", tool.crate or tool.command])
    cargo_home = context.env.get("CARGO_HOME") or str(context.home / ".cargo")
    built = Path(cargo_home) / "bin" / tool.command
    tools.note_shadowed(context, tool.command, built)
    tools.require_runs(context, built, *_probe(tool.command))


def _completion_installed(command: str) -> bool:
    """Whether some package already put a completion for `command` where zsh looks.

    Homebrew links one for most of its formulae; the same tool installed from a
    release tarball on Linux comes with nothing.
    """
    return any((directory / f"_{command}").exists() for directory in SYSTEM_COMPLETION_DIRS)


def _install_completion(context: StepContext, unpacked: Path, command: str) -> None:
    """Install the zsh completion a tarball ships, where nothing else provides one.

    Several of these tarballs carry a completions/ directory, and for a tool
    with no "print your own completion" subcommand that archive is the only
    source there is: install_zsh_completions can generate for uv, fd, delta and
    the rest, but zoxide 0.9.9 has no such subcommand, so on Linux, where these
    arrive as bare binaries with no package manager to link a site-functions
    file, `zoxide <TAB>` completed nothing at all. Homebrew links one on macOS,
    which is why the gap only shows on the other platform. Skipped where a
    system-wide copy already exists, so the package manager keeps ownership,
    matching the policy install_zsh_completions follows.
    """
    completion = release.find_file(unpacked, f"_{command}")
    if completion is None or _completion_installed(command):
        return
    data_home = context.env.get("XDG_DATA_HOME") or str(context.home / ".local" / "share")
    target = Path(data_home) / "zsh" / "site-functions" / f"_{command}"
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(completion, target)
        target.chmod(0o644)
    except OSError as error:
        # The tool itself is installed, so a completion that cannot be written
        # does not fail the step.
        context.note(str(error))
        return
    context.log(f"Installed the zsh completion shipped with {command}")
    # compinit caches the command-to-function map in the dump and only rereads
    # fpath when the dump is stale, so drop it. Cheap, and this step does not
    # always run before install_zsh_completions, which does the same at the
    # end of a full run.
    zdotdir = Path(context.env.get("ZDOTDIR") or context.home)
    for dump in (".zcompdump", ".zcompdump.zwc"):
        (zdotdir / dump).unlink(missing_ok=True)


def _install_binary(context: StepContext, tool: CargoTool, triple: str) -> None:
    command = tool.command
    tag = pins.pinned_tag(context, tool.pin)
    # nextest-rs and samply tag the crate name into the tag
    # (`cargo-nextest-0.9.143`, `samply-v0.13.1`) and rustsec as a path
    # (`cargo-audit/v0.22.2`), so strip those and then a leading `v` before
    # comparing against what the installed binary reports.
    version = tag.removeprefix(f"{command}-").removeprefix(f"{command}/").removeprefix("v")
    if not version:
        raise StepFailed(f"Could not resolve the {command} release to install")

    if context.upgrade and context.which(command) is not None:
        current = _installed_version(context, command)
        if current == version:
            context.log(f"{command} {current} already at latest; skipping")
            return

    names = {"tag": tag, "version": version, "triple": triple}
    asset = tool.asset.format(**names)
    checksum = tool.checksum.format(asset=asset, **names) if tool.checksum else None
    archive = release.download(context, pins.repository(tool.pin), tag, asset, checksum)
    unpacked = release.unpack(context, archive)
    binary = release.find_file(unpacked, command)
    if binary is None:
        raise StepFailed(f"No {command} binary inside {asset}")
    target = tools.install_binary(context, binary, command)
    _install_completion(context, unpacked, command)

    # Delete the build this step left behind before it moved to prebuilt
    # binaries. ~/.local/bin leads ~/.cargo/bin in the rendered zshrc so the new
    # copy would win there anyway, but verify-install.sh searches the two the
    # other way round, and a stale build answering for the tool on every check
    # is exactly the shadowing install_starship had to unpick for /usr/local.
    (context.home / ".cargo" / "bin" / command).unlink(missing_ok=True)
    tools.note_shadowed(context, command, target)
    tools.require_runs(context, target, *_probe(command))


def install(context: StepContext, command: str) -> None:
    tool = TOOLS[command]
    triple = _triple(context, tool)

    # The skip check comes before the tag resolves, so a tool that is already
    # installed costs no API call.
    existing = context.which(command)
    if existing is not None and not context.upgrade:
        if triple is None or not existing.startswith(f"{context.home}/.cargo/bin/"):
            context.log(f"{command} already installed; skipping")
            return
        context.log(f"Replacing cargo-built {command} with the prebuilt binary")
    elif existing is not None:
        context.log(f"Upgrading {command}")
    else:
        context.log(f"Installing {command}")

    if triple is None:
        _install_from_source(context, tool)
    else:
        _install_binary(context, tool, triple)


def install_git_absorb(context: StepContext) -> None:
    """git-absorb, from Homebrew on macOS.

    It publishes no aarch64 asset for either platform, so on an ARM Mac it
    would be built from source on every fresh machine. brew has a bottle, so
    take that and leave Linux on the release binary.
    """
    if context.host.system == "Darwin":
        brew.formula(context, "git-absorb", "git-absorb")
    else:
        install(context, "git-absorb")


EXTRAS = ("cargo-audit", "cargo-fuzz", "cargo-llvm-cov", "cross", "samply")


def install_cargo_extras(context: StepContext) -> None:
    """Cargo tools for Rust work rather than for the shell.

    Each arrives as a prebuilt binary where its entry lists the platform and is
    built from source elsewhere (cargo-fuzz and cross on ARM). One step rather
    than five, so a failure is reported as one line, and each tool is skipped
    individually once installed.
    """
    # Every tool is tried, so one broken build does not leave the rest
    # uninstalled; the failures are named together at the end.
    failed = []
    for command in EXTRAS:
        try:
            install(context, command)
        except StepFailed as failure:
            if str(failure):
                context.console.err(str(failure))
            failed.append(command)
    if failed:
        raise StepFailed(f"cargo tools failed to install: {' '.join(failed)}")


def _step(name: str, command: str) -> Step:
    return Step(name, lambda context: install(context, command))


STEPS = (
    _step("install_eza", "eza"),
    _step("install_fd", "fd"),
    _step("install_bat", "bat"),
    _step("install_ripgrep", "rg"),
    _step("install_git_delta", "delta"),
    _step("install_hyperfine", "hyperfine"),
    _step("install_zoxide", "zoxide"),
    # Prebuilt release binaries where upstream publishes one for this platform,
    # and `cargo install` where it does not.
    _step("install_sccache", "sccache"),
    _step("install_difftastic", "difft"),
    _step("install_cargo_nextest", "cargo-nextest"),
    _step("install_typst", "typst"),
    Step("install_git_absorb", install_git_absorb),
    Step("install_cargo_extras", install_cargo_extras),
)
