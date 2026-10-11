"""Obsidian, and obsync with the schedule that runs it against the vault."""

from __future__ import annotations

import json
import os
import re
import shutil
import time
from pathlib import Path

from .. import apt, brew, fetch, release, tools
from ..runner import Step, StepContext, StepFailed

REPOSITORY = "obsidianmd/obsidian-releases"
DESKTOP_RELEASES = f"https://raw.githubusercontent.com/{REPOSITORY}/master/desktop-releases.json"
_LATEST_VERSION = re.compile(r'"latestVersion": "([^"]*)"')

APP = Path("/Applications/Obsidian.app")
PLIST_BUDDY = "/usr/libexec/PlistBuddy"


def desktop_version(context: StepContext) -> str:
    """The newest Obsidian version that has desktop builds.

    The repo's latest release is not necessarily a desktop one. Obsidian ships
    Android from the same repo on its own cadence, and v1.13.8 (21 August 2026)
    carried a single Obsidian-1.13.8.apk with no .deb or tarball beside it, so
    the latest tag named a version whose desktop assets do not exist and the
    download 404ed. desktop-releases.json on the repo's master branch is what
    the app's own updater reads, so its latestVersion names the newest version
    that has desktop builds; there that was 1.13.7. The beta block repeats the
    same key further down, which taking the first match skips.
    """
    listing = context.tmpdir() / "desktop-releases.json"
    fetch.download(context, DESKTOP_RELEASES, listing)
    found = _LATEST_VERSION.search(listing.read_text(errors="replace"))
    if found is None or not found.group(1):
        raise StepFailed(
            "Obsidian: no latestVersion in desktop-releases.json; upstream format changed"
        )
    return found.group(1)


def _macos_cli_note(context: StepContext) -> None:
    # The cask has already linked /opt/homebrew/bin/obsidian, so the GUI toggle
    # the hint below describes is not needed here. The command still cannot do
    # anything with the app closed (it exits with "unable to find Obsidian"),
    # so say that much rather than nothing.
    context.log("Obsidian CLI linked as 'obsidian'; it needs the app running to do anything")


def _cli_hint(context: StepContext) -> None:
    context.log("Obsidian CLI needs a one-time manual step: open Obsidian, then")
    context.log("  Settings -> General -> enable 'Command line interface'")
    context.log("  and follow the prompt to register it (installs the 'obsidian' command)")


def _install_macos(context: StepContext) -> None:
    if brew.cask_installed(context, "obsidian"):
        if not context.upgrade:
            context.log("Obsidian already installed; skipping")
        else:
            # The cask sets `auto_updates true`, so this is a no-op unless
            # --greedy is passed. That is deliberate: Obsidian replaces its own
            # bundle, and a greedy upgrade only races the app's own updater.
            context.log("Upgrading Obsidian")
            context.call(["brew", "upgrade", "--cask", "obsidian"])
        _macos_cli_note(context)
        return

    # `brew list --cask` only sees what brew put there, so an Obsidian
    # installed by hand before these scripts existed reads as absent. Left to
    # fall through, the install below fails on the existing bundle, and every
    # later run repeats it.
    if APP.is_dir():
        plist = str(APP / "Contents/Info.plist")
        installed = context.capture(
            [PLIST_BUDDY, "-c", "Print :CFBundleShortVersionString", plist], quiet=True
        )
        # --adopt takes over an existing artifact only when it is identical to
        # the cask's, so it is worth trying at a matching version and a wasted
        # download at any other. Compare first rather than let brew pull ~150MB
        # to discover the same thing.
        if installed and installed == _cask_version(context):
            context.log(f"Adopting the existing Obsidian {installed} into brew")
            if context.call(["brew", "install", "--cask", "--adopt", "obsidian"]) == 0:
                _macos_cli_note(context)
                return
        context.log(
            f"Obsidian {installed or '(version unknown)'} at /Applications was not installed"
            " by brew; leaving it alone"
        )
        context.log(
            "  to hand it over: rm -rf /Applications/Obsidian.app && brew install --cask obsidian"
        )
        _cli_hint(context)
        return

    context.log("Installing Obsidian")
    context.run(["brew", "install", "--cask", "obsidian"])
    _macos_cli_note(context)


def _cask_version(context: StepContext) -> str:
    info = context.capture(["brew", "info", "--cask", "--json=v2", "obsidian"], quiet=True)
    try:
        version = json.loads(info or "")["casks"][0]["version"]
    except (ValueError, LookupError, TypeError):
        return ""
    return version if isinstance(version, str) else ""


