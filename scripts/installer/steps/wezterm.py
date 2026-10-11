"""WezTerm, and making it the default terminal on Linux."""

from __future__ import annotations

from .. import apt, release, tools
from ..runner import Step, StepContext

CASK = "wezterm@nightly"
REPOSITORY = "wezterm/wezterm"
# The Ubuntu releases nightly publishes a package for.
UBUNTU_BUILDS = ("20.04", "22.04", "24.04", "26.04")
# What the wezterm-nightly deb registers as a terminal emulator.
OPEN_HERE = "/usr/bin/open-wezterm-here"


def install_wezterm(context: StepContext) -> None:
    darwin = context.host.system == "Darwin"
    display = context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")
    if context.host.system == "Linux" and not display:
        context.log("WezTerm: no display session detected; skipping on headless Linux")
        return

    present = context.which("wezterm") is not None
    if not tools.announce(context, "WezTerm", present):
        return
    if darwin:
        if not present:
            context.run(["brew", "install", "--cask", CASK])
        # wezterm@nightly's cask upstream occasionally ships a broken source
        # glob; a failed upgrade reverts to the existing working install, so
        # treat it as best-effort rather than failing the whole run.
        elif context.call(["brew", "upgrade", "--cask", CASK]) != 0:
            context.log(
                "WezTerm nightly upgrade failed (likely upstream cask bug);"
                " keeping existing install; skipping"
            )
        # Either way: the reverted install has to run too.
        tools.require_runs(context, "wezterm")
        return

    # Linux binary download, tracking the rolling `nightly` tag rather than the
    # newest tagged release. WezTerm has cut no release since 20240203 (February
    # 2024), so `releases/latest` pinned Linux to a build two and a half years
    # behind the wezterm@nightly cask that macOS installs. The nightly tag name
    # never changes; its assets are rebuilt from the tip of main.
    if context.host.machine != "x86_64":
        # arm64 nightly debs are published but lag the x86_64 ones by months,
        # so there is nothing worth tracking on that architecture yet.
        context.log(f"WezTerm: no official binary for {context.host.machine}; skipping")
        return
    # Anything nightly has no package for falls back to 22.04, which runs on
    # newer Ubuntu.
    ubuntu = tools.os_release("VERSION_ID")
    if ubuntu not in UBUNTU_BUILDS:
        ubuntu = "22.04"
    # No "already at latest" check: the tag is fixed, so the installed version
    # string can never match it, and a nightly moves most days in any case.
    # This only runs under --upgrade, since an existing install returns above.
    deb = f"wezterm-nightly.Ubuntu{ubuntu}.deb"
    package = release.download(context, REPOSITORY, "nightly", deb, f"{deb}.sha256")
    apt.install(context, package)
    tools.require_runs(context, "wezterm")


def set_default_terminal_wezterm(context: StepContext) -> None:
    # GNOME's Ctrl+Alt+T and "Open in Terminal" run x-terminal-emulator, which
    # otherwise points at whichever terminal registered the highest priority.
    # The wezterm-nightly deb registers open-wezterm-here; without it (headless,
    # or arm64, where install_wezterm skips) there is nothing to point at.
    query = context.capture(["update-alternatives", "--query", "x-terminal-emulator"], quiet=True)
    lines = (query or "").splitlines()
    if f"Alternative: {OPEN_HERE}" not in lines:
        context.log(f"x-terminal-emulator: {OPEN_HERE} not registered; skipping")
        return
    if f"Value: {OPEN_HERE}" in lines:
        context.log("x-terminal-emulator already WezTerm; skipping")
        return
    context.log("Setting x-terminal-emulator to WezTerm")
    tools.sudo(context, ["update-alternatives", "--set", "x-terminal-emulator", OPEN_HERE])


STEPS = (
    Step("install_wezterm", install_wezterm),
    Step("set_default_terminal_wezterm", set_default_terminal_wezterm),
)
