from __future__ import annotations

from installer import pins
from installer.steps import STEPS

from .support import StepCase, prints

TAG = pins.pin("ELAN_VERSION")
BASE = f"https://github.com/leanprover/elan/releases/download/{TAG}"

# Stands in for elan-init, which installs elan into ~/.elan.
INIT = """#!/bin/sh
echo "elan-init $*" >>"$FAKE_CALLS"
mkdir -p "$HOME/.elan/bin"
printf '#!/bin/sh\\necho elan 4.2.4\\n' >"$HOME/.elan/bin/elan"
chmod +x "$HOME/.elan/bin/elan"
"""


class ElanTest(StepCase):
    def test_install(self) -> None:
        self.serve(f"{BASE}/elan-aarch64-apple-darwin.tar.gz", self.tarball({"elan-init": INIT}))
        self.assertTrue(self.run_step(STEPS["install_elan"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), f"[install] Installing elan {TAG}\n")
        self.assertEqual(self.called(), ["elan-init -y --no-modify-path"])

    def test_no_installer_in_the_tarball(self) -> None:
        self.serve(f"{BASE}/elan-x86_64-unknown-linux-gnu.tar.gz", self.tarball({"README": "x"}))
        self.assertFalse(self.run_step(STEPS["install_elan"]))
        self.assertIn(
            "ERROR: No elan-init inside elan-x86_64-unknown-linux-gnu.tar.gz;"
            " upstream layout changed\n",
            self.said(),
        )

    def test_present_off_path_is_skipped(self) -> None:
        self.fake("elan", prints("elan 4.2.4"), self.home / ".elan/bin")
        self.assertTrue(self.run_step(STEPS["install_elan"]))
        self.assertEqual(self.said(), "[install] elan already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_upgrade_retries_once(self) -> None:
        # The first `self update` fails, as one dropped download makes it.
        elan = self.fake(
            "elan",
            '#!/bin/sh\necho "elan $*" >>"$FAKE_CALLS"\n'
            '[ "$1" != self ] && exit 0\n'
            '[ -e "$HOME/tried" ] && exit 0\n'
            'touch "$HOME/tried"\nexit 1\n',
            self.home / ".elan/bin",
        )
        self.assertTrue(self.run_step(STEPS["install_elan"], upgrade=True))
        self.assertEqual(
            self.said(), f"[install] Upgrading elan\n[install] {elan} failed; retrying once\n"
        )
        self.assertEqual(self.called(), ["elan self update", "elan self update", "elan --version"])

    def test_unsupported_platform(self) -> None:
        self.assertTrue(self.run_step(STEPS["install_elan"], machine="riscv64"))
        self.assertEqual(
            self.said(),
            "[install] Unsupported platform Linux/riscv64 for elan install; skipping\n",
        )
