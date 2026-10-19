"""Iosevka Term, WezTerm's text font: the release zip on both platforms.

Homebrew has no cask for it, only the Nerd Font build, whose family name differs.
"""

from __future__ import annotations

import shutil

from .. import pins, release, tools
from ..runner import Step, StepContext

NAME = "Iosevka Term"
PIN = "IOSEVKA_VERSION"
# Unhinted, at 122 MB against 177 MB hinted. wezterm.lua sets light hinting,
# under which FreeType's auto-hinter replaces the font's own instructions.
ASSET = "PkgTTF-Unhinted-IosevkaTerm-{version}.zip"
# The faces wezterm.lua resolves to: SemiBold for normal text, Heavy for bold
# and Light for half intensity, each with its italic.
MEMBERS = tuple(
    f"IosevkaTerm-{weight}{style}.ttf"
    for weight in ("SemiBold", "Heavy", "Light")
    for style in ("", "Italic")
)


def install(context: StepContext) -> None:
    if context.host.system == "Linux" and not (
        context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")
    ):
        context.log(f"{NAME}: no display session detected; skipping on headless Linux")
        return

    tools.require_command(context, "unzip")
    if context.host.system == "Darwin":
        font_dir = context.home / "Library" / "Fonts" / "IosevkaTerm"
    else:
        font_dir = context.home / ".local" / "share" / "fonts" / "IosevkaTerm"
    # An earlier version installed the slab variant beside it, which nothing
    # uses now.
    retired = font_dir.with_name("IosevkaTermSlab")
    if retired.is_dir():
        context.log("Removing the retired Iosevka Term Slab")
        shutil.rmtree(retired)
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
    asset = ASSET.format(version=tag[1:] if tag.startswith("v") else tag)
    archive = release.download(context, pins.repository(PIN), tag, asset, "SHA-256.txt")
    font_dir.mkdir(parents=True, exist_ok=True)
    context.run(["unzip", "-joq", str(archive), *MEMBERS, "-d", str(font_dir)])
    version_file.write_text(f"{tag}\n")
    # fontconfig may be absent, and the fonts are found without the cache.
    context.succeeds(["fc-cache", "-f", str(font_dir)])


STEPS = (Step("install_terminal_font", install),)
