"""Forge, the tiling GNOME Shell extension, from extensions.gnome.org.

Forge publishes a different release for each GNOME Shell version, so the step
asks extensions.gnome.org which release fits the installed shell rather than
pinning one. It enables the extension through gsettings, not
`gnome-extensions enable`: on Wayland the running shell does not see a new
extension until the next login, so `enable` fails straight after an install,
while the gsettings key takes effect at that login.
"""

from __future__ import annotations

import ast
import json
import os
import re
import stat
from pathlib import Path

from .. import fetch
from ..runner import Step, StepContext, StepFailed

NAME = "Forge"
UUID = "forge@jmmaranan.com"
SITE = "https://extensions.gnome.org"
INFO = f"{SITE}/extension-info/?uuid={UUID}&shell_version={{shell}}"
SCHEMA = "org.gnome.shell"

_SHELL_VERSION = re.compile(r"(\d+)\.(\d+)")


def _shell_version(context: StepContext) -> str | None:
    """The version extensions.gnome.org files releases under: 42 for 42.9.

    Before GNOME 40 the minor number was part of it, as in 3.38.
    """
    match = _SHELL_VERSION.search(context.capture(["gnome-shell", "--version"], quiet=True) or "")
    if match is None:
        return None
    major, minor = match.groups()
    return major if int(major) >= 40 else f"{major}.{minor}"


def _installed_version(metadata: Path) -> int | None:
    try:
        version = json.loads(metadata.read_text())["version"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return version if isinstance(version, int) else None


def _offered(context: StepContext, shell: str) -> tuple[int, str]:
    """The version extensions.gnome.org offers for this shell, and its zip's URL."""
    info = context.tmpdir() / "extension-info.json"
    url = INFO.format(shell=shell)
    try:
        fetch.download(context, url, info)
    except StepFailed:
        raise StepFailed(
            f"No {NAME} release for GNOME Shell {shell} from {url}"
            " (none published, or the site is unreachable)"
        ) from None
    try:
        data = json.loads(info.read_text())
        version, path = data["version"], data["download_url"]
    except (ValueError, KeyError, TypeError):
        raise StepFailed(f"{NAME}: unexpected reply from {url}; upstream format changed") from None
    # Relative to the site, and held to it, so the reply cannot send the
    # download to another host.
    if not isinstance(version, int) or not str(path).startswith("/download-extension/"):
        raise StepFailed(f"{NAME}: unexpected reply from {url}; upstream format changed")
    return version, f"{SITE}{path}"


def _has_session_bus(context: StepContext) -> bool:
    """Whether gsettings can reach dconf, so a write would persist.

    Without a bus gsettings falls back to an in-memory backend and drops the
    write without failing.
    """
    if context.env.get("DBUS_SESSION_BUS_ADDRESS"):
        return True
    runtime = context.env.get("XDG_RUNTIME_DIR")
    if not runtime:
        return False
    try:
        return stat.S_ISSOCK(os.stat(os.path.join(runtime, "bus")).st_mode)
    except OSError:
        return False


def _read_list(context: StepContext, key: str) -> list[str] | None:
    """A string-list key, from gsettings' GVariant text: `@as []` or `['a', 'b']`."""
    text = context.capture(["gsettings", "get", SCHEMA, key], quiet=True)
    if text is None:
        return None
    text = text.strip()
    if text.startswith("@as "):
        text = text[len("@as ") :]
    try:
        value = ast.literal_eval(text)
    except (ValueError, SyntaxError):
        return None
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        return None
    return value


def _write_list(context: StepContext, key: str, value: list[str]) -> None:
    text = "[" + ", ".join(f"'{item}'" for item in value) + "]"
    context.run(["gsettings", "set", SCHEMA, key, text])


def _enable(context: StepContext) -> None:
    """Add Forge to enabled-extensions, keeping what is there, and out of disabled-extensions.

    disabled-extensions wins over enabled-extensions, which is why
    `gnome-extensions enable` clears both.
    """
    if context.which("gsettings") is None:
        context.log(f"{NAME}: no gsettings; installed but not enabled")
        return
    if not _has_session_bus(context):
        context.log(
            f"{NAME}: no session bus; installed but not enabled."
            f" Run `gnome-extensions enable {UUID}` from a desktop session"
        )
        return
    enabled = _read_list(context, "enabled-extensions")
    disabled = _read_list(context, "disabled-extensions")
    if enabled is None or disabled is None:
        raise StepFailed(f"Could not read {SCHEMA} enabled-extensions with gsettings")
    if UUID in disabled:
        _write_list(context, "disabled-extensions", [item for item in disabled if item != UUID])
    if UUID in enabled:
        return
    _write_list(context, "enabled-extensions", [*enabled, UUID])
    after = _read_list(context, "enabled-extensions")
    if after is None or UUID not in after:
        raise StepFailed(f"{UUID} is not in {SCHEMA} enabled-extensions after setting it")
    context.log(f"Enabled {NAME}; it starts at the next login")


def install(context: StepContext) -> None:
    if context.host.system != "Linux":
        return
    if context.which("gnome-shell") is None or context.which("gnome-extensions") is None:
        context.log(f"{NAME}: no GNOME Shell; skipping")
        return

    metadata = (
        context.home / ".local" / "share" / "gnome-shell" / "extensions" / UUID / "metadata.json"
    )
    installed = _installed_version(metadata)
    if installed is not None and not context.upgrade:
        context.log(f"{NAME} already installed; skipping")
        _enable(context)
        return

    shell = _shell_version(context)
    if shell is None:
        raise StepFailed("Could not read the GNOME Shell version from `gnome-shell --version`")
    version, url = _offered(context, shell)
    if installed == version:
        context.log(f"{NAME} {version} already at latest; skipping")
        _enable(context)
        return

    if installed is None:
        context.log(f"Installing {NAME} {version}")
    else:
        context.log(f"Upgrading {NAME} to {version}")
    archive = context.tmpdir() / f"{UUID}.shell-extension.zip"
    # extensions.gnome.org publishes no digest for an extension's zip, so the
    # download is unverified beyond TLS.
    fetch.download(context, url, archive)
    context.run(["gnome-extensions", "install", "--force", str(archive)])
    # The proof it installed: no binary to run, so read back what gnome-shell
    # will load.
    if _installed_version(metadata) != version:
        raise StepFailed(f"{NAME} {version} is not in {metadata.parent} after installing")
    _enable(context)


STEPS = (Step("install_forge_extension", install),)
