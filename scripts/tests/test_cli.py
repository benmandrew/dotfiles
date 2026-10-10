from __future__ import annotations

import contextlib
import io
import os
import unittest

from installer.cli import parse_args, run
from installer.plan import OptionalStep, Plan, Require
from installer.runner import Settings, Step, StepContext, StepFailed

from .support import ConsoleCase


class ParseArgsTest(unittest.TestCase):
    def test_defaults(self) -> None:
        self.assertEqual(parse_args([]), Settings())

    def test_flags(self) -> None:
        self.assertEqual(
            parse_args(["--upgrade", "--verbose", "--reconfigure-optional", "--all-optional"]),
            Settings(upgrade=True, verbose=True, optional_mode="all", reconfigure_optional=True),
        )
        self.assertEqual(parse_args(["--no-optional"]).optional_mode, "none")

    def test_unknown_argument_is_refused(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            parse_args(["--upgrde"])
        self.assertEqual(caught.exception.code, 2)

    def test_optional_modes_exclude_each_other(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse_args(["--all-optional", "--no-optional"])


class RunTest(ConsoleCase):
    """A whole run over a plan of Python steps. Root, so no sudo is involved."""

    def setUp(self) -> None:
        super().setUp()
        self.ran: list[str] = []
        self.env = dict(
            os.environ,
            TMPDIR=self.scratch,
            XDG_CONFIG_HOME=self.scratch,
            DOTFILES_NO_ASKPASS="1",
        )
        geteuid = os.geteuid
        os.geteuid = lambda: 0
        self.addCleanup(setattr, os, "geteuid", geteuid)

    def step(self, name: str, fail: bool = False, fatal: bool = False) -> Step:
        def action(_context: StepContext) -> None:
            self.ran.append(name)
            if fail:
                raise StepFailed

        return Step(name, action, fatal=fatal)

    def run_plan(self, plan: Plan, optional_mode: str | None = None) -> int:
        return run(self.console, Settings(optional_mode=optional_mode), self.env, plan)

    def test_all_steps_pass(self) -> None:
        plan = Plan(requires=("sh",), items=(self.step("one"), Require(("sh",)), self.step("two")))
        self.assertEqual(self.run_plan(plan), 0)
        self.assertEqual(self.ran, ["one", "two"])
        said = self.said()
        self.assertTrue(said.startswith("[install] Checking prerequisites\n"))
        self.assertIn("You can initialize chezmoi with: chezmoi init --apply", said)

    def test_a_failed_step_does_not_stop_the_rest(self) -> None:
        plan = Plan(requires=(), items=(self.step("one", fail=True), self.step("two")))
        self.assertEqual(self.run_plan(plan), 1)
        self.assertEqual(self.ran, ["one", "two"])
        self.assertTrue(self.said().endswith("ERROR: 1 step failed:\n[install]   one\n"))

    def test_missing_prerequisite_ends_the_run_before_any_step(self) -> None:
        plan = Plan(requires=("sh", "no-such-command-here"), items=(self.step("one"),))
        self.assertEqual(self.run_plan(plan), 1)
        self.assertEqual(self.ran, [])
        self.assertIn("ERROR: Missing required command: no-such-command-here", self.said())

    def test_missing_command_mid_plan_ends_the_run(self) -> None:
        plan = Plan(
            requires=(),
            items=(self.step("one"), Require(("no-such-command-here",)), self.step("two")),
        )
        self.assertEqual(self.run_plan(plan), 1)
        self.assertEqual(self.ran, ["one"])

    def test_fatal_step_ends_the_run(self) -> None:
        plan = Plan(requires=(), items=(self.step("base", fail=True, fatal=True), self.step("two")))
        self.assertEqual(self.run_plan(plan), 1)
        self.assertEqual(self.ran, ["base"])
        self.assertNotIn("chezmoi init", self.said())

    def test_optional_steps_follow_the_mode(self) -> None:
        plan = Plan(requires=(), items=(OptionalStep("extra", "An extra", self.step("extra")),))
        self.assertEqual(self.run_plan(plan, optional_mode="none"), 0)
        self.assertEqual(self.ran, [])
        self.assertEqual(self.run_plan(plan, optional_mode="all"), 0)
        self.assertEqual(self.ran, ["extra"])


if __name__ == "__main__":
    unittest.main()
