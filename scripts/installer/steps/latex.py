"""TeX Live.

Linux takes upstream TeX Live through install-tl, since apt pins it to the
distro's release year: Ubuntu 22.04 ships TeX Live 2021 and biber 2.17, and a
biber that lags biblatex refuses the .bcf files it writes. The collections
match the apt packages this replaced (texlive-latex-extra, -fonts-extra,
-fonts-recommended, -extra-utils, -bibtex-extra, -science) short of
texlive-full's language packs; docs and sources are skipped. macOS takes MacTeX
without its GUI apps: the full TeX Live scheme, which already carries latexmk
and biber. BasicTeX is a tenth of the size but lacks most of what the Linux set
pulls in, and tlmgr-installing the gap by hand would make the two platforms
drift.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
from pathlib import Path

from .. import apt, brew, fetch, release, tools
from ..runner import Step, StepContext, StepFailed

REPOSITORY = "https://mirror.ctan.org/systems/texlive/tlnet"
COLLECTIONS = (
    "collection-basic",
    "collection-latex",
    "collection-latexrecommended",
    "collection-latexextra",
    "collection-fontsrecommended",
    "collection-fontsextra",
    "collection-binextra",
    "collection-bibtexextra",
    "collection-mathscience",
    "collection-pictures",
    "collection-plaingeneric",
    "collection-luatex",
)
# Written into a TEXDIR once install-tl has finished there. install-tl lays
# tlmgr down first, so a tlmgr alone does not mean the collections followed.
COMPLETE_MARKER = ".dotfiles-complete"
INSTALLER = "install-tl-unx.tar.gz"
CASK = "mactex-no-gui"
# The pkg installer puts binaries here and adds it to PATH through
# /etc/paths.d/TeX, which a running shell has not read.
TEXBIN = Path("/Library/TeX/texbin")

_YEAR = re.compile(r"20[0-9][0-9]")


def _root(context: StepContext) -> Path:
    return context.home / ".local/texlive"


def _complete(texdir: Path) -> bool:
    """Whether install-tl finished in a TEXDIR.

    A tree from before the marker counts when its package database lists every
    collection, and gets the marker then.
    """
    marker = texdir / COMPLETE_MARKER
    if marker.is_file():
        return True
    try:
        packages = set((texdir / "tlpkg/texlive.tlpdb").read_text(errors="replace").splitlines())
        if any(f"name {collection}" not in packages for collection in COLLECTIONS):
            return False
        marker.touch()
    except OSError:
        return False
    return True


def _bin_dir(texdir: Path) -> Path | None:
    """bin/<platform> of a TEXDIR.

    install-tl names the platform itself (x86_64-linux, aarch64-linux), so it
    is looked for rather than derived.
    """
    return next((path for path in sorted(texdir.glob("bin/*")) if path.is_dir()), None)


def _installed_year(root: Path) -> str:
    """The newest complete year directory under the root; empty when none."""
    year = ""
    for texdir in sorted(root.glob("20[0-9][0-9]")):
        bin_dir = _bin_dir(texdir)
        if bin_dir and os.access(bin_dir / "tlmgr", os.X_OK) and _complete(texdir):
            year = texdir.name
    return year


def _resolve_mirror(context: StepContext) -> str:
    """One CTAN mirror, for every request of the run.

    mirror.ctan.org redirects each request to a mirror of its choosing, so the
    tarball and its checksum fetched separately can come from two mirrors at
    different points in a sync; on 1 October 2026 they did, and disagreed. The
    redirect is resolved once here and every later request, install-tl's own
    included, goes to that mirror.
    """
    url = fetch.resolve(context, f"{REPOSITORY}/")
    if url is None:
        raise StepFailed(f"Could not resolve a CTAN mirror from {REPOSITORY}")
    return url[:-1] if url.endswith("/") else url


def _sha512(path: Path) -> str:
    digest = hashlib.sha512()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _fetch_installer(context: StepContext, mirror: str) -> tuple[Path, str]:
    """Fetch and unpack install-tl; its directory and its release year.

    Upstream publishes a SHA-512 rather than a SHA-256, so the check is done
    here instead of through download_verified.
    """
    work = context.tmpdir()
    tarball = work / INSTALLER
    checksum = work / f"{INSTALLER}.sha512"
    fetch.download(context, f"{mirror}/{INSTALLER}", tarball)
    fetch.download(context, f"{mirror}/{INSTALLER}.sha512", checksum)
    expected = checksum.read_text(errors="replace").split()
    if not expected or _sha512(tarball) != expected[0]:
        raise StepFailed(f"Checksum mismatch for {INSTALLER} from {mirror}")
    release.unpack(context, tarball, work)
    # The tarball unpacks to install-tl-<date>.
    unpacked = [path for path in sorted(work.glob("install-tl-*")) if path.is_dir()]
    notes = (unpacked[-1] if unpacked else work) / "release-texlive.txt"
    # release-texlive.txt opens with "TeX Live (https://tug.org/texlive) version 2026".
    try:
        words = notes.read_text(errors="replace").split("\n", 1)[0].split()
    except OSError:
        words = []
    if not words or not _YEAR.fullmatch(words[-1]):
        raise StepFailed(f"Could not read the TeX Live year from {notes}")
    return unpacked[-1], words[-1]


def _run_installer(context: StepContext, installer: Path, texdir: Path, mirror: str) -> Path:
    """Install into `texdir` and return its bin directory.

    A per-user install, so tlmgr runs without sudo. instopt_adjustpath links
    every binary into ~/.local/bin, which .zshrc puts ahead of /usr/bin, so the
    year directory never appears on PATH and a new year only relinks:
    install-tl replaces an existing symlink and warns past a regular file.
    install-tl leaves tlmgr on the mirror it installed from (instopt_adjustrepo
    covers only a DVD install), so tlmgr is pointed back at mirror.ctan.org
    afterwards.
    """
    home = context.home
    profile = installer / "dotfiles.profile"
    lines = [
        "selected_scheme scheme-custom",
        f"TEXDIR {texdir}",
        f"TEXMFLOCAL {_root(context)}/texmf-local",
        f"TEXMFSYSVAR {texdir}/texmf-var",
        f"TEXMFSYSCONFIG {texdir}/texmf-config",
        "TEXMFHOME ~/texmf",
        *(f"{collection} 1" for collection in COLLECTIONS),
        "instopt_adjustpath 1",
        "instopt_letter 0",
        f"tlpdbopt_sys_bin {home}/.local/bin",
        f"tlpdbopt_sys_man {home}/.local/share/man",
        f"tlpdbopt_sys_info {home}/.local/share/info",
        "tlpdbopt_install_docfiles 0",
        "tlpdbopt_install_srcfiles 0",
        "tlpdbopt_autobackup 0",
    ]
    profile.write_text("".join(f"{line}\n" for line in lines))
    tools.local_bin(context)
    context.run(
        ["perl", str(installer / "install-tl"), f"--profile={profile}", f"--repository={mirror}"]
    )
    bin_dir = _bin_dir(texdir)
    if bin_dir is None:
        raise StepFailed
    context.run([str(bin_dir / "tlmgr"), "option", "repository", REPOSITORY])
    (texdir / COMPLETE_MARKER).touch()
    return bin_dir


def _remove_stale_links(context: StepContext) -> None:
    """Remove links in ~/.local/bin left dangling by a removed TeX Live year."""
    root = f"{_root(context)}/"
    for link in tools.local_bin(context).iterdir():
        if link.is_symlink() and not link.exists() and os.readlink(link).startswith(root):
            link.unlink()


def _install_macos(context: StepContext) -> None:
    if not brew.cask_installed(context, CASK):
        context.log("Installing MacTeX (no GUI); this is a download of several gigabytes")
        context.run(["brew", "install", "--cask", CASK])
    elif context.upgrade:
        context.log("Upgrading MacTeX")
        context.run(["brew", "upgrade", "--cask", CASK])
    else:
        context.log("MacTeX already installed; skipping")
        return
    tools.require_runs(context, TEXBIN / "latexmk", "-v")
    tools.require_runs(context, TEXBIN / "biber", "--version")


def install_latex(context: StepContext) -> None:
    if context.host.system == "Darwin":
        _install_macos(context)
        return

    root = _root(context)
    installed = _installed_year(root)
    if installed and not context.upgrade:
        context.log(f"TeX Live {installed} already installed; skipping")
        return

    mirror = _resolve_mirror(context)
    installer, year = _fetch_installer(context, mirror)
    if installed and int(year) < int(installed):
        # A mirror lagging a release year behind would otherwise count as a
        # new year, install the older TeX Live and delete the newer one.
        context.log(
            f"TeX Live {installed} is newer than the {year} installer on {mirror}; skipping"
        )
        return
    if installed == year:
        bin_dir = _bin_dir(root / installed)
        if bin_dir is None:
            raise StepFailed
        context.log(f"Upgrading TeX Live {installed} packages")
        tools.retry_once(context, [str(bin_dir / "tlmgr"), "update", "--self", "--all"])
    else:
        # tlmgr cannot cross a release year, so a new year is a fresh install
        # beside the old one, which goes only once the new one runs. Whatever
        # is there already is an interrupted install, since a complete one
        # would have counted as installed above.
        texdir = root / year
        if texdir.is_dir():
            context.log(f"Removing the incomplete TeX Live {year} left by an earlier run")
            shutil.rmtree(texdir)
        context.log(
            f"Installing TeX Live {year} into {root}; this is a download of several gigabytes"
        )
        bin_dir = _run_installer(context, installer, texdir, mirror)

    tools.require_runs(context, bin_dir / "latexmk", "-v")
    tools.require_runs(context, bin_dir / "biber", "--version")
    if installed and installed != year:
        context.log(f"Removing TeX Live {installed}")
        shutil.rmtree(root / installed)
        _remove_stale_links(context)
    tools.note_shadowed(context, "latexmk", tools.local_bin(context) / "latexmk")
    if apt.installed(context, "texlive-base"):
        context.log(
            "Note: the apt TeX Live is still installed, behind this one on PATH."
            " To reclaim its space:"
        )
        context.log("  sudo apt-get purge 'texlive*' latexmk biber && sudo apt-get autoremove")


STEPS = (Step("install_latex", install_latex),)
