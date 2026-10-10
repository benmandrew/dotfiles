"""Tools that only some machines want."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Callable

from .console import Console
from .sudo import tty_available


class OptionalTools:
    """Decides whether an optional tool is installed on this machine.

    Everything else installs everywhere, but a few tools only make sense on a
    machine someone sits in front of (a GUI app, say) and are noise on a server
    that only ever gets ssh'd into. Rather than hardcoding that split
    (hostnames churn, and a headless check only catches the Linux GUI case),
    ask once, then remember the answer in a state file so every later run,
    --upgrade included, stays non-interactive.

    Answers are stored one per line as `name=yes|no`.
    """

    def __init__(
        self,
        console: Console,
        env: dict[str, str],
        mode: str | None,
        reconfigure: bool,
        has_tty: Callable[[], bool] = tty_available,
    ) -> None:
        self.console = console
        self.mode = mode
        self.reconfigure = reconfigure
        self._has_tty = has_tty
        config = env.get("XDG_CONFIG_HOME") or os.path.join(env.get("HOME", ""), ".config")
        self.state_file = Path(config) / "dotfiles" / "optional-tools.conf"

    def enabled(self, name: str, description: str) -> bool:
        if self.mode == "all":
            return True
        if self.mode == "none":
            return False

        answer = "" if self.reconfigure else self._recorded(name)
        if not answer:
            asked = self._ask(name, description)
            if asked is None:
                return False
            answer = asked
            self.record(name, answer)
        return answer == "yes"

    def _recorded(self, name: str) -> str:
        try:
            lines = self.state_file.read_text().splitlines()
        except OSError:
            return ""
        for line in lines:
            if line.startswith(f"{name}="):
                return line.partition("=")[2]
        return ""

    def _ask(self, name: str, description: str) -> str | None:
        """yes or no, or None with nothing to ask on."""
        # /dev/tty rather than stdin, which is the script text itself when the
        # installer is piped into a shell.
        has_tty = self._has_tty()
        # Nothing to ask on (CI, a provisioning run, a detached shell): decline
        # rather than block on a read that can never be answered, and leave it
        # unrecorded so a later interactive run still gets to ask.
        if not has_tty and not sys.stdin.isatty():
            self.console.log(f"{name}: optional and no terminal to prompt on; skipping")
            return None
        self.console.ask(description)
        prompt = f"[install] Install {name}? [y/N] "
        if has_tty:
            with open("/dev/tty", "r+") as tty:
                tty.write(prompt)
                tty.flush()
                reply = tty.readline()
        else:
            self.console.write(prompt.encode())
            reply = sys.stdin.readline()
        return "yes" if reply[:1] in ("y", "Y") else "no"

    def record(self, name: str, answer: str) -> None:
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        try:
            lines = self.state_file.read_text().splitlines()
        except OSError:
            lines = []
        kept = [line for line in lines if not line.startswith(f"{name}=")]
        kept.append(f"{name}={answer}")
        # Written beside the state file and renamed over it, so an interrupted
        # run leaves the old answers rather than half a file.
        pending = self.state_file.with_name(f"{self.state_file.name}.tmp")
        pending.write_text("".join(f"{line}\n" for line in kept))
        pending.replace(self.state_file)
        self.console.log(f"Recorded {name}={answer} in {self.state_file}")
