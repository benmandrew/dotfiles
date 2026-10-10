"""Fetching a GitHub release asset and placing what it holds."""

from __future__ import annotations

import os
from pathlib import Path

from . import fetch
from .runner import StepContext


def asset_url(repo: str, tag: str, asset: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{asset}"


def download(
    context: StepContext, repo: str, tag: str, asset: str, manifest: str | None = None
) -> Path:
    """Download a release asset into scratch space and return its path.

    `manifest` names a checksum manifest in the same release. Leave it out only
    for a release that publishes none.
    """
    dest = context.tmpdir() / asset
    if manifest is None:
        fetch.download(context, asset_url(repo, tag, asset), dest)
    else:
        fetch.download_verified(
            context, asset_url(repo, tag, asset), dest, asset_url(repo, tag, manifest)
        )
    return dest


def unpack(context: StepContext, archive: Path, into: Path | None = None) -> Path:
    """Unpack an archive and return the directory it went into.

    `tar -xf` and never `-xzf`: tar works the compression out for itself, so a
    release that moves to .tar.xz or .tar.zst needs no change here.
    """
    directory = context.tmpdir() if into is None else into
    context.run(["tar", "-C", str(directory), "-xf", str(archive)])
    return directory


def find_file(root: Path, name: str) -> Path | None:
    """A regular file called `name` somewhere under `root`.

    Found by name, since the tarballs disagree on whether the binary sits at
    the root or inside a versioned directory. Regular files only, which keeps
    it off the completion and man directories several of them ship alongside.
    """
    for directory, subdirectories, files in os.walk(root):
        subdirectories.sort()
        candidate = Path(directory) / name
        if name in files and candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None
