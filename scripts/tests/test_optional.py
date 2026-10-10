from __future__ import annotations

import io
from pathlib import Path
from unittest import mock

from installer.optional import OptionalTools

from .support import ConsoleCase


class OptionalToolsTest(ConsoleCase):
    def setUp(self) -> None:
        super().setUp()
        # Not a terminal, whatever the tests were started from, so nothing
        # here can stop to wait for an answer.
        stdin = mock.patch("sys.stdin", io.StringIO())
        stdin.start()
        self.addCleanup(stdin.stop)

    def tools(self, mode: str | None = None, reconfigure: bool = False) -> OptionalTools:
        env = {"HOME": "/nonexistent", "XDG_CONFIG_HOME": self.scratch}
        return OptionalTools(self.console, env, mode, reconfigure, has_tty=lambda: False)

    def state(self) -> Path:
        return Path(self.scratch) / "dotfiles" / "optional-tools.conf"

    def write_state(self, text: str) -> None:
        self.state().parent.mkdir(parents=True)
        self.state().write_text(text)

    def test_state_file_honours_xdg_config_home(self) -> None:
        self.assertEqual(self.tools().state_file, self.state())

    def test_state_file_defaults_under_home(self) -> None:
        env = {"HOME": "/home/me", "XDG_CONFIG_HOME": ""}
        tools = OptionalTools(self.console, env, None, False)
        self.assertEqual(tools.state_file, Path("/home/me/.config/dotfiles/optional-tools.conf"))

    def test_modes_decide_without_the_file(self) -> None:
        self.write_state("docker=no\nlatex=yes\n")
        self.assertTrue(self.tools(mode="all").enabled("docker", ""))
        self.assertFalse(self.tools(mode="none").enabled("latex", ""))
        self.assertEqual(self.state().read_text(), "docker=no\nlatex=yes\n")

    def test_recorded_answers_are_used(self) -> None:
        self.write_state("docker=no\nlatex=yes\n")
        tools = self.tools()
        self.assertFalse(tools.enabled("docker", ""))
        self.assertTrue(tools.enabled("latex", ""))
        self.assertEqual(self.said(), "")

    def test_no_terminal_skips_without_recording(self) -> None:
        self.assertFalse(self.tools().enabled("typst", "Typst: a compiler"))
        self.assertIn("typst: optional and no terminal to prompt on; skipping", self.said())
        self.assertFalse(self.state().exists())

    def test_reconfigure_ignores_the_recorded_answer(self) -> None:
        self.write_state("latex=yes\n")
        self.assertFalse(self.tools(reconfigure=True).enabled("latex", ""))
        # Nothing to ask on, so the old answer stays for a later run.
        self.assertEqual(self.state().read_text(), "latex=yes\n")

    def test_record_replaces_one_answer_and_keeps_the_rest(self) -> None:
        self.write_state("docker=no\nlatex=yes\ntypst=no\n")
        self.tools().record("latex", "no")
        self.assertEqual(self.state().read_text(), "docker=no\ntypst=no\nlatex=no\n")
        self.assertIn(f"Recorded latex=no in {self.state()}", self.said())

    def test_record_creates_the_directory(self) -> None:
        self.tools().record("docker", "yes")
        self.assertEqual(self.state().read_text(), "docker=yes\n")
        left = [path.name for path in self.state().parent.iterdir()]
        self.assertEqual(left, ["optional-tools.conf"])

    def test_a_name_that_prefixes_another_is_not_confused(self) -> None:
        self.write_state("docker-desktop=yes\n")
        self.assertFalse(self.tools().enabled("docker", ""))
