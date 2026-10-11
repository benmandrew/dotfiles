from __future__ import annotations

import os
import unittest

from installer.console import Console


def read_all(fd: int) -> str:
    chunks: list[bytes] = []
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            return b"".join(chunks).decode()
        chunks.append(chunk)


class ConsoleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, self.read_fd)
        self.console = Console(write_fd)

    def output(self) -> str:
        os.close(self.console.fd)
        return read_all(self.read_fd)

    def test_log_is_green(self) -> None:
        self.console.log("Installing jq")
        self.assertEqual(self.output(), "\033[1;32m[install]\033[0m Installing jq\n")

    def test_skipping_is_yellow(self) -> None:
        self.console.log("jq already installed; skipping")
        self.assertTrue(self.output().startswith("\033[1;33m[install]"))

    def test_upgrading_is_cyan(self) -> None:
        self.console.log("Upgrading jq")
        self.assertTrue(self.output().startswith("\033[1;36m[install]"))

    def test_err(self) -> None:
        self.console.err("no")
        self.assertEqual(self.output(), "\033[1;31m[install]\033[0m ERROR: no\n")

    def test_detail_is_indented(self) -> None:
        self.console.detail("install_jq")
        self.assertEqual(self.output(), "\033[1;31m[install]\033[0m   install_jq\n")


if __name__ == "__main__":
    unittest.main()