def _wanted(context: StepContext, current: str | None, version: str) -> bool:
    """Say what happens to an install at `current`, and whether to go on."""
    if current is None:
        context.log(f"Installing Obsidian {version}")
        return True
    if not context.upgrade:
        context.log(f"Obsidian {current} already installed; skipping")
    elif current == version:
        context.log(f"Obsidian {current} already at latest; skipping")
    else:
        context.log(f"Upgrading Obsidian to {version}")
        return True
    _cli_hint(context)
    return False


def _install_deb(context: StepContext, version: str) -> bool:
    current = None
    if apt.installed(context, "obsidian"):
        query = ["dpkg-query", "-W", "-f=${Version}", "obsidian"]
        current = context.capture(query, quiet=True) or ""
    if not _wanted(context, current, version):
        return False
    deb = release.download(context, REPOSITORY, f"v{version}", f"obsidian_{version}_amd64.deb")
    apt.install(context, deb)
    return True


def _install_tarball(context: StepContext, version: str) -> bool:
    # Upstream publishes no arm64 .deb, only a tarball, so unpack it under
    # ~/.local/share and link the launcher onto PATH by hand.
    dest = context.home / ".local/share/obsidian"
    version_file = dest / ".version"
    current = version_file.read_text().rstrip("\n") if version_file.is_file() else None
    if not _wanted(context, current, version):
        return False
    name = f"obsidian-{version}-arm64"
    archive = release.download(context, REPOSITORY, f"v{version}", f"{name}.tar.gz")
    unpacked = release.unpack(context, archive, archive.parent) / name
    if not os.access(unpacked / "obsidian", os.X_OK):
        raise StepFailed(f"Obsidian: no 'obsidian' binary at {unpacked}; upstream layout changed")
    shutil.rmtree(dest, ignore_errors=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(unpacked), dest)
    version_file.write_text(f"{version}\n")
    # Electron refuses to start if its setuid sandbox helper is not root-owned
    # and mode 4755. The .deb arranges that; an unpacked tarball cannot, so do
    # it here. Best-effort: failing only costs the sandbox, and saying so beats
    # a bare "app won't launch".
    sandbox = dest / "chrome-sandbox"
    if sandbox.exists() and not (
        tools.sudo(context, ["chown", "root:root", sandbox], check=False) == 0
        and tools.sudo(context, ["chmod", "4755", sandbox], check=False) == 0
    ):
        context.log(
            "Obsidian: could not setuid chrome-sandbox; skipping"
            " (launch with --no-sandbox if the app refuses to start)"
        )
    launcher = tools.local_bin(context) / "obsidian-app"
    launcher.unlink(missing_ok=True)
    launcher.symlink_to(dest / "obsidian")
    return True


def install_obsidian(context: StepContext) -> None:
    """The desktop app, which carries the `obsidian` command inside it.

    The thing advertised at obsidian.md/cli is not a separately installable
    binary: it ships inside the desktop app. On macOS the cask now links it
    onto PATH itself (a `binary` stanza pointing /opt/homebrew/bin/obsidian at
    Contents/MacOS/obsidian-cli, added upstream in March 2026), so a cask
    install needs no further step. Everywhere else it is registered by a GUI
    toggle (Settings -> General -> Command line interface), which copies the
    binary to ~/.local/bin/obsidian on Linux or symlinks
    /usr/local/bin/obsidian on macOS. It also needs the app to be running; the
    first command launches it. So the most a script can do on those paths is
    install the app and point at the remaining manual step, which is also why
    this is optional rather than installed everywhere.
    """
    if context.host.system == "Darwin":
        _install_macos(context)
        return

    # The CLI drives a running GUI app, so an Obsidian install on a machine
    # with no display buys nothing.
    if not (context.env.get("DISPLAY") or context.env.get("WAYLAND_DISPLAY")):
        context.log("Obsidian: no display session detected; skipping on headless Linux")
        return

    version = desktop_version(context)
    machine = context.host.machine
    if machine in ("x86_64", "amd64"):
        installed = _install_deb(context, version)
    elif machine in ("aarch64", "arm64"):
        installed = _install_tarball(context, version)
    else:
        context.log(f"Unsupported arch {machine} for Obsidian install; skipping")
        return
    if installed:
        _cli_hint(context)


