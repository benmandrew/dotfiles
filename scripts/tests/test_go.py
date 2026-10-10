from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import pins
from installer.steps import PORTED, go

from .support import StepCase, sha256

PIN = pins.pin("GO_VERSION")


def fake_go(version: str) -> str:
    """A `go` that reports `version` and records the toolchain setting it ran under."""
    return (
        f'#!/bin/sh\necho "go $* GOTOOLCHAIN=$GOTOOLCHAIN" >>"$FAKE_CALLS"\n'
        f"echo 'go version {version} linux/arm64'\n"
    )


class GoTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.root = Path(self.scratch) / "usr-local" / "go"
        self.root.parent.mkdir()
        patch = mock.patch.object(go, "GO_ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)

    def serve_release(self, version: str = PIN, digest: str = "") -> None:
        name = f"{version}.linux-arm64.tar.gz"
        tarball = self.tarball({"go/bin/go": fake_go(version), "go/VERSION": version})
        self.serve(f"https://go.dev/dl/{name}", tarball)
        self.serve(f"https://dl.google.com/go/{name}.sha256", digest or sha256(tarball))

    def run_go(self, upgrade: bool = False) -> bool:
        return self.run_step(PORTED["install_go"], machine="aarch64", upgrade=upgrade)

    def test_install(self) -> None:
        self.serve_release()
        self.assertTrue(self.run_go())
        self.assertEqual(self.said(), "[install] Installing Go\n")
        self.assertEqual((self.root / "VERSION").read_text(), PIN)
        self.assertFalse(self.root.with_name("go.old").exists())
        # The steps that follow find the new toolchain first.
        self.assertTrue(self.env["PATH"].startswith(f"{self.root}/bin:"))
        self.assertEqual(self.called(), ["go version GOTOOLCHAIN=local"])

    def test_an_old_distro_go_is_superseded(self) -> None:
        self.fake("go", fake_go("go1.18.1"))
        self.serve_release()
        self.assertTrue(self.run_go())
        self.assertEqual(self.said(), "[install] Go 1.18 < 1.21; upgrading to latest stable\n")
        self.assertEqual(self.called()[0], "go version GOTOOLCHAIN=local")
        self.assertTrue((self.root / "bin/go").is_file())

    def test_new_enough_is_skipped(self) -> None:
        self.fake("go", fake_go("go1.27.1"), self.root / "bin")
        self.assertTrue(self.run_go())
        self.assertEqual(self.said(), "[install] Go 1.27 already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_the_old_tree_is_swapped_out(self) -> None:
        self.fake("go", fake_go("go1.18.1"), self.root / "bin")
        (self.root / "stale").write_text("from 1.18")
        self.serve_release()
        self.assertTrue(self.run_go())
        self.assertFalse((self.root / "stale").exists())
        self.assertFalse(self.root.with_name("go.old").exists())

    def test_wrong_checksum_leaves_the_old_tree(self) -> None:
        self.fake("go", fake_go("go1.18.1"), self.root / "bin")
        self.serve_release(digest="a" * 64)
        self.assertFalse(self.run_go())
        self.assertIn(f"ERROR: Checksum mismatch for {PIN}.linux-arm64.tar.gz", self.said())
        self.assertIn("go1.18.1", (self.root / "bin/go").read_text())

    def test_upgrade(self) -> None:
        self.fake("go", fake_go("go1.99.9"), self.root / "bin")
        self.serve("https://go.dev/VERSION?m=text", "go1.99.9\ntime 2026-01-01T00:00:00Z\n")
        self.assertTrue(self.run_go(upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Upgrading Go\n[install] Go go1.99.9 already at latest; skipping\n",
        )

        self.serve("https://go.dev/VERSION?m=text", "go1.99.10\n")
        self.serve_release("go1.99.10")
        self.assertTrue(self.run_go(upgrade=True))
        self.assertEqual((self.root / "VERSION").read_text(), "go1.99.10")

    def test_a_distro_go_at_the_latest_version_does_not_count(self) -> None:
        self.fake("go", fake_go("go1.99.9"))
        self.serve("https://go.dev/VERSION?m=text", "go1.99.9\n")
        self.serve_release("go1.99.9")
        self.assertTrue(self.run_go(upgrade=True))
        self.assertTrue((self.root / "bin/go").is_file())

    def test_upgrade_without_go_dev(self) -> None:
        self.assertFalse(self.run_go(upgrade=True))
        self.assertIn("ERROR: Could not read the current Go release from go.dev\n", self.said())
        self.serve("https://go.dev/VERSION?m=text", "\n")
        self.assertFalse(self.run_go(upgrade=True))
        self.assertIn("ERROR: go.dev returned no version\n", self.said())

    def test_unsupported_arch(self) -> None:
        self.assertTrue(self.run_step(PORTED["install_go"], machine="riscv64"))
        self.assertEqual(
            self.said(),
            "[install] Installing Go\n"
            "[install] Unsupported arch riscv64 for Go install; skipping\n",
        )
