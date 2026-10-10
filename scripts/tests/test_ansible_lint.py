from __future__ import annotations

from installer.steps import PORTED

from .support import StepCase


class AnsibleLintTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.tools = self.home / "uv-tools"
        self.fake(
            "uv",
            '#!/bin/sh\necho "uv $*" >>"$FAKE_CALLS"\n'
            f'[ "$2" = dir ] && echo "{self.tools}"\nexit 0\n',
        )

    def test_install_into_the_uv_tool_directory(self) -> None:
        self.fake("ansible-lint", '#!/bin/sh\necho "ansible-lint $*" >>"$FAKE_CALLS"\n', self.tools)
        self.assertTrue(self.run_step(PORTED["install_ansible_lint"]))
        self.assertEqual(self.said(), "[install] Installing ansible-lint\n")
        self.assertEqual(
            self.called(),
            [
                "uv tool install ansible-lint",
                "uv tool dir --bin",
                "ansible-lint --offline --version",
            ],
        )

    def test_present(self) -> None:
        self.fake("ansible-lint", "#!/bin/sh\n")
        self.assertTrue(self.run_step(PORTED["install_ansible_lint"]))
        self.assertEqual(self.said(), "[install] ansible-lint already installed; skipping\n")
        self.fake("ansible-lint", "#!/bin/sh\n", self.tools)
        self.assertTrue(self.run_step(PORTED["install_ansible_lint"], upgrade=True))
        self.assertEqual(self.called()[0], "uv tool upgrade ansible-lint")

    def test_without_uv(self) -> None:
        (self.bin / "uv").unlink()
        self.assertFalse(self.run_step(PORTED["install_ansible_lint"]))
        self.assertIn("ERROR: Missing required command: uv\n", self.said())

    def test_macos_is_a_formula(self) -> None:
        self.recording("brew", failing="list")
        self.fake("ansible-lint", "#!/bin/sh\n")
        self.assertTrue(
            self.run_step(PORTED["install_ansible_lint"], system="Darwin", machine="arm64")
        )
        self.assertEqual(self.said(), "[install] Installing ansible-lint\n")
        self.assertEqual(self.called()[-1], "brew install ansible-lint")
