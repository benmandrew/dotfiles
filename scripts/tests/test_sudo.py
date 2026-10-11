from __future__ import annotations

import stat
import subprocess
import unittest

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


if __name__ == "__main__":
    unittest.main()
