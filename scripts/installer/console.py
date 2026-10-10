"""What the installer says for itself."""

from __future__ import annotations

import os

_RED = "1;31"
_GREEN = "1;32"
_YELLOW = "1;33"
_MAGENTA = "1;35"
_CYAN = "1;36"


class Console:
    """Writes to the terminal the run started on.

    The descriptor is a copy of stderr taken before any step runs. A step's
    stdout and stderr both go to its log, so everything the installer says for
    itself goes through here instead, and a bash step is handed the same
    descriptor for its own `log` and `err` (see legacy.py).
    """

    def __init__(self, fd: int) -> None:
        self.fd = fd

    def _line(self, colour: str, text: str) -> None:
        self.write(f"\033[{colour}m[install]\033[0m {text}\n".encode())

    def write(self, data: bytes) -> None:
        os.write(self.fd, data)

    def log(self, message: str) -> None:
        if "skipping" in message:
            self._line(_YELLOW, message)
        elif "pgrading" in message:
            self._line(_CYAN, message)
        else:
            self._line(_GREEN, message)

    def err(self, message: str) -> None:
        self._line(_RED, f"ERROR: {message}")

    def detail(self, message: str) -> None:
        """An indented line under an error: a failed step, a log path."""
        self._line(_RED, f"  {message}")

    def ask(self, message: str) -> None:
        """The line above a prompt."""
        self._line(_MAGENTA, message)
