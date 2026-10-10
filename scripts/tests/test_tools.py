from __future__ import annotations

import stat

from installer import tools
from installer.runner import StepContext

from .support import StepCase, prints


class VersionTest(StepCase):
    def test_version_gte(self) -> None:
        for current, required, expected in (
            ("4.4.3", "4.4.3", True),
            ("4.10.0", "4.9.9", True),
            ("3.31.6", "4.0.0", False),
            ("4.4", "4.4.1", False),
            ("5", "4.9.9", True),
            ("4.4.3-rc1", "4.4.3", True),
            ("", "0.0.1", False),
        ):
            with self.subTest(current=current, required=required):
                self.assertEqual(tools.version_gte(current, required), expected)


class ToolsTest(StepCase):
    def test_require_runs(self) -> None:
        self.fake("good", prints("good 1.0"))
        self.fake("bad", "#!/bin/sh\nexit 3\n")
        self.assertTrue(self.run_action(lambda context: tools.require_runs(context, "good")))
        self.assertFalse(
            self.run_action(lambda context: tools.require_runs(context, "bad", "version", "-q"))
        )
        self.assertIn(
            f"ERROR: bad does not run after installing ({self.bin}/bad;"
            " probed with 'version -q')\n",
            self.said(),
        )

    def test_require_runs_names_a_missing_command(self) -> None:
        self.assertFalse(self.run_action(lambda context: tools.require_runs(context, "absent")))
        self.assertIn(
            "ERROR: absent does not run after installing (not on PATH; probed with '--version')\n",
            self.said(),
        )

    def test_install_binary_and_note_shadowed(self) -> None:
        self.fake("tool", prints("the older copy"))
        source = self.fake("tool", prints("new"), self.home / "download")

        def action(context: StepContext) -> None:
            target = tools.install_binary(context, source, "tool")
            self.assertEqual(target, self.home / ".local/bin/tool")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
            tools.note_shadowed(context, "tool", target)
            # Nothing is said for a command that is not on PATH at all.
            tools.note_shadowed(context, "absent", target)

        self.assertTrue(self.run_action(action))
        self.assertEqual(
            self.said(),
            f"[install] Note: tool on PATH is {self.bin}/tool, which shadows the copy just"
            f" installed at {self.home}/.local/bin/tool\n",
        )

    def test_step_context(self) -> None:
        scratch = []

        def action(context: StepContext) -> None:
            scratch.append(context.tmpdir())
            self.assertTrue(scratch[0].is_dir())
            self.assertEqual(context.call(["no-such-command"]), 127)
            self.assertEqual(context.capture(["/bin/sh", "-c", "echo out; echo err >&2"]), "out")
            self.assertIsNone(context.capture(["/bin/sh", "-c", "echo out; exit 1"]))
            self.assertIsNone(context.capture(["no-such-command"]))
            self.assertFalse(context.succeeds(["no-such-command"]))
            context.run(["/bin/sh", "-c", "exit 4"])

        self.assertFalse(self.run_action(action))
        # The scratch directory goes with the step, however the step ends.
        self.assertFalse(scratch[0].exists())
        self.assertIn("no-such-command: command not found\n", self.said())
        self.assertIn("err\n", self.said())
