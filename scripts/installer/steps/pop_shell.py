"""Pop Shell, System76's tiling GNOME Shell extension, built from source.

Pop Shell is not on extensions.gnome.org, and Ubuntu 22.04 does not package
it, so the step builds it. Its `master_jammy` branch is the one for GNOME
Shell 40 to 44; `master` has moved to the module format of GNOME 45. The
build is TypeScript, so the step installs a pinned `tsc` from npm into
scratch space rather than onto PATH.

It replaces Forge, which crashed in its layout pass and left windows untiled.
Two tiling extensions fight over every window, so enabling Pop Shell takes
Forge out of enabled-extensions.

It enables the extension through gsettings, not `gnome-extensions enable`: on
Wayland the running shell does not see a new extension until the next login,
so `enable` fails straight after an install, while the gsettings key takes
effect at that login.
"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import stat
from pathlib import Path

from .. import fetch, release, tools
from ..runner import Step, StepContext, StepFailed

NAME = "Pop Shell"
UUID = "pop-shell@system76.com"
REPO = "https://github.com/pop-os/shell"
BRANCH = "master_jammy"
# A commit on BRANCH, which carries no tags; --upgrade takes the branch tip.
COMMIT = "67ef96c36bba6ab7185ecf7ee4984b95f34c2b8a"
TYPESCRIPT_VERSION = "5.4.5"
# Written into the installed extension, since its metadata.json version
# never changes between commits.
COMMIT_FILE = ".commit"
FORGE_UUID = "forge@jmmaranan.com"
SCHEMA = "org.gnome.shell"

_SHELL_MAJOR = re.compile(r"(\d+)\.\d+")
_SHA = re.compile(r"[0-9a-f]{40}")


def _shell_major(context: StepContext) -> int | None:
    text = context.capture(["gnome-shell", "--version"], quiet=True) or ""
    match = _SHELL_MAJOR.search(text)
    return int(match.group(1)) if match else None


def _installed_commit(extension: Path) -> str | None:
    if not (extension / "metadata.json").is_file():
        return None
    try:
        return (extension / COMMIT_FILE).read_text().strip()
    except OSError:
        # Installed by hand, with no record of the commit.
        return ""


def _branch_tip(context: StepContext) -> str:
    out = context.capture(["git", "ls-remote", f"{REPO}.git", f"refs/heads/{BRANCH}"]) or ""
    sha = out.split()[0] if out.split() else ""
    if not _SHA.fullmatch(sha):
        raise StepFailed(f"{NAME}: could not read the tip of {BRANCH} from {REPO}")
    return sha


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
    """Put Pop Shell in enabled-extensions in place of Forge, and out of disabled-extensions.

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
    if FORGE_UUID in enabled:
        enabled = [item for item in enabled if item != FORGE_UUID]
        _write_list(context, "enabled-extensions", enabled)
        context.log("Disabled Forge, which Pop Shell replaces")
    if UUID in enabled:
        return
    _write_list(context, "enabled-extensions", [*enabled, UUID])
    after = _read_list(context, "enabled-extensions")
    if after is None or UUID not in after:
        raise StepFailed(f"{UUID} is not in {SCHEMA} enabled-extensions after setting it")
    context.log(f"Enabled {NAME}; it starts at the next login")


def _build(context: StepContext, commit: str, extension: Path) -> None:
    tools.require_command(context, "npm")
    tools.require_command(context, "make")
    tools.require_command(context, "glib-compile-schemas")
    # GitHub publishes no digest for an archive of a commit, so the download
    # is unverified beyond TLS. The commit pins the content.
    archive = context.tmpdir() / f"shell-{commit}.tar.gz"
    fetch.download(context, f"{REPO}/archive/{commit}.tar.gz", archive)
    source = release.unpack(context, archive) / f"shell-{commit}"
    if not (source / "Makefile").is_file():
        raise StepFailed(f"{NAME}: no Makefile in the archive of {commit}")

    typescript = context.tmpdir()
    context.run(
        [
            "npm",
            "install",
            "--no-audit",
            "--no-fund",
            "--prefix",
            str(typescript),
            f"typescript@{TYPESCRIPT_VERSION}",
        ]
    )
    tsc_bin = typescript / "node_modules" / ".bin"
    env = {**context.env, "PATH": f"{tsc_bin}{os.pathsep}{context.env.get('PATH', '')}"}
    # `compile` only: `local-install` also rebinds GNOME's keys, which
    # desktop_keys owns, and logs the session out.
    context.run(["make", "compile"], env=env, cwd=source)
    built = source / "_build"
    if not (built / "extension.js").is_file():
        raise StepFailed(f"{NAME}: the build left no extension.js in {built}")

    if extension.exists():
        shutil.rmtree(extension)
    extension.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(built, extension)
    (extension / COMMIT_FILE).write_text(f"{commit}\n")
    # The proof it installed: no binary to run, so read back what gnome-shell
    # will load.
    try:
        uuid = json.loads((extension / "metadata.json").read_text())["uuid"]
    except (OSError, ValueError, KeyError, TypeError):
        uuid = None
    if uuid != UUID or _installed_commit(extension) != commit:
        raise StepFailed(f"{NAME} {commit[:7]} is not in {extension} after installing")


def install(context: StepContext) -> None:
    if context.host.system != "Linux":
        return
    if context.which("gnome-shell") is None or context.which("gnome-extensions") is None:
        context.log(f"{NAME}: no GNOME Shell; skipping")
        return

    extension = context.home / ".local" / "share" / "gnome-shell" / "extensions" / UUID
    installed = _installed_commit(extension)
    if installed is not None and not context.upgrade:
        context.log(f"{NAME} already installed; skipping")
        _enable(context)
        return

    major = _shell_major(context)
    if major is None:
        raise StepFailed("Could not read the GNOME Shell version from `gnome-shell --version`")
    if not 40 <= major <= 44:
        raise StepFailed(f"{NAME}'s {BRANCH} branch supports GNOME Shell 40 to 44, not {major}")

    commit = _branch_tip(context) if context.upgrade else COMMIT
    if installed == commit:
        context.log(f"{NAME} {commit[:7]} already at latest; skipping")
        _enable(context)
        return
    if installed is None:
        context.log(f"Installing {NAME} {commit[:7]}")
    else:
        context.log(f"Upgrading {NAME} to {commit[:7]}")
    _build(context, commit, extension)
    _enable(context)


STEPS = (Step("install_pop_shell_extension", install),)
