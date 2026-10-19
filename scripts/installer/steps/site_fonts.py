"""The typefaces of benmandrew.com, for Obsidian: a cask where one fits, else a release zip.

Obsidian reads system fonts, so the vault's CSS snippet can name the site's
faces only once they are installed. The site's own woff2 files stay where they
are, in another repository; these come from upstream.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .. import pins, release, tools
from ..runner import Step, StepContext


@dataclass(frozen=True)
class Family:
    name: str
    # Used on macOS when set; otherwise the release zip is used there too.
    cask: str | None
    pin: str
    # Under ~/Library/Fonts or ~/.local/share/fonts.
    directory: str
    # Formatted with the tag less its `v`.
    asset: str
    manifest: str | None
    # unzip patterns for the faces to keep, flattened into the directory. A
    # pattern that matches nothing fails the extract, so a renamed face is loud.
    members: tuple[str, ...]


FAMILIES = (
    Family(
        name="Libertinus Serif",
        cask="font-libertinus",
        pin="LIBERTINUS_VERSION",
        directory="Libertinus",
        asset="Libertinus-{version}.zip",
        # Upstream publishes no checksum, and GitHub records no digest for the
        # asset either, so this one download goes unverified.
        manifest=None,
        members=tuple(
            f"*/static/TTF/LibertinusSerif-{style}.ttf"
            for style in ("Regular", "Italic", "Bold", "BoldItalic")
        ),
    ),
    Family(
        name="Iosevka Slab",
        # No cask: see RETIRED_CASKS.
        cask=None,
        pin="IOSEVKA_VERSION",
        directory="IosevkaSlab",
        # Unhinted, at 123 MB against 179 MB hinted.
        asset="PkgTTF-Unhinted-IosevkaSlab-{version}.zip",
        manifest="SHA-256.txt",
        members=tuple(
            f"IosevkaSlab-Extended{style}.ttf" for style in ("", "Italic", "Bold", "BoldItalic")
        ),
    ),
)

# Casks an earlier version installed, removed on macOS. font-iosevka-slab is a
# 495 MB super-TTC that also holds Iosevka Term Slab, and a CoreText lookup
# that lands in it reads the whole file: WezTerm took 2 s to find its font
# again on every zoom.
RETIRED_CASKS = ("font-iosevka-slab",)


def _install_cask(context: StepContext, family: Family, cask: str) -> None:
    if context.succeeds(["brew", "list", "--cask", cask]):
        if not context.upgrade:
            context.log(f"{family.name} already installed; skipping")
            return
        context.log(f"Upgrading {family.name}")
        context.run(["brew", "upgrade", "--cask", cask])
        return
    context.log(f"Installing {family.name}")
    context.run(["brew", "install", "--cask", cask])


def _install_release(context: StepContext, family: Family, fonts: Path) -> None:
    font_dir = fonts / family.directory
    # The version file is written after unzip, so an interrupted extract leaves
    # none and the next run finishes the job.
    version_file = font_dir / ".version"
    installed = version_file.is_file()
    if installed and not context.upgrade:
        context.log(f"{family.name} already installed; skipping")
        return
    context.log(f"Upgrading {family.name}" if installed else f"Installing {family.name}")

    tag = pins.pinned_tag(context, family.pin)
    if installed and version_file.read_text().rstrip("\n") == tag:
        context.log(f"{family.name} {tag} already at latest; skipping")
        return
    asset = family.asset.format(version=tag[1:] if tag.startswith("v") else tag)
    archive = release.download(context, pins.repository(family.pin), tag, asset, family.manifest)
    font_dir.mkdir(parents=True, exist_ok=True)
    context.run(["unzip", "-joq", str(archive), *family.members, "-d", str(font_dir)])
    version_file.write_text(f"{tag}\n")
    # fontconfig may be absent, and the fonts are found without the cache.
    context.succeeds(["fc-cache", "-f", str(font_dir)])


def install(context: StepContext) -> None:
    if context.host.system == "Linux" and not (
        context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")
    ):
        context.log("Site fonts: no display session detected; skipping on headless Linux")
        return

    tools.require_command(context, "unzip")
    if context.host.system == "Darwin":
        for cask in RETIRED_CASKS:
            if context.succeeds(["brew", "list", "--cask", cask]):
                context.log(f"Removing the retired {cask} cask")
                context.run(["brew", "uninstall", "--cask", cask])
        fonts = context.home / "Library" / "Fonts"
    else:
        fonts = context.home / ".local" / "share" / "fonts"

    for family in FAMILIES:
        if context.host.system == "Darwin" and family.cask:
            _install_cask(context, family, family.cask)
        else:
            _install_release(context, family, fonts)


STEPS = (Step("install_site_fonts", install),)
