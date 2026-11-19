from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer.steps import STEPS, completions

from .support import StepCase


class CompletionsTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.fish_system = Path(self.scratch) / "vendor_completions.d"
        self.fish_system.mkdir()
        patch = mock.patch.dict(completions.SYSTEM_DIRECTORIES, {"fish": (self.fish_system,)})
        patch.start()
        self.addCleanup(patch.stop)
        self.fish = self.home / ".local/share/fish/vendor_completions.d"

    def fish_said(self, generated: int) -> str:
        return f"[install] Generated {generated} fish completion file(s) in {self.fish}\n"

    def step(self) -> bool:
        return self.run_step(STEPS["install_shell_completions"])

    def test_generate(self) -> None:
        self.fake(
            "uv",
            '#!/bin/sh\n[ "$*" = "generate-shell-completion fish" ] && echo "complete -c uv"\n'
            "exit 0\n",
        )
        self.fake(
            "atuin",
            '#!/bin/sh\n[ "$*" = "gen-completions --shell fish" ] && echo "complete -c atuin"\n'
            "exit 0\n",
        )
        self.assertTrue(self.step())
        self.assertEqual(self.said(), self.fish_said(2))
        self.assertEqual((self.fish / "uv.fish").read_text(), "complete -c uv\n")
        self.assertEqual(
            sorted(path.name for path in self.fish.iterdir()), ["atuin.fish", "uv.fish"]
        )

    def test_a_generator_that_fails_keeps_the_file_it_had(self) -> None:
        self.fish.mkdir(parents=True)
        (self.fish / "fd.fish").write_text("old\n")
        self.fake("fd", "#!/bin/sh\necho partial\nexit 1\n")
        self.fake("delta", "#!/bin/sh\nexit 0\n")
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(),
            "[install] Could not generate fish completion for fd; skipping\n"
            "[install] Could not generate fish completion for delta; skipping\n"
            + self.fish_said(0),
        )
        self.assertEqual((self.fish / "fd.fish").read_text(), "old\n")
        self.assertEqual([path.name for path in self.fish.iterdir()], ["fd.fish"])

    def test_a_system_wide_completion_is_left_to_its_owner(self) -> None:
        (self.fish_system / "chezmoi.fish").touch()
        self.fake("chezmoi", "#!/bin/sh\necho 'complete -c chezmoi'\n")
        self.assertTrue(self.step())
        self.assertFalse((self.fish / "chezmoi.fish").exists())
        self.assertIn(self.fish_said(0), self.said())

    def test_a_dangling_link_is_no_system_wide_completion(self) -> None:
        (self.fish_system / "rustup.fish").symlink_to(self.fish_system / "gone")
        self.fake("rustup", "#!/bin/sh\necho 'complete -c rustup'\n")
        self.assertTrue(self.step())
        self.assertTrue((self.fish / "rustup.fish").exists())

    def test_the_xdg_setting(self) -> None:
        self.env["XDG_DATA_HOME"] = f"{self.scratch}/data"
        self.fake("chezmoi", "#!/bin/sh\necho 'complete -c chezmoi'\n")
        self.assertTrue(self.step())
        self.assertTrue(
            (Path(self.scratch) / "data/fish/vendor_completions.d/chezmoi.fish").is_file()
        )
