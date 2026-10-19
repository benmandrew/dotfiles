"""The typefaces of benmandrew.com, for Obsidian: casks on macOS, release zips on Linux.

Obsidian reads system fonts, so the vault's CSS snippet can name the site's
faces only once they are installed. The site's own woff2 files stay where they
are, in another repository; these come from upstream.
"""

from __future__ import annotations

from dataclasses import dataclass

from .. import pins, release, tools
from ..runner import Step, StepContext


@dataclass(frozen=True)
class Family:
    name: str
    cask: str
    pin: str
    # Under ~/.local/share/fonts.
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
        # The cask's super-TTC holds every width, Extended among them.
        cask="font-iosevka-slab",
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


def _install_cask(context: StepContext, family: Family) -> None:
    if context.succeeds(["brew", "list", "--cask", family.cask]):
        if not context.upgrade:
            context.log(f"{family.name} already installed; skipping")
            return
        context.log(f"Upgrading {family.name}")
        context.run(["brew", "upgrade", "--cask", family.cask])
        return
    context.log(f"Installing {family.name}")
    context.run(["brew", "install", "--cask", family.cask])


def _install_release(context: StepContext, family: Family) -> None:
    font_dir = context.home / ".local" / "share" / "fonts" / family.directory
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

    if context.host.system == "Darwin":
        for family in FAMILIES:
            _install_cask(context, family)
        return

    tools.require_command(context, "unzip")
    for family in FAMILIES:
        _install_release(context, family)


STEPS = (Step("install_site_fonts", install),)
