from __future__ import annotations

import stat
import subprocess
import unittest
from unittest import mock

from installer.runner import Fatal
from installer.sudo import SudoSession, sudo_command, write_askpass

from .support import ConsoleCase


class SudoCommandTest(unittest.TestCase):
    def test_askpass_adds_the_flag(self) -> None:
        self.assertEqual(sudo_command({}), ["sudo"])
        self.assertEqual(sudo_command({"SUDO_ASKPASS": ""}), ["sudo"])
        self.assertEqual(sudo_command({"SUDO_ASKPASS": "/tmp/helper"}), ["sudo", "-A"])


class AskpassTest(ConsoleCase):
    def test_helper_prints_the_password_and_nobody_else_can_read_it(self) -> None:
        password = 'it\'s "quoted" $HOME `x` \\'
        # A directory with a space in it, which the helper has to quote.
        helper = write_askpass(password, self.scratch)
        self.assertEqual(stat.S_IMODE(helper.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(helper.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((helper.parent / "secret").stat().st_mode), 0o600)
        self.assertNotIn(password, helper.read_text())
        printed = subprocess.run([str(helper)], capture_output=True, text=True, check=True)
        self.assertEqual(printed.stdout, f"{password}\n")

    def test_stop_removes_the_helper_and_the_variable(self) -> None:
        env = {"TMPDIR": self.scratch}
        session = SudoSession(self.console, env)
        helper = write_askpass("secret", self.scratch)
        session._askpass_dir = helper.parent
        env["SUDO_ASKPASS"] = str(helper)
        session.stop()
        self.assertFalse(helper.parent.exists())
        self.assertNotIn("SUDO_ASKPASS", env)
        session.stop()


class PasswordPromptTest(ConsoleCase):
    def start(self, typed: list[str], correct: str) -> tuple[dict[str, str], mock.Mock]:
        env = {"TMPDIR": self.scratch}
        session = SudoSession(self.console, env)
        self.addCleanup(session.stop)

        def verify(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
            status = 0 if kwargs["input"] == f"{correct}\n".encode() else 1
            return subprocess.CompletedProcess(command, status)

        with (
            mock.patch("installer.sudo.os.geteuid", return_value=1000),
            mock.patch("installer.sudo.tty_available", return_value=True),
            mock.patch("installer.sudo.getpass.getpass", side_effect=typed) as asked,
            mock.patch("installer.sudo.subprocess.run", side_effect=verify),
        ):
            session.start_askpass()
        return env, asked

    def test_a_wrong_password_is_asked_for_again(self) -> None:
        env, asked = self.start(["typo", "right"], "right")
        self.assertEqual(asked.call_count, 2)
        self.assertIn("Sorry, try again", self.said())
        printed = subprocess.run([env["SUDO_ASKPASS"]], capture_output=True, text=True, check=True)
        self.assertEqual(printed.stdout, "right\n")

    def test_three_wrong_passwords_end_the_run(self) -> None:
        with self.assertRaisesRegex(Fatal, "sudo authentication failed"):
            self.start(["a", "b", "c", "right"], "right")
        self.assertEqual(self.said().count("Sorry, try again"), 2)

    def test_an_empty_password_falls_back_to_prompting_per_step(self) -> None:
        env, asked = self.start(["typo", ""], "right")
        self.assertEqual(asked.call_count, 2)
        self.assertNotIn("SUDO_ASKPASS", env)
        self.assertIn("No password given; falling back to prompting per step", self.said())


if __name__ == "__main__":
    unittest.main()
