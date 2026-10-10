"""Shared by the tests: a console whose output can be read back."""

from __future__ import annotations

import os
import re
import tempfile
import unittest

from installer.console import Console

_COLOUR = re.compile(r"\033\[[0-9;]*m")


class ConsoleCase(unittest.TestCase):
    """A test with a console writing to a file, and a scratch directory."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        # Resolved, since macOS reaches its temporary directory by a symlink.
        self.scratch = os.path.realpath(scratch.name)
        self._console_path = os.path.join(self.scratch, "console")
        fd = os.open(self._console_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.addCleanup(os.close, fd)
        self.console = Console(fd)

    def said(self) -> str:
        """Everything written to the console so far, without the colours."""
        with open(self._console_path, encoding="utf-8", errors="replace") as handle:
            return _COLOUR.sub("", handle.read())
