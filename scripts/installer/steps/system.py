"""What the machine itself needs: Homebrew, the login shell, perf, and two
files under /etc on Linux."""

from __future__ import annotations

import os
import pwd
from pathlib import Path

from .. import shell, tools
from ..runner import Step, StepContext, StepFailed

HOMEBREW_URL = "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
BREW = Path("/opt/homebrew/bin/brew")

# The system zsh, in the order tried.
ZSH_CANDIDATES = (Path("/usr/bin/zsh"), Path("/bin/zsh"))
SHELLS = Path("/etc/shells")
PASSWD = Path("/etc/passwd")

INOTIFY_CONF = Path("/etc/sysctl.d/60-inotify-watches.conf")
INOTIFY_LIMITS = "fs.inotify.max_user_watches = 524288\nfs.inotify.max_user_instances = 512"
VSCODE_ORIGIN_CONF = Path("/etc/apt/apt.conf.d/51unattended-upgrades-vscode")
VSCODE_ORIGIN = 'Unattended-Upgrade::Origins-Pattern { "origin=code stable,archive=stable"; };'


def install_homebrew(context: StepContext) -> None:
    if context.which("brew") is not None:
        context.log("Homebrew already installed")
        return
    context.log("Installing Homebrew")
    tools.run_downloaded(context, HOMEBREW_URL, ["/bin/bash"])
    if not os.access(BREW, os.X_OK):
        return
    # HOMEBREW_PREFIX, PATH and the rest, for every step that follows. Named
    # as bash, since brew otherwise picks a syntax from its parent process.
    shellenv = context.capture([str(BREW), "shellenv", "bash"])
    if shellenv is None:
        raise StepFailed
    script = context.tmpdir() / "shellenv.sh"
    script.write_text(f"{shellenv}\n")
    shell.source(context, script)


def _lines(path: Path) -> list[str]:
    try:
        return path.read_text(errors="replace").splitlines()
    except OSError:
        return []


def _contents(path: Path) -> str:
    """A file's text without its trailing newlines, or "" where there is none."""
    try:
        return path.read_text(errors="replace").rstrip("\n")
    except OSError:
        return ""


def login_shell(context: StepContext, user: str) -> str:
    """The login shell the account database records, or "" if it will not say.

    $SHELL is no substitute: it comes from the session that started the
    install, and stays stale after chsh until the next login.
    """
    if context.host.system == "Darwin":
        entry = context.capture(["dscl", ".", "-read", f"/Users/{user}", "UserShell"], quiet=True)
        return (entry or "").removeprefix("UserShell: ")
    entry = context.capture(["getent", "passwd", user])
    return (entry or "").rpartition(":")[2]


def install_login_shell(context: StepContext) -> None:
    """Make the system zsh the login shell.

    Any zsh already set and listed in /etc/shells is left alone, so a Homebrew
    or nix zsh chosen by hand survives. The system one is preferred over
    whatever zsh is first on PATH, since a login shell under ~/.nix-profile or
    /opt/homebrew breaks when that tree is upgraded or removed.
    """
    user = pwd.getpwuid(os.geteuid()).pw_name
    current = login_shell(context, user)
    if Path(current).name == "zsh" and os.access(current, os.X_OK) and current in _lines(SHELLS):
        context.log(f"Login shell is already {current}; skipping")
        return
    target = next(
        (
            str(candidate)
            for candidate in ZSH_CANDIDATES
            if os.access(candidate, os.X_OK) and context.succeeds([str(candidate), "-fc", "exit 0"])
        ),
        None,
    )
    if target is None:
        raise StepFailed("No working zsh at /usr/bin/zsh or /bin/zsh")
    # chsh edits /etc/passwd alone, so an account held in LDAP or SSSD has to
    # have its shell changed by whoever runs the directory.
    if context.host.system != "Darwin" and not any(
        line.startswith(f"{user}:") for line in _lines(PASSWD)
    ):
        context.log(f"{user} is not in /etc/passwd, so chsh cannot change its shell; skipping")
        return
    # chsh refuses a shell missing from /etc/shells.
    if target not in _lines(SHELLS):
        tools.sudo_write(context, SHELLS, f"{target}\n", append=True)
    context.log(f"Changing login shell from {current or 'unknown'} to {target}")
    tools.sudo(context, ["chsh", "-s", target, user])
    current = login_shell(context, user)
    if current != target:
        raise StepFailed(f"chsh exited 0 but the login shell is still {current or 'unknown'}")


def install_perf(context: StepContext) -> None:
    # Run it rather than find it: /usr/bin/perf is linux-tools-common's wrapper,
    # which stays after a kernel update and then fails with "perf not found for
    # kernel", since linux-tools-generic tracks the GA kernel, not an HWE one.
    if context.succeeds(["perf", "--version"]):
        context.log("perf already installed; skipping")
        return
    kernel_tools = f"linux-tools-{os.uname().release}"
    context.log(f"Installing perf (linux-tools-generic and {kernel_tools})")
    # Cloud/CI runners often run a custom kernel with no matching package in
    # the archive, so this install is best-effort: warn and continue rather
    # than failing the whole script.
    packages = ["linux-tools-generic", kernel_tools]
    if tools.sudo(context, ["apt-get", "install", "-y", *packages], check=False) != 0:
        context.log(
            f"WARNING: failed to install {kernel_tools} (perf); skipping, this is expected"
            " on some cloud kernels"
        )


def install_inotify_limits(context: StepContext) -> None:
    # VS Code and other file watchers exhaust the default inotify limits on
    # large workspaces, producing "Unable to watch for file changes". Raise the
    # persistent limits via a sysctl drop-in.
    if _contents(INOTIFY_CONF) == INOTIFY_LIMITS:
        context.log("inotify limits already configured; skipping")
        return
    context.log("Configuring inotify watch/instance limits")
    tools.sudo_write(context, INOTIFY_CONF, f"{INOTIFY_LIMITS}\n")
    tools.sudo(context, ["sysctl", "-p", INOTIFY_CONF])


def install_vscode_unattended_upgrades(context: StepContext) -> None:
    # The code .deb adds Microsoft's apt repository, but unattended-upgrades
    # only takes Ubuntu origins, so VS Code fell behind and prompted for a
    # manual .deb download. Allow the repository's origin; the managed
    # "update.mode": "none" stops VS Code's own prompt.
    if context.which("unattended-upgrade") is None:
        context.log("unattended-upgrades not installed; skipping VS Code origin")
        return
    if _contents(VSCODE_ORIGIN_CONF) == VSCODE_ORIGIN:
        context.log("unattended-upgrades already allows VS Code; skipping")
        return
    context.log("Allowing unattended-upgrades to update VS Code")
    tools.sudo_write(context, VSCODE_ORIGIN_CONF, f"{VSCODE_ORIGIN}\n")


STEPS = (
    Step("install_homebrew", install_homebrew),
    Step("install_login_shell", install_login_shell),
    Step("install_perf", install_perf),
    Step("install_inotify_limits", install_inotify_limits),
    Step("install_vscode_unattended_upgrades", install_vscode_unattended_upgrades),
)
