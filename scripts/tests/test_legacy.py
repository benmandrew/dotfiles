"""The bash steps, run for real through legacy-step.sh.

`eval`, `export` and the helpers in install-common.sh stand in for install
steps, since the shim calls whatever it is given.
"""

from __future__ import annotations

import os

from installer.legacy import legacy
from installer.runner import Runner, Settings

from .support import ConsoleCase


class LegacyTest(ConsoleCase):
    def runner(self, upgrade: bool = False) -> Runner:
        self.env = dict(os.environ, TMPDIR=self.scratch)
        self.env.pop("DOTFILES_UPGRADE", None)
        runner = Runner(self.console, Settings(upgrade=upgrade), self.env)
        self.addCleanup(runner.close)
        return runner

    def test_log_reaches_the_terminal_and_output_is_held(self) -> None:
        runner = self.runner()
        self.assertTrue(runner.run(legacy("eval", "echo noise; echo more >&2; log 'said so'")))
        self.assertEqual(self.said(), "[install] said so\n")

    def test_failing_function_fails_the_step(self) -> None:
        runner = self.runner()
        self.assertFalse(runner.run(legacy("eval", "echo before; false")))
        said = self.said()
        self.assertIn("before\n", said)
        self.assertIn("ERROR: Step failed: eval echo before; false", said)

    def test_helper_statuses_come_back(self) -> None:
        runner = self.runner()
        self.assertTrue(runner.run(legacy("version_gte", "1.2.3", "1.2.0")))
        self.assertFalse(runner.run(legacy("version_gte", "1.2.0", "1.2.3")))

    def test_unknown_function_fails_the_step(self) -> None:
        runner = self.runner()
        self.assertFalse(runner.run(legacy("install_no_such_tool")))
        self.assertIn("command not found", self.said())

    def test_exported_variable_reaches_the_next_step(self) -> None:
        runner = self.runner()
        self.assertTrue(runner.run(legacy("export", "DOTFILES_TEST_VALUE=a b\nc")))
        self.assertEqual(self.env["DOTFILES_TEST_VALUE"], "a b\nc")
        check = "[[ \"${DOTFILES_TEST_VALUE}\" == $'a b\\nc' ]]"
        self.assertTrue(runner.run(legacy("eval", check)))

    def test_unset_variable_is_gone_for_the_next_step(self) -> None:
        runner = self.runner()
        self.env["DOTFILES_TEST_VALUE"] = "set"
        self.assertTrue(runner.run(legacy("unset", "DOTFILES_TEST_VALUE")))
        self.assertNotIn("DOTFILES_TEST_VALUE", self.env)

    def test_runner_variables_are_not_carried(self) -> None:
        runner = self.runner()
        self.assertTrue(runner.run(legacy("true")))
        self.assertNotIn("DOTFILES_TERM_FD", self.env)
        self.assertNotIn("DOTFILES_UPGRADE", self.env)
        self.assertEqual(self.env["HOME"], os.environ["HOME"])

    def test_step_that_exits_keeps_the_environment(self) -> None:
        runner = self.runner()
        self.env["DOTFILES_TEST_VALUE"] = "kept"
        self.assertFalse(runner.run(legacy("eval", "export DOTFILES_TEST_VALUE=lost; exit 4")))
        self.assertEqual(self.env["DOTFILES_TEST_VALUE"], "kept")

    def test_unset_variable_under_nounset_fails_the_step(self) -> None:
        runner = self.runner()
        self.assertFalse(runner.run(legacy("eval", 'echo "${DOTFILES_NEVER_SET}"')))
        self.assertIn("unbound variable", self.said())

    def test_upgrade_is_passed_down(self) -> None:
        self.assertTrue(self.runner().run(legacy("eval", '[[ -z "${UPGRADE}" ]]')))
        self.assertTrue(self.runner(upgrade=True).run(legacy("eval", '[[ -n "${UPGRADE}" ]]')))

    def test_stdin_is_closed(self) -> None:
        self.assertTrue(self.runner().run(legacy("eval", "! read -r _line")))

    def test_sudo_function_survives(self) -> None:
        self.assertTrue(self.runner().run(legacy("eval", '[[ "$(type -t sudo)" == function ]]')))
