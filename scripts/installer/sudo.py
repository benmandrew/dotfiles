"""One sudo password for the whole run."""

from __future__ import annotations

import getpass
import os
import shlex
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

from .console import Console
from .runner import Fatal

# Seconds between refreshes of the sudo timestamp. sudo caches credentials for
# 15 minutes by default, and less on some configs.
KEEPALIVE_INTERVAL = 50


def sudo_command(env: dict[str, str]) -> list[str]:
    """`sudo`, with -A when the askpass helper is in place.

    Homebrew adds -A itself whenever SUDO_ASKPASS is set, and the bash steps
    get it from the `sudo` function in install-common.sh. This is for the
    Python side. Leave -A off where the call must never prompt, as in the
    keepalive's `sudo -n true`.
    """
    if env.get("SUDO_ASKPASS"):
        return ["sudo", "-A"]
    return ["sudo"]


def tty_available() -> bool:
    """Whether there is a terminal to prompt on.

    Opening /dev/tty is the test. The device node is readable even with no
    controlling terminal attached, where opening it fails.
    """
    try:
        os.close(os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY))
    except OSError:
        return False
    return True


def write_askpass(password: str, tmpdir: str | None) -> Path:
    """Write the askpass helper and its secret, and return the helper's path.

    Both sit in a mode-0700 directory and are created with their final mode,
    so the password never touches a file anyone else can read. The password
    lives in a data file rather than inside the script text, so no shell
    quoting has to survive a round trip through it.
    """
    directory = Path(tempfile.mkdtemp(prefix="dotfiles-askpass.", dir=tmpdir or None))
    secret = directory / "secret"
    helper = directory / "askpass"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    with os.fdopen(os.open(secret, flags, 0o600), "w") as handle:
        handle.write(f"{password}\n")
    with os.fdopen(os.open(helper, flags, 0o700), "w") as handle:
        handle.write(f"#!/bin/sh\nexec cat {shlex.quote(str(secret))}\n")
    return helper


class SudoSession:
    """Authenticates once and keeps the credential for the length of the run.

    Homebrew 6 runs `sudo --reset-timestamp` as unconditional preamble on every
    brew invocation (Library/Homebrew/brew.sh), and sudo's default
    timestamp_type is `tty`, one record per terminal, so each brew command
    destroys the very record this run authenticated. A background refresher
    cannot repair that: `sudo -n true` is non-interactive by definition and the
    record is gone, not stale. That is why an --upgrade run asked for the
    password four times.

    An askpass helper is the way out. sudo runs it instead of prompting when
    given -A, and Homebrew opts in on its own (system_command.rb adds -A
    whenever SUDO_ASKPASS is set), so reading the password once up front covers
    both this installer's sudo calls and the ones brew makes internally for
    pkg-based casks.

    The cost is that the password sits in a file for the length of the run. It
    is readable only by this user, who could read it from their own keychain
    anyway, and `stop` removes it. A run killed with SIGKILL leaves it behind.
    Set DOTFILES_NO_ASKPASS=1 to skip all of this and take the prompts.
    """

    def __init__(self, console: Console, env: dict[str, str]) -> None:
        self.console = console
        self.env = env
        self._askpass_dir: Path | None = None
        self._stop_keepalive = threading.Event()
        self._keepalive: threading.Thread | None = None

    def start_askpass(self) -> None:
        if self.env.get("DOTFILES_NO_ASKPASS"):
            return
        # Already root: nothing to authenticate.
        if os.geteuid() == 0:
            return
        # Nothing to read a password on (CI, a piped provisioning run): leave
        # sudo to prompt or fail on its own terms rather than blocking on a
        # dead tty.
        if not tty_available():
            return

        self.console.log(
            "Reading the sudo password once, so brew's timestamp reset cannot force a re-prompt"
        )
        try:
            password = getpass.getpass("[install] Password: ")
        except EOFError:
            password = ""
        if not password:
            self.console.log("No password given; falling back to prompting per step")
            return

        # Verify now rather than let a typo surface halfway through the run as
        # a helper quietly feeding the wrong password to every step.
        check = subprocess.run(
            ["sudo", "-S", "-v"],
            input=f"{password}\n".encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=self.env,
            check=False,
        )
        if check.returncode != 0:
            raise Fatal("sudo authentication failed")

        helper = write_askpass(password, self.env.get("TMPDIR"))
        self._askpass_dir = helper.parent
        self.env["SUDO_ASKPASS"] = str(helper)

    def start_keepalive(self) -> None:
        """Authenticate, then refresh the timestamp from the background.

        A full install comfortably outruns sudo's cache, especially the
        --upgrade path, which rebuilds tmux and re-downloads every toolchain,
        so the password would be asked for again at each later sudo step.
        Refreshing covers every step whose only problem is outlasting the
        cache. With an askpass helper in place the refresher is belt and
        braces: a reset timestamp costs a silent helper call rather than a
        prompt.
        """
        # Already root: nothing to cache, and `sudo -v` would be pointless.
        if os.geteuid() == 0:
            return
        if self.env.get("SUDO_ASKPASS"):
            self.console.log(
                "Requesting sudo access (refreshed in the background; "
                "the askpass helper covers brew's timestamp resets)"
            )
        else:
            self.console.log(
                "Requesting sudo access (refreshed in the background; "
                "steps that follow a brew command may re-prompt)"
            )
        check = subprocess.run([*sudo_command(self.env), "-v"], env=self.env, check=False)
        if check.returncode != 0:
            raise Fatal("sudo authentication failed")
        # A daemon thread, so it cannot outlive the run however the run ends.
        self._keepalive = threading.Thread(target=self._refresh, daemon=True)
        self._keepalive.start()

    def _refresh(self) -> None:
        # `sudo -n true` never prompts, so a refresh that fails costs nothing
        # and is ignored rather than ending the loop: after a brew command has
        # wiped the timestamp, or under a sudoers config with
        # timestamp_timeout=0, the next step that authenticates by hand hands
        # the credential back and the loop carries it forward again. Stopping
        # here instead retired the refresher for the whole run at the first
        # brew command, which is most of an --upgrade.
        sudo = shutil.which("sudo", path=self.env.get("PATH")) or "sudo"
        while True:
            subprocess.run(
                [sudo, "-n", "true"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if self._stop_keepalive.wait(KEEPALIVE_INTERVAL):
                return

    def stop(self) -> None:
        self._stop_keepalive.set()
        if self._askpass_dir is not None:
            shutil.rmtree(self._askpass_dir, ignore_errors=True)
            self._askpass_dir = None
        self.env.pop("SUDO_ASKPASS", None)
