"""GitHub's API: the newest release of a repository, and an asset's digest."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from . import fetch
from .runner import StepContext, StepFailed

API = "https://api.github.com/repos"


def api_token(context: StepContext) -> str:
    """The token for API calls: GITHUB_TOKEN, else the one gh holds, else none.

    Anonymous calls share a limit of 60 an hour per address, which `make pins`
    alone spends in two runs; gh's token lifts that to 5000 on any machine
    where `gh auth login` has been run. `gh auth token` fails when gh is not
    logged in, which leaves the call anonymous.
    """
    token = context.env.get("GITHUB_TOKEN", "")
    if token:
        return token
    if context.which("gh") is None:
        return ""
    return (context.capture(["gh", "auth", "token"], quiet=True) or "").strip()


def failure_reason(headers: str) -> str:
    """Why an API call failed, from the response headers curl dumped.

    GitHub answers an exhausted limit with 403 (or 429) and
    x-ratelimit-remaining: 0, and curl's -f reduces that to "returned error:
    403", which reads like a permissions fault.
    """
    status = ""
    fields: dict[str, str] = {}
    for line in headers.splitlines():
        if line.upper().startswith("HTTP/"):
            words = line.split()
            status = words[1] if len(words) > 1 else ""
            continue
        name, separator, value = line.partition(":")
        if separator:
            fields[name.strip().lower()] = value.strip()
    reset = fields.get("x-ratelimit-reset", "")
    if fields.get("x-ratelimit-remaining") == "0" and reset.isdigit():
        when = time.strftime("%H:%M %Z", time.localtime(int(reset)))
        return f"rate limit exhausted until {when}; set GITHUB_TOKEN or run gh auth login"
    if status:
        return f"HTTP {status}"
    return "no response"


def _get(context: StepContext, path: str, what: str) -> Any:
    scratch = context.tmpdir()
    headers = scratch / "headers"
    body = scratch / "body"
    argv = list(fetch.CURL)
    token = api_token(context)
    if token:
        argv += ["-H", f"Authorization: Bearer {token}"]
    argv += [f"{API}/{path}", "-D", str(headers), "-o", str(body)]
    if context.call(argv) != 0:
        reason = failure_reason(_read(headers))
        raise StepFailed(f"GitHub API request failed for {what} ({reason})")
    try:
        return json.loads(_read(body))
    except ValueError:
        return None


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def latest_tag(context: StepContext, repo: str) -> str:
    """The tag of a repository's newest release.

    `owner/repo:prefix` takes the newest release whose tag starts with the
    prefix, for a monorepo whose releases/latest may be another crate's.

    A missing tag fails here rather than at each call site: a rate-limited or
    unreachable API used to return an empty tag, which the callers pasted into
    an asset URL and downloaded a 404 page with.
    """
    name, _, prefix = repo.partition(":")
    endpoint = "releases?per_page=50" if prefix else "releases/latest"
    found = _get(context, f"{name}/{endpoint}", name)
    # The list endpoint is newest first, so the first match is the latest.
    releases = found if isinstance(found, list) else [found]
    for release in releases:
        tag = release.get("tag_name") if isinstance(release, dict) else None
        if isinstance(tag, str) and tag and tag.startswith(prefix):
            return tag
    raise StepFailed(f"No release tag for {name} in the GitHub API response")


def asset_sha256(context: StepContext, repo: str, tag: str, asset: str) -> str:
    """The SHA-256 GitHub records for a release asset.

    For releases that publish no checksum manifest of their own. GitHub has
    computed one for every asset uploaded since June 2025 and serves it as the
    asset's `digest` in the release's API response. It is weaker than a
    manifest the project signs off on in one way only, being GitHub's record
    rather than upstream's, and it costs an API call against the rate limit.
    """
    release = _get(context, f"{repo}/releases/tags/{tag}", f"{repo} {tag}")
    assets = release.get("assets") if isinstance(release, dict) else None
    for entry in assets if isinstance(assets, list) else []:
        if not isinstance(entry, dict) or entry.get("name") != asset:
            continue
        algorithm, _, digest = str(entry.get("digest") or "").partition(":")
        if algorithm == "sha256" and fetch.is_sha256(digest):
            return digest
    raise StepFailed(f"No sha256 digest for {asset} in the {repo} {tag} release")


def download_verified(context: StepContext, repo: str, tag: str, asset: str, dest: Path) -> None:
    """Download a release asset and check it against the digest GitHub records."""
    fetch.download(context, f"https://github.com/{repo}/releases/download/{tag}/{asset}", dest)
    fetch.check_sha256(dest, asset_sha256(context, repo, tag, asset), asset)
