from __future__ import annotations

from installer import pins
from installer.steps import STEPS

from .support import StepCase, prints, sha256

TAG = pins.pin("ATUIN_VERSION")
VERSION = TAG.removeprefix("v")
TRIPLE = "aarch64-unknown-linux-musl"
BASE = "https://github.com/atuinsh/atuin/releases/download"
LATEST = "https://api.github.com/repos/atuinsh/atuin/releases/latest"


class AtuinTest(StepCase):
    def serve_release(self, tag: str = TAG) -> None:
        asset = f"atuin-{TRIPLE}.tar.gz"
        version = tag.removeprefix("v")
        tarball = self.tarball({f"atuin-{TRIPLE}/atuin": prints(f"atuin {version} ()")})
        self.serve(f"{BASE}/{tag}/{asset}", tarball)
        self.serve(f"{BASE}/{tag}/{asset}.sha256", f"{sha256(tarball)}  {asset}\n")

    def run_atuin(self, upgrade: bool = False) -> bool:
        return self.run_step(STEPS["install_atuin"], machine="aarch64", upgrade=upgrade)

    def test_install(self) -> None:
        self.serve_release()
        self.assertTrue(self.run_atuin())
        self.assertEqual(self.said(), f"[install] Installing atuin {VERSION}\n")
        self.assertIn(VERSION, (self.home / ".local/bin/atuin").read_text())

    def test_present_costs_no_request(self) -> None:
        self.fake("atuin", prints(f"atuin {VERSION} ()"))
        self.assertTrue(self.run_atuin())
        self.assertEqual(self.said(), "[install] atuin already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_a_broken_copy_is_replaced(self) -> None:
        self.fake("atuin", "#!/bin/sh\necho 'GLIBC_2.38 not found' >&2\nexit 1\n")
        self.serve_release()
        self.assertTrue(self.run_atuin())
        self.assertIn(
            f"[install] atuin present but not runnable; reinstalling {VERSION}\n", self.said()
        )
        self.assertTrue((self.home / ".local/bin/atuin").is_file())

    def test_upgrade(self) -> None:
        # The version is the second word, and a commit hash may follow it.
        self.fake("atuin", prints(f"atuin {VERSION} (abc1234)"))
        self.serve(LATEST, f'{{"tag_name":"{TAG}"}}')
        self.assertTrue(self.run_atuin(upgrade=True))
        self.assertEqual(self.said(), f"[install] atuin {VERSION} already at latest; skipping\n")

        self.serve(LATEST, '{"tag_name":"v99.0.0"}')
        self.serve_release("v99.0.0")
        self.assertTrue(self.run_atuin(upgrade=True))
        self.assertIn("[install] Upgrading atuin to 99.0.0\n", self.said())
        self.assertIn("99.0.0", (self.home / ".local/bin/atuin").read_text())

    def test_unsupported_arch(self) -> None:
        self.assertTrue(self.run_step(STEPS["install_atuin"], machine="riscv64"))
        self.assertIn(
            "[install] Unsupported arch riscv64 for atuin install; skipping\n", self.said()
        )

    def test_homebrew_on_macos(self) -> None:
        self.recording("brew", failing="list")
        self.fake("atuin", prints("atuin 18.21.0"))
        self.assertTrue(self.run_step(STEPS["install_atuin"], system="Darwin", machine="arm64"))
        self.assertEqual(self.called(), ["brew list --formula atuin", "brew install atuin"])
