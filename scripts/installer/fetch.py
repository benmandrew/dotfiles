"""Downloads, and the checksums that go with them."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

from .runner import StepContext, StepFailed

# Every fetch here goes to a third-party host that rate-limits, and one bad
# minute takes a whole step down; a GitHub codeload 429 is what prompted this.
# curl retries transient HTTP status on its own (408, 429 and the 5xx family,
# honouring Retry-After when the server sends one) with an exponential backoff
# from 1s, so five attempts span about 30s. --retry-connrefused adds the
# connection-level case, which a bare --retry ignores. Deliberately not
# --retry-all-errors: that retries a 404 too, so a release asset renamed
# upstream would burn the full backoff before reporting the obvious.
#
# The TLS floor matters as much for an API call as for a download, since the
# API calls decide which version gets installed.
CURL = (
    "curl",
    "-fsSL",
    "--proto",
    "=https",
    "--tlsv1.2",
    "--retry",
    "5",
    "--retry-connrefused",
    "--retry-max-time",
    "120",
)

_SHA256 = re.compile(r"[0-9a-f]{64}")


def is_sha256(text: str) -> bool:
    return _SHA256.fullmatch(text) is not None


def download(context: StepContext, url: str, dest: Path) -> None:
    """Fetch a URL to a path, failing the step if it cannot be had."""
    if context.call([*CURL, url, "-o", str(dest)]) != 0:
        raise StepFailed(f"Download failed: {url}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest_sha256(manifest: str, asset: str) -> str | None:
    """The hash a checksum manifest gives for `asset`, or None.

    The manifests disagree on layout. Some releases ship one line per asset
    (charmbracelet, kunchenguid and gitleaks call it checksums.txt, Kitware and
    ryanoasis SHA-256.txt), some a file per asset holding the hash and the name
    (BurntSushi, atuinsh, wez, nextest-rs), and mozilla ships the hash on its
    own with no name at all. atuinsh prefixes the name with `*`, BSD's binary
    marker. So the hash is the first field of the line naming the asset,
    falling back to the only field when the manifest names nothing.

    The name is matched whole rather than as a substring of the line, because a
    manifest listing `<asset>.tar.gz` also lists `<asset>.tar.gz.sbom.json`
    beside it, and a substring match would take whichever came first.
    """
    rows = [line.split() for line in manifest.splitlines()]
    rows = [row for row in rows if row]
    expected = ""
    for row in rows:
        name = row[-1]
        if name.startswith("*"):
            name = name[1:]
        if name == asset:
            expected = row[0]
            break
    if not expected:
        expected = next((row[0] for row in rows if len(row) == 1), "")
    expected = expected.lower()
    return expected if is_sha256(expected) else None


def verify_sha256(context: StepContext, file: Path, manifest_url: str, asset: str) -> None:
    """Check a downloaded file against a checksum manifest published beside it.

    What this buys and what it does not: the manifest sits in the same release
    as the asset, so it cannot detect a release the publisher's own account was
    used to rewrite. It does catch a truncated or corrupted download, and an
    asset swapped underneath a pinned tag, which is the failure the pins exist
    to make visible.
    """
    manifest = context.tmpdir() / "manifest"
    try:
        download(context, manifest_url, manifest)
    except StepFailed as failure:
        context.console.err(str(failure))
        raise StepFailed(f"Could not fetch the checksum manifest for {asset}") from None
    expected = manifest_sha256(manifest.read_text(errors="replace"), asset)
    if expected is None:
        raise StepFailed(f"No sha256 for {asset} in {manifest_url}")
    check_sha256(file, expected, asset)


def check_sha256(file: Path, expected: str, asset: str) -> None:
    actual = sha256_file(file)
    if actual != expected:
        raise StepFailed(f"Checksum mismatch for {asset}: expected {expected}, got {actual}")


def download_verified(context: StepContext, url: str, dest: Path, manifest_url: str) -> None:
    """download, then verify. The manifest names the last part of the URL."""
    download(context, url, dest)
    verify_sha256(context, dest, manifest_url, url.rsplit("/", 1)[-1])
