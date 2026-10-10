from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

from installer.runner import Fatal, Runner, Settings, Step, StepContext, StepFailed

from .support import ConsoleCase


def python(code: str) -> list[str]:
    return [sys.executable, "-c", code]


class RunnerTest(ConsoleCase):
    def runner(self, verbose: bool = False) -> Runner:
        env = dict(os.environ, TMPDIR=self.scratch)
        runner = Runner(self.console, Settings(verbose=verbose), env)
        self.addCleanup(runner.close)
        return runner

    def logs(self) -> list[Path]:
        return sorted(Path(self.scratch).glob("dotfiles-install.*/*.log"))

    def test_passing_step_leaves_no_log(self) -> None:
        def action(context: StepContext) -> None:
            self.assertEqual(context.call(python("print('noise')")), 0)

        runner = self.runner()
        self.assertTrue(runner.run(Step("quiet_step", action)))
        self.assertEqual(self.logs(), [])
        self.assertEqual(self.said(), "")
        self.assertEqual(runner.finish(), 0)
        runner.close()
        self.assertEqual(list(Path(self.scratch).glob("dotfiles-install.*")), [])

    def test_failing_step_keeps_its_log_and_prints_the_tail(self) -> None:
        def action(context: StepContext) -> None:
            code = "import sys\nfor n in range(80): print('line', n)\nsys.exit('boom')"
            if context.call(python(code)) != 0:
                raise StepFailed

        runner = self.runner()
        self.assertFalse(runner.run(Step("noisy", action, args=("a", "b"))))
        said = self.said()
        (log,) = self.logs()
        self.assertEqual(log.name, "noisy.log")
        self.assertIn(f"ERROR: Output of noisy, last 50 lines (all of it: {log}):", said)
        # Both streams are held, and only the last 50 lines come back.
        self.assertIn("boom\n", log.read_text())
        self.assertIn("line 79\n", said)
        self.assertIn("line 30\n", said)
        self.assertNotIn("line 29\n", said)
        self.assertIn("ERROR: Step failed: noisy a b", said)
        self.assertEqual(runner.failed, ["noisy a b"])

    def test_finish_names_every_failed_step(self) -> None:
        def fail(_context: StepContext) -> None:
            raise StepFailed("went wrong")

        runner = self.runner()
        runner.run(Step("one", fail))
        runner.run(Step("two", fail, args=("x",)))
        self.assertEqual(runner.finish(), 1)
        said = self.said()
        self.assertIn("ERROR: went wrong", said)
        summary = "ERROR: 2 steps failed:\n[install]   one\n[install]   two x\n"
        self.assertTrue(said.endswith(summary))

    def test_finish_counts_one_step(self) -> None:
        def fail(_context: StepContext) -> None:
            raise StepFailed

        runner = self.runner()
        runner.run(Step("one", fail))
        runner.finish()
        self.assertIn("ERROR: 1 step failed:", self.said())

    def test_fatal_step_ends_the_run(self) -> None:
        def fail(_context: StepContext) -> None:
            raise StepFailed

        runner = self.runner()
        with self.assertRaises(Fatal):
            runner.run(Step("base", fail, fatal=True))
        self.assertIn("ERROR: Step failed: base", self.said())
        self.assertEqual(runner.failed, [])
        # The log was named where the step failed, so close has nothing to add.
        runner.close()
        self.assertNotIn("stopped inside a step", self.said())

    def test_bug_in_a_step_fails_that_step_alone(self) -> None:
        def broken(_context: StepContext) -> None:
            raise KeyError("oops")

        runner = self.runner()
        self.assertFalse(runner.run(Step("broken", broken)))
        self.assertIn("KeyError: 'oops'", self.said())
        self.assertTrue(runner.run(Step("fine", lambda _context: None)))
        self.assertEqual(runner.failed, ["broken"])

    def test_stdin_is_closed_to_a_held_step(self) -> None:
        def action(context: StepContext) -> None:
            code = "import sys; sys.exit(0 if sys.stdin.read() == '' else 1)"
            self.assertEqual(context.call(python(code)), 0)

        self.assertTrue(self.runner().run(Step("reads", action)))

    def test_verbose_holds_nothing(self) -> None:
        def action(context: StepContext) -> None:
            if context.call(python("import sys; sys.exit(3)")) != 0:
                raise StepFailed

        runner = self.runner(verbose=True)
        self.assertFalse(runner.run(Step("loud", action)))
        self.assertEqual(self.logs(), [])
        self.assertNotIn("Output of", self.said())
        self.assertIn("ERROR: Step failed: loud", self.said())

    def test_interrupted_step_leaves_its_log_named(self) -> None:
        def interrupted(context: StepContext) -> None:
            context.call(python("print('half way')"))
            raise KeyboardInterrupt

        runner = self.runner()
        with self.assertRaises(KeyboardInterrupt):
            runner.run(Step("slow", interrupted))
        runner.close()
        (log,) = self.logs()
        self.assertEqual(log.read_text(), "half way\n")
        said = self.said()
        self.assertIn("ERROR: The run stopped inside a step. Its output is in:", said)
        self.assertIn(f"[install]   {log}", said)

    def test_environment_is_shared_between_steps(self) -> None:
        def first(context: StepContext) -> None:
            context.env["DOTFILES_TEST_VALUE"] = "carried"

        def second(context: StepContext) -> None:
            code = "import os, sys; sys.exit(os.environ.get('DOTFILES_TEST_VALUE') != 'carried')"
            if context.call(python(code)) != 0:
                raise StepFailed

        runner = self.runner()
        self.assertTrue(runner.run(Step("first", first)))
        self.assertTrue(runner.run(Step("second", second)))


if __name__ == "__main__":
    unittest.main()
