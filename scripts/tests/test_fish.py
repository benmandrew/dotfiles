from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import apt, tools
from installer.steps import STEPS, fish

from .support import StepCase, prints

# gpg as the step uses it: list a key's fingerprint, and dearmor a key.
GPG = """#!/bin/sh
if [ "$1" = --show-keys ]; then
    echo "fpr:::::::::$(cat "$3"):"
    exit 0
fi
echo "gpg $1 $3" >>"$FAKE_CALLS"
cp "$4" "$2"
"""


class FishTest(StepCase):
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
            (fish, "FISH", self.bin / "fish"),
        ):
            patch = mock.patch.object(module, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.fake("fish", prints("fish, version 3.3.1"))
        self.fake("gpg", GPG)
        self.fake("dpkg", prints("amd64"))
        # The fake gpg reports the served text as the key's fingerprint.
        self.serve(fish.KEY_URL, fish.FISH_PPA_FINGERPRINT)

    def test_new_enough_is_skipped(self) -> None:
        for version in ("4.9.3", "4.0"):
            self.fake("fish", prints(f"fish, version {version}"))
            self.assertTrue(self.run_step(STEPS["install_fish"]))
            self.assertIn(f"[install] fish {version} is at least 4.0; skipping\n", self.said())
        self.assertEqual(self.requests(), [])

    def test_a_fish_elsewhere_on_path_is_not_enough(self) -> None:
        # A nix-profile fish passed the old guard and left no /usr/bin/fish
        # for install_login_shell.
        other = Path(self.system)
        (other / "fish").write_text("#!/bin/sh\necho 'fish, version 4.8.0'\n")
        (other / "fish").chmod(0o755)
        (self.bin / "fish").unlink()
        self.recording("apt-get")
        self.assertFalse(self.run_step(STEPS["install_fish"]))
        self.assertIn(
            "[install] Installing fish from the fish-shell PPA (distro fish is absent)\n",
            self.said(),
        )

    def test_a_ppa_is_for_ubuntu_alone(self) -> None:
        self.os_release.write_text('ID=debian\nVERSION_CODENAME="bookworm"\n')
        self.assertTrue(self.run_step(STEPS["install_fish"]))
        self.assertEqual(
            self.said(), "[install] not Ubuntu; keeping fish 3.3.1 as the distro ships it\n"
        )

    def test_install_from_the_ppa(self) -> None:
        self.installer("apt-get", creates="fish", output="fish, version 4.2.1")
        self.assertTrue(self.run_step(STEPS["install_fish"]))
        self.assertEqual(
            self.said(),
            "[install] Installing fish from the fish-shell PPA (distro fish is 3.3.1)\n"
            "[install] fish is now 4.2.1\n",
        )
        keyring = self.keyrings / "fish-ppa.gpg"
        self.assertEqual(keyring.read_text(), fish.FISH_PPA_FINGERPRINT)
        self.assertEqual(
            (self.sources / "fish-ppa.list").read_text(),
            f"deb [arch=amd64 signed-by={keyring}]"
            " https://ppa.launchpadcontent.net/fish-shell/release-4/ubuntu jammy main\n",
        )
        self.assertEqual(
            self.called(), ["gpg --output --dearmor", "apt-get update", "apt-get install -y fish"]
        )

    def test_another_key_is_refused(self) -> None:
        self.serve(fish.KEY_URL, "0" * 40)
        self.recording("apt-get")
        self.assertFalse(self.run_step(STEPS["install_fish"]))
        self.assertIn(
            "ERROR: fish-shell PPA key does not carry the pinned fingerprint\n", self.said()
        )
        self.assertEqual(self.called(), [])

    def test_apt_leaving_the_old_fish_fails_the_step(self) -> None:
        self.recording("apt-get")
        self.assertFalse(self.run_step(STEPS["install_fish"]))
        self.assertIn(
            "ERROR: fish is 3.3.1 after installing from the PPA; need at least 4.0\n",
            self.said(),
        )

    def test_a_fish_that_does_not_run_fails_the_step(self) -> None:
        # Reports a good version, then fails to run a command.
        broken = self.bin / "fish"
        self.fake(
            "apt-get",
            f'#!/bin/sh\nprintf \'#!/bin/sh\\n[ "$1" = --version ]'
            f' && echo "fish, version 4.2.1" && exit 0\\nexit 1\\n\' >"{broken}"\n',
        )
        self.assertFalse(self.run_step(STEPS["install_fish"]))
        self.assertIn(f"ERROR: {broken} does not run after installing", self.said())
