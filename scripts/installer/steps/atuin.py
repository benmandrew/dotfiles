"""atuin: Homebrew on macOS, the static release binary on Linux.

atuin keeps shell history in its own SQLite database and syncs it one command
record at a time, so two machines merge without the conflict a shared
~/.zsh_history file produces. That file only ever appends locally, so git or
rsync sees two divergent tails and cannot reconcile them. Sync is end-to-end
encrypted with a key held on the machine, so the server stores ciphertext.
"""

from __future__ import annotations

from .. import brew, pins, release, tools
from ..runner import Step, StepContext, StepFailed

PIN = "ATUIN_VERSION"

# musl, not gnu. Upstream builds the gnu tarballs on a newer glibc than the
# oldest target distro here ships (18.19 needs GLIBC_2.38/2.39, jammy has 2.35)
# so the gnu binary exits at the dynamic linker with a `version GLIBC_2.38 not
# found` before main() ever runs. The musl builds are static, so they run on
# any of these machines; atuin's work is SQLite and a sync request, neither of
# which the musl allocator is a bottleneck for.
_TRIPLES = {
    "x86_64": "x86_64-unknown-linux-musl",
    "amd64": "x86_64-unknown-linux-musl",
    "aarch64": "aarch64-unknown-linux-musl",
    "arm64": "aarch64-unknown-linux-musl",
}


def _current(context: StepContext) -> str:
    """The version the atuin on PATH reports, or "" when it will not say.

    Field 2, not the last: `atuin --version` prints `atuin 18.19.0 ()`, with a
    trailing git-hash field, empty on some builds and the commit on others,
    that the last field would pick up instead of the version, making every
    --upgrade download a build that is already current.
    """
    words = (context.capture(["atuin", "--version"], quiet=True) or "").split()
    return words[1] if len(words) > 1 else ""


def install(context: StepContext) -> None:
    if context.host.system == "Darwin":
        brew.formula(context, "atuin", "atuin")
        return

    # Linux: the official release tarball, which upstream ships for both
    # arches. The skip check comes first, so an install that has nothing to do
    # costs no network round trip.
    present = context.which("atuin") is not None
    if present and not context.upgrade and context.succeeds(["atuin", "--version"]):
        context.log("atuin already installed; skipping")
        return

    tag = pins.pinned_tag(context, PIN)
    version = tag.removeprefix("v")
    if present:
        current = _current(context)
        if not current:
            # An atuin that will not report its version is a broken install,
            # not a present one: the gnu tarball this step used to fetch dies
            # at the dynamic linker on any distro whose glibc predates the
            # build host's. Reinstall over it, since treating it as installed
            # leaves the machine skipping the step and the binary broken for
            # ever.
            context.log(f"atuin present but not runnable; reinstalling {version}")
        elif not context.upgrade:
            context.log(f"atuin {current} already installed; skipping")
            return
        elif current == version:
            context.log(f"atuin {current} already at latest; skipping")
            return
        else:
            context.log(f"Upgrading atuin to {version}")
    else:
        context.log(f"Installing atuin {version}")

    triple = _TRIPLES.get(context.host.machine)
    if triple is None:
        context.log(f"Unsupported arch {context.host.machine} for atuin install; skipping")
        return

    asset = f"atuin-{triple}.tar.gz"
    archive = release.download(context, pins.repository(PIN), tag, asset, f"{asset}.sha256")
    binary = release.unpack(context, archive) / f"atuin-{triple}" / "atuin"
    if not binary.is_file():
        raise StepFailed(f"No atuin binary inside {asset}; upstream layout changed")
    target = tools.install_binary(context, binary, "atuin")
    tools.note_shadowed(context, "atuin", target)
    tools.require_runs(context, target)


STEPS = (Step("install_atuin", install),)
