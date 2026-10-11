from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer.steps import STEPS, completions

from .support import StepCase


class CompletionsTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.system = Path(self.scratch) / "site-functions"
        self.system.mkdir()
        patch = mock.patch.object(completions, "SYSTEM_DIRECTORIES", (self.system,))
        patch.start()
        self.addCleanup(patch.stop)
        self.out = self.home / ".local/share/zsh/site-functions"

    def step(self) -> bool:
        return self.run_step(STEPS["install_zsh_completions"])

    def test_generate(self) -> None:
        self.fake(
            "uv", '#!/bin/sh\n[ "$*" = "generate-shell-completion zsh" ] && echo "#compdef uv"\n'
        )
        self.fake(
            "atuin",
            '#!/bin/sh\n[ "$*" = "gen-completions --shell zsh" ] && echo "#compdef atuin"\n',
        )
        for dump in (".zcompdump", ".zcompdump.zwc"):
            (self.home / dump).touch()
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(), f"[install] Generated 2 zsh completion function(s) in {self.out}\n"
        )
        self.assertEqual((self.out / "_uv").read_text(), "#compdef uv\n")
        self.assertEqual(sorted(path.name for path in self.out.iterdir()), ["_atuin", "_uv"])
        self.assertFalse((self.home / ".zcompdump").exists())
        self.assertFalse((self.home / ".zcompdump.zwc").exists())

    def test_a_generator_that_fails_keeps_the_function_it_had(self) -> None:
        self.out.mkdir(parents=True)
        (self.out / "_fd").write_text("old\n")
        self.fake("fd", "#!/bin/sh\necho partial\nexit 1\n")
        self.fake("delta", "#!/bin/sh\nexit 0\n")
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(),
            "[install] Could not generate zsh completion for fd; skipping\n"
            "[install] Could not generate zsh completion for delta; skipping\n"
            f"[install] Generated 0 zsh completion function(s) in {self.out}\n",
        )
        self.assertEqual((self.out / "_fd").read_text(), "old\n")
        self.assertEqual([path.name for path in self.out.iterdir()], ["_fd"])

    def test_a_system_wide_function_is_left_to_its_owner(self) -> None:
        (self.system / "_rustup").touch()
        self.fake("rustup", "#!/bin/sh\necho '#compdef rustup'\n")
        self.assertTrue(self.step())
        self.assertFalse((self.out / "_rustup").exists())
        self.assertIn("Generated 0 ", self.said())

    def test_a_dangling_link_is_no_system_wide_function(self) -> None:
        (self.system / "_rustup").symlink_to(self.system / "gone")
        self.fake("rustup", "#!/bin/sh\necho '#compdef rustup'\n")
        self.assertTrue(self.step())
        self.assertTrue((self.out / "_rustup").exists())

    def test_the_xdg_and_zdotdir_settings(self) -> None:
        self.env["XDG_DATA_HOME"] = f"{self.scratch}/data"
        self.env["ZDOTDIR"] = f"{self.scratch}/zdot"
        Path(self.env["ZDOTDIR"]).mkdir()
        (Path(self.env["ZDOTDIR"]) / ".zcompdump").touch()
        (self.home / ".zcompdump").touch()
        self.fake("chezmoi", "#!/bin/sh\necho '#compdef chezmoi'\n")
        self.assertTrue(self.step())
        self.assertTrue((Path(self.scratch) / "data/zsh/site-functions/_chezmoi").is_file())
        self.assertFalse((Path(self.env["ZDOTDIR"]) / ".zcompdump").exists())
        self.assertTrue((self.home / ".zcompdump").exists())
