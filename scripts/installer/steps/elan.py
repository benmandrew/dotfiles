"""elan, Lean's toolchain manager.

It is the equivalent of rustup: it installs `lean` and `lake` per project from
the lean-toolchain file, so this step only has to put elan itself on the
machine. The release tarball holds `elan-init`, the one-shot installer, which
writes into ~/.elan.
"""

from __future__ import annotations

import os

from .. import pins, release, tools
from ..runner import Step, StepContext, StepFailed

PIN = "ELAN_VERSION"

_TRIPLES = {
    ("Darwin", "arm64"): "aarch64-apple-darwin",
    ("Darwin", "aarch64"): "aarch64-apple-darwin",
    ("Darwin", "x86_64"): "x86_64-apple-darwin",
    ("Linux", "x86_64"): "x86_64-unknown-linux-gnu",
    ("Linux", "amd64"): "x86_64-unknown-linux-gnu",
    ("Linux", "aarch64"): "aarch64-unknown-linux-gnu",
    ("Linux", "arm64"): "aarch64-unknown-linux-gnu",
}


def install(context: StepContext) -> None:
    elan = context.home / ".elan" / "bin" / "elan"
    if context.which("elan") is not None or os.access(elan, os.X_OK):
        if not context.upgrade:
            context.log("elan already installed; skipping")
            return
        context.log("Upgrading elan")
        tools.retry_once(context, [str(elan), "self", "update"])
        tools.require_runs(context, elan)
        return

    host = context.host
    triple = _TRIPLES.get((host.system, host.machine))
    if triple is None:
        context.log(f"Unsupported platform {host.system}/{host.machine} for elan install; skipping")
        return

    tag = pins.pinned_tag(context, PIN)
    context.log(f"Installing elan {tag}")
    asset = f"elan-{triple}.tar.gz"
    # No checksum manifest is published alongside the tarballs.
    archive = release.download(context, pins.repository(PIN), tag, asset)
    init = release.unpack(context, archive) / "elan-init"
    if not os.access(init, os.X_OK):
        raise StepFailed(f"No elan-init inside {asset}; upstream layout changed")
    # --no-modify-path: ~/.elan/bin goes on PATH from the shell config, not from
    # a line elan-init appends to a profile file chezmoi owns.
    context.run([str(init), "-y", "--no-modify-path"])
    tools.note_shadowed(context, "elan", elan)
    tools.require_runs(context, elan)


STEPS = (Step("install_elan", install),)
