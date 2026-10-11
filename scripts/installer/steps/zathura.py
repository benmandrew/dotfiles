"""zathura, a keyboard-driven PDF viewer.

The managed zathurarc wires up SyncTeX inverse search into VS Code, so the
build has to have SyncTeX support: Debian's package does, but the macOS formula
makes it an :optional dependency, hence --with-synctex.

macOS has no zathura in homebrew-core, so this uses the community tap. That tap
builds from source and ships each document backend as its own formula, so a
bare `brew install zathura` renders nothing at all; the backend plugin is not a
nicety. The plugin also has to be linked into place by hand: its formula
installs the .dylib into its own keg, while zathura only scans
$(brew --prefix zathura)/lib/zathura.

poppler is the backend on both platforms. The tap recommends mupdf and mupdf is
the faster renderer, but only in ratio: measured on a 6-page typst paper, a
single-page re-render, which is all watch mode does, is 24.3ms under mupdf
against 30.2ms under poppler, and typst's own compile of the same document is
92ms. A ~6ms edge is invisible next to that, and it costs 71MB of mupdf plus a
second renderer's quirks to learn. poppler is already present on most machines
and is what Debian ships, so one backend covers both platforms.
"""

from __future__ import annotations

import json
from pathlib import Path

from .. import apt, brew, tools
from ..runner import Step, StepContext, StepFailed

TAP = "homebrew-zathura/zathura"
BACKEND = "zathura-pdf-poppler"
PLUGIN = "libpdf-poppler.dylib"


def _tap_is_trusted(context: StepContext) -> bool:
    try:
        taps = json.loads(context.capture(["brew", "trust", "--json", "v1"]) or "")["taps"]
    except (ValueError, LookupError, TypeError):
        return False
    return isinstance(taps, list) and TAP in taps


def _install_macos(context: StepContext) -> None:
    if TAP not in (context.capture(["brew", "tap"]) or "").splitlines():
        context.log(f"Tapping {TAP}")
        context.call(["brew", "tap", TAP])
    # Homebrew 6 refuses to load formulae from an unofficial tap until it is
    # trusted. The refusal is a per-formula error rather than a failed tap, so
    # without this the step walks straight past it and "succeeds" having built
    # nothing. Answering yes to the optional-tool prompt is the opt-in;
    # re-asking per tap would make the install interactive again.
    if not _tap_is_trusted(context):
        context.log(f"Trusting tap {TAP}")
        context.run(["brew", "trust", "--tap", TAP])
    if not brew.formula_installed(context, "zathura"):
        context.log("Installing zathura")
        context.run(["brew", "install", "zathura", "--with-synctex"])
    elif context.upgrade:
        context.log("Upgrading zathura")
        # `brew upgrade` reuses the options a formula was installed with and
        # appends any given here, so --with-synctex also repairs a build that
        # predates it.
        context.run(["brew", "upgrade", "zathura", "--with-synctex"])
    else:
        context.log("zathura already installed; skipping")
    # Guarded separately from zathura itself: the two are distinct formulae,
    # and an interrupted first run can leave the viewer without a backend.
    if not brew.formula_installed(context, BACKEND):
        context.log(f"Installing {BACKEND}")
        context.run(["brew", "install", BACKEND])
    elif context.upgrade:
        context.log(f"Upgrading {BACKEND}")
        context.run(["brew", "upgrade", BACKEND])
    _link_pdf_plugin(context)
    tools.require_runs(context, "zathura", "--version")
    context.log("zathura on macOS is a command-line tool. To also get a /Applications bundle")
    context.log("  that opens PDFs on double-click, run the tap's convert-into-app.sh:")
    context.log("  https://github.com/homebrew-zathura/homebrew-zathura")


def _link_pdf_plugin(context: StepContext) -> None:
    # `brew --prefix <formula>` answers with the opt path whether or not the
    # formula is installed, so check installation separately or a failed
    # install gets misreported as an upstream layout change.
    if not brew.formula_installed(context, BACKEND):
        raise StepFailed(f"zathura: {BACKEND} is not installed; cannot link the PDF backend")
    zathura_prefix = context.capture(["brew", "--prefix", "zathura"]) or ""
    plugin_prefix = context.capture(["brew", "--prefix", BACKEND]) or ""
    plugin = Path(plugin_prefix) / PLUGIN
    if not plugin.is_file():
        raise StepFailed(f"zathura: no {PLUGIN} under {plugin_prefix}; upstream layout changed")
    plugins = Path(zathura_prefix) / "lib/zathura"
    plugins.mkdir(parents=True, exist_ok=True)
    link = plugins / PLUGIN
    link.unlink(missing_ok=True)
    link.symlink_to(plugin)


def install_zathura(context: StepContext) -> None:
    if context.host.system == "Darwin":
        _install_macos(context)
        return

    # A GUI document viewer buys nothing on a machine with no display.
    if not (context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")):
        context.log("zathura: no display session detected; skipping on headless Linux")
        return
    present = context.which("zathura") is not None and apt.installed(context, BACKEND)
    if not tools.announce(context, "zathura", present):
        return
    apt.install(context, "zathura", BACKEND)
    tools.require_runs(context, "zathura", "--version")


STEPS = (Step("install_zathura", install_zathura),)
