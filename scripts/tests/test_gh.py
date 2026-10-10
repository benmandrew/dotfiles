from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import apt
from installer.steps import PORTED, gh

from .support import StepCase, prints

OFFICIAL = """gh:
  Installed: 2.80.0
  Candidate: 2.80.0
  Version table:
 *** 2.80.0 500
        500 https://cli.github.com/packages stable/main arm64 Packages
        100 /var/lib/dpkg/status
"""
DISTRO = OFFICIAL.replace("https://cli.github.com/packages stable", "http://ports.ubuntu.com jammy")


class GhTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        etc = Path(self.scratch) / "etc"
        self.keyrings = etc / "keyrings"
        self.sources = etc / "sources.list.d"
        self.sources.mkdir(parents=True)
        for name, value in (("KEYRINGS", self.keyrings), ("SOURCES", self.sources)):
            patch = mock.patch.object(apt, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.fake("dpkg", prints("arm64"))
        self.serve(gh.KEYRING_URL, b"key")

    def policy(self, text: str) -> None:
        (Path(self.scratch) / "policy").write_text(text)
        self.fake("apt-cache", f'#!/bin/sh\ncat "{self.scratch}/policy"\n')

    def test_install_from_the_official_repository(self) -> None:
        self.installer("apt-get", creates="gh")
        self.assertTrue(self.run_step(PORTED["install_gh"]))
        self.assertEqual(self.said(), "[install] Installing GitHub CLI from official apt repo\n")
        keyring = self.keyrings / "githubcli-archive-keyring.gpg"
        self.assertEqual(keyring.read_bytes(), b"key")
        self.assertEqual(
            (self.sources / "github-cli.list").read_text(),
            f"deb [arch=arm64 signed-by={keyring}] https://cli.github.com/packages stable main\n",
        )
        self.assertEqual(self.called(), ["apt-get update", "apt-get install -y gh"])

    def test_gh_from_the_official_repository_is_skipped(self) -> None:
        self.fake("gh", "#!/bin/sh\n")
        (self.sources / "github-cli.list").write_text("deb\n")
        self.policy(OFFICIAL)
        self.assertTrue(self.run_step(PORTED["install_gh"]))
        self.assertEqual(self.said(), "[install] GitHub CLI already installed; skipping\n")

    def test_the_distro_gh_is_migrated(self) -> None:
        # The list file is there, but the installed gh did not come from it.
        self.fake("gh", "#!/bin/sh\n")
        (self.sources / "github-cli.list").write_text("deb\n")
        self.policy(DISTRO)
        self.recording("apt-get")
        self.assertTrue(self.run_step(PORTED["install_gh"]))
        self.assertEqual(self.called()[-1], "apt-get install -y gh")

    def test_no_keyring_no_repository(self) -> None:
        (self.web / "cli.github.com/packages/githubcli-archive-keyring.gpg").unlink()
        self.recording("apt-get")
        self.assertFalse(self.run_step(PORTED["install_gh"]))
        self.assertFalse((self.sources / "github-cli.list").exists())
        self.assertEqual(self.called(), [])

    def test_macos(self) -> None:
        (self.bin / "gh").unlink()
        self.installer("brew", creates="gh")
        self.assertTrue(self.run_step(PORTED["install_gh"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] Installing GitHub CLI\n")
        self.assertEqual(self.called(), ["brew install gh"])
        self.assertTrue(
            self.run_step(PORTED["install_gh"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(self.called()[-1], "brew upgrade gh")
