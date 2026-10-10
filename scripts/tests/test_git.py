from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import apt, tools
from installer.steps import PORTED, git

from .support import StepCase, prints

# gpg as the step uses it: list a key's fingerprint, and dearmor a key.
GPG = """#!/bin/sh
if [ "$1" = --show-keys ]; then
    echo "pub:-:4096:1:E363C90F8F1B6217:1263380161:::-:::scESC::::::23::0:"
    echo "fpr:::::::::$(cat "$3"):"
    exit 0
fi
echo "gpg $1 $3" >>"$FAKE_CALLS"
cp "$4" "$2"
"""


class GitTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        etc = Path(self.scratch) / "etc"
        self.keyrings = etc / "keyrings"
        self.sources = etc / "sources.list.d"
        self.sources.mkdir(parents=True)
        self.os_release = etc / "os-release"
        self.os_release.write_text('NAME="Ubuntu"\nID=ubuntu\nVERSION_CODENAME=jammy\n')
        for module, name, value in (
            (apt, "KEYRINGS", self.keyrings),
            (apt, "SOURCES", self.sources),
            (tools, "OS_RELEASE", self.os_release),
        ):
            patch = mock.patch.object(module, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.fake("git", prints("git version 2.34.1"))
        self.fake("gpg", GPG)
        self.fake("dpkg", prints("arm64"))
        # The fake gpg reports the served text as the key's fingerprint.
        self.serve(git.KEY_URL, git.GIT_CORE_PPA_FINGERPRINT)

    def test_new_enough_is_skipped(self) -> None:
        self.fake("git", prints("git version 2.43.0"))
        self.assertTrue(self.run_step(PORTED["install_git"]))
        self.assertEqual(self.said(), "[install] git 2.43.0 is at least 2.35.0; skipping\n")
        self.fake("git", prints("git version 2.35.0"))
        self.assertTrue(self.run_step(PORTED["install_git"]))
        self.assertIn("[install] git 2.35.0 is at least 2.35.0; skipping\n", self.said())
        self.assertEqual(self.requests(), [])

    def test_a_ppa_is_for_ubuntu_alone(self) -> None:
        self.os_release.write_text('ID=debian\nVERSION_CODENAME="bookworm"\n')
        self.assertTrue(self.run_step(PORTED["install_git"]))
        self.assertEqual(
            self.said(), "[install] not Ubuntu; keeping git 2.34.1 as the distro ships it\n"
        )
        (self.bin / "git").unlink()
        self.os_release.unlink()
        self.assertTrue(self.run_step(PORTED["install_git"]))
        self.assertIn("keeping git (absent) as the distro ships it\n", self.said())

    def test_install_from_the_ppa(self) -> None:
        self.installer("apt-get", creates="git", output="git version 2.47.1")
        self.assertTrue(self.run_step(PORTED["install_git"]))
        self.assertEqual(
            self.said(),
            "[install] Installing git from the git-core PPA (distro git is 2.34.1)\n"
            "[install] git is now 2.47.1\n",
        )
        keyring = self.keyrings / "git-core-ppa.gpg"
        self.assertEqual(keyring.read_text(), git.GIT_CORE_PPA_FINGERPRINT)
        self.assertEqual(
            (self.sources / "git-core-ppa.list").read_text(),
            f"deb [arch=arm64 signed-by={keyring}]"
            " https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy main\n",
        )
        self.assertEqual(
            self.called(), ["gpg --output --dearmor", "apt-get update", "apt-get install -y git"]
        )

    def test_upgrade_goes_to_the_ppa_whatever_is_installed(self) -> None:
        self.fake("git", prints("git version 2.43.0"))
        self.recording("apt-get")
        self.assertTrue(self.run_step(PORTED["install_git"], upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Installing git from the git-core PPA (distro git is 2.43.0)\n"
            "[install] git is now 2.43.0\n",
        )

    def test_another_key_is_refused(self) -> None:
        self.serve(git.KEY_URL, "0" * 40)
        self.recording("apt-get")
        self.assertFalse(self.run_step(PORTED["install_git"]))
        self.assertIn(
            "ERROR: git-core PPA key does not carry the pinned fingerprint\n", self.said()
        )
        self.assertEqual(self.called(), [])
        self.assertFalse(self.keyrings.exists())

    def test_apt_leaving_the_old_git_fails_the_step(self) -> None:
        self.recording("apt-get")
        self.assertFalse(self.run_step(PORTED["install_git"]))
        self.assertIn(
            "ERROR: git is 2.34.1 after installing from the PPA; need at least 2.35.0\n",
            self.said(),
        )
