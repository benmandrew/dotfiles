"""The CodeNewRoman Nerd Font: a cask on macOS, the release zip on Linux."""

from __future__ import annotations

from .. import pins, release, tools
from ..runner import Step, StepContext

NAME = "CodeNewRoman Nerd Font"
CASK = "font-code-new-roman-nerd-font"
PIN = "NERD_FONTS_VERSION"


def install(context: StepContext) -> None:
    if context.host.system == "Linux" and not (
        context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")
    ):
        context.log(f"{NAME}: no display session detected; skipping on headless Linux")
        return

    if context.host.system == "Darwin":
        if context.succeeds(["brew", "list", "--cask", CASK]):
            if not context.upgrade:
                context.log(f"{NAME} already installed; skipping")
                return
            context.log(f"Upgrading {NAME}")
            context.run(["brew", "upgrade", "--cask", CASK])
            return
        context.log(f"Installing {NAME}")
        context.run(["brew", "install", "--cask", CASK])
        return

    # Linux: no cask equivalent, so the patched font comes from the nerd-fonts
    # releases.
    tools.require_command(context, "unzip")
    font_dir = context.home / ".local" / "share" / "fonts" / "CodeNewRomanNerdFont"
    # The version file is written after unzip, so an interrupted extract leaves
    # none and the next run finishes the job.
    version_file = font_dir / ".version"
    installed = version_file.is_file()
    if installed and not context.upgrade:
        context.log(f"{NAME} already installed; skipping")
        return
    context.log(f"Upgrading {NAME}" if installed else f"Installing {NAME}")

    tag = pins.pinned_tag(context, PIN)
    if installed and version_file.read_text().rstrip("\n") == tag:
        context.log(f"{NAME} {tag} already at latest; skipping")
        return
    archive = release.download(
        context, pins.repository(PIN), tag, "CodeNewRoman.zip", "SHA-256.txt"
    )
    font_dir.mkdir(parents=True, exist_ok=True)
    context.run(["unzip", "-oq", str(archive), "-d", str(font_dir)])
    version_file.write_text(f"{tag}\n")
    # fontconfig may be absent, and the fonts are found without the cache.
    context.succeeds(["fc-cache", "-f", str(font_dir)])


STEPS = (Step("install_nerd_font", install),)