# Sharing Obsidian config across machines is really this clone plus its
# schedule: the vault is a git repository and `.obsidian/` lives inside it, so
# settings, hotkeys, appearance, snippets and community-plugin code all ride
# along with the notes. Only `.obsidian/workspace.json` is gitignored. Nothing
# here belongs in chezmoi: obsync commits whatever Obsidian writes every 15
# minutes, so a chezmoi-managed copy would fight it for the same files.
#
# Three pieces have to line up and none is discoverable from the app: the
# obsync checkout, a vault clone whose remote is named `personal`, and the
# periodic invocation. install_obsync owns the first and the third. The vault
# clone stays manual, because its URL is a private self-hosted forge and this
# repository is public; see scripts/CLAUDE.md for the reasoning.
OBSYNC_REPO = "https://github.com/benmandrew/obsync.git"
VAULT_REMOTE = "personal"
INTERVAL_MIN = 15
CRON_MARKER = "# obsync: managed by dotfiles install"
LAUNCHD_LABEL = "com.benmandrew.obsync"
# How long to leave launchd between two tries at loading the agent.
BOOTSTRAP_WAIT = 1.0
BOOTSTRAP_TRIES = 5


def _obsync_dir(context: StepContext) -> Path:
    return context.home / "projects/obsync"


def _vault_dir(context: StepContext) -> Path:
    return context.home / "projects/obsidian-vault"


def _obsync_log(context: StepContext) -> Path:
    return context.home / ".local/share/obsync/cron.log"


def install_obsync(context: StepContext) -> None:
    # obsync itself is public, so it clones over https and needs no key.
    directory = _obsync_dir(context)
    if not (directory / ".git").is_dir():
        context.log("Cloning obsync")
        directory.parent.mkdir(parents=True, exist_ok=True)
        context.run(["git", "clone", OBSYNC_REPO, str(directory)])
    elif context.upgrade:
        context.log("Upgrading obsync")
        tools.ensure_user_owns(context, directory)
        tools.safe_git(context, directory, "fetch", "origin")
        tools.safe_git(context, directory, "reset", "--hard", "origin/main")
    else:
        context.log("obsync already cloned; skipping")

    # No vault means nothing to schedule against, and obsync.sh exits 1 on a
    # missing directory, which the cron job would then alert about every 15
    # minutes.
    if not _vault_is_ready(context):
        return
    _obsync_log(context).parent.mkdir(parents=True, exist_ok=True)
    if context.host.system == "Darwin":
        _schedule_launchd(context)
    else:
        _schedule_cron(context)


def _vault_is_ready(context: StepContext) -> bool:
    """Whether the vault is cloned and has the remote obsync pushes to.

    Both conditions gate the schedule, since obsync fails on either and a cron
    job would report that failure every 15 minutes. Neither is repairable from
    here: cloning the vault and naming its remote both need the forge URL,
    which is deliberately not in this repository. So this detects and explains.

    The remote name is the one worth explaining. obsync.sh hardcodes
    PRIMARY_REMOTE=personal, so a vault cloned the usual way, which gets
    `origin`, fails at `rev-parse personal/main` on every run, and the EXIT
    trap reports it as a bare exit status with no indication of the cause.
    """
    vault = _vault_dir(context)
    if not (vault / ".git").is_dir():
        context.log(f"obsync: no vault at {vault}; skipping schedule")
        context.log(f"  clone it there first, naming the remote '{VAULT_REMOTE}':")
        context.log(f"    git clone -o {VAULT_REMOTE} <vault-url> {vault}")
        return False
    git = ["git", "-c", f"safe.directory={vault}", "-C", str(vault)]
    if not context.capture([*git, "remote", "get-url", VAULT_REMOTE], quiet=True):
        context.log(f"obsync: vault has no '{VAULT_REMOTE}' remote; skipping schedule")
        context.log(f"  git -C {vault} remote add {VAULT_REMOTE} <vault-url>")
        return False
    return True


def _crontab(context: StepContext) -> str:
    return context.capture(["crontab", "-l"], quiet=True) or ""


def _set_crontab(context: StepContext, text: str) -> None:
    if context.feed(["crontab", "-"], f"{text}\n") != 0:
        raise StepFailed


def _without_obsync(crontab: str) -> str:
    """A crontab with every obsync line taken out.

    Matching on obsync.sh as well as the marker catches hand-written entries
    that predate it. Everything else is passed through.
    """
    kept = (
        line for line in crontab.split("\n") if CRON_MARKER not in line and "obsync.sh" not in line
    )
    return "\n".join(kept).rstrip("\n")


def _remove_cron(context: StepContext) -> None:
    """Take the obsync entry out of the crontab, if it has one.

    Called from the launchd path, so a Mac that predates the LaunchAgent does
    not keep running the crontab entry beside it. obsync.sh has no lock file,
    and launchd's phase resets on every reboot, so the two schedules can land
    together mid-rebase.
    """
    if context.which("crontab") is None:
        return
    existing = _crontab(context)
    kept = _without_obsync(existing)
    if kept == existing:
        return
    context.log("Removing obsync crontab entry")
    _set_crontab(context, kept)


def _schedule_cron(context: StepContext) -> None:
    if context.which("crontab") is None:
        context.log("obsync: no crontab command; skipping schedule")
        return

    # The redirect merges stderr into the log. Without it obsync's failure
    # output goes to cron's local mail, which nothing on these machines reads.
    line = (
        f"*/{INTERVAL_MIN} * * * * cd {_obsync_dir(context)} && /bin/bash obsync.sh"
        f" {_vault_dir(context)} >> {_obsync_log(context)} 2>&1"
    )
    existing = _crontab(context)
    if line in existing:
        context.log("obsync cron entry already installed; skipping")
        return

    # Drop any earlier entry before appending, so re-running does not stack up
    # duplicate schedules.
    kept = _without_obsync(existing)
    payload = f"{CRON_MARKER}\n{line}"
    if kept.strip():
        payload = f"{kept}\n{payload}"
    context.log(f"Installing obsync cron entry (every {INTERVAL_MIN} minutes)")
    _set_crontab(context, payload)


def _launch_agent(context: StepContext) -> str:
    log = _obsync_log(context)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>{_obsync_dir(context)}/obsync.sh</string>
        <string>{_vault_dir(context)}</string>
    </array>
    <key>WorkingDirectory</key><string>{_obsync_dir(context)}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key><integer>{INTERVAL_MIN * 60}</integer>
    <key>StandardOutPath</key><string>{log}</string>
    <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>"""


def _schedule_launchd(context: StepContext) -> None:
    """Run obsync from a LaunchAgent.

    macOS still has cron, but it runs under a sandbox that needs Full Disk
    Access granted to /usr/sbin/cron by hand, and inherits a PATH with no
    Homebrew on it, so git is absent. A LaunchAgent avoids both.
    """
    plist = context.home / f"Library/LaunchAgents/{LAUNCHD_LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    service = f"{domain}/{LAUNCHD_LABEL}"
    desired = _launch_agent(context)
    plist.parent.mkdir(parents=True, exist_ok=True)
    unchanged = plist.is_file() and plist.read_text().rstrip("\n") == desired
    if unchanged and context.succeeds(["launchctl", "print", service]):
        context.log("obsync LaunchAgent already loaded and unchanged; skipping")
        _remove_cron(context)
        return
    context.log(f"Installing obsync LaunchAgent (every {INTERVAL_MIN} minutes)")
    plist.write_text(f"{desired}\n")

    # bootout first so a changed plist is picked up; it fails when nothing is
    # loaded, which is the normal first-install case. launchd unloads
    # asynchronously, and a bootstrap straight after fails with I/O error 5
    # until it has, so bootstrap is retried for a few seconds.
    context.succeeds(["launchctl", "bootout", service])
    for attempt in range(1, BOOTSTRAP_TRIES + 1):
        if context.succeeds(["launchctl", "bootstrap", domain, str(plist)]):
            break
        if attempt == BOOTSTRAP_TRIES:
            raise StepFailed(
                f"launchctl bootstrap of {plist} still failing after {attempt} attempts"
            )
        time.sleep(BOOTSTRAP_WAIT)

    # After the agent is loaded, not before: a machine whose bootstrap failed
    # keeps the crontab entry and stays scheduled by it.
    _remove_cron(context)


def install_obsidian_stack(context: StepContext) -> None:
    """Obsidian, then obsync, under the one `obsidian` opt-in.

    install_obsidian returns early on several paths (already installed,
    headless, unsupported arch), so the two are sequenced here rather than
    chained inside it, and a failure in one still lets the other run.
    """
    failed = False
    for half in (install_obsidian, install_obsync):
        try:
            half(context)
        except StepFailed as failure:
            if str(failure):
                context.console.err(str(failure))
            failed = True
        except OSError as failure:
            # A file the first half could not move or write. Caught here, or
            # it would end the step before obsync had its turn.
            context.console.err(str(failure))
            failed = True
    if failed:
        raise StepFailed


STEPS = (Step("install_obsidian_stack", install_obsidian_stack),)
