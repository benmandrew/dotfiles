from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer.steps import STEPS, ghostty

from .support import StepCase


class GhosttyTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.snap_bin = Path(self.scratch) / "snap-bin"
        self.app_bin = Path(self.scratch) / "Ghostty.app" / "Contents" / "MacOS"
        for name, path in (("SNAP_BIN", self.snap_bin), ("APP_BIN", self.app_bin / "ghostty")):
            patch = mock.patch.object(ghostty, name, path)
            patch.start()
            self.addCleanup(patch.stop)

    def run_linux(self, *, upgrade: bool = False) -> bool:
        self.env["WAYLAND_DISPLAY"] = "wayland-0"
        return self.run_step(STEPS["install_ghostty"], upgrade=upgrade)

    def test_headless_linux(self) -> None:
        self.assertTrue(self.run_step(STEPS["install_ghostty"]))
        self.assertEqual(
            self.said(),
            "[install] Ghostty: no display session detected; skipping on headless Linux\n",
        )

    def test_linux_installs_the_classic_snap(self) -> None:
        self.installer("snap", creates="ghostty", into=self.snap_bin)
        self.assertTrue(self.run_linux())
        self.assertEqual(self.said(), "[install] Installing Ghostty\n")
        self.assertEqual(self.called(), ["snap install ghostty --classic"])

    def test_linux_present(self) -> None:
        self.recording("snap")
        self.fake("ghostty", "#!/bin/sh\n", directory=self.snap_bin)
        self.assertTrue(self.run_linux())
        self.assertEqual(self.said(), "[install] Ghostty already installed; skipping\n")
        self.assertEqual(self.called(), [])

    def test_linux_upgrade_refreshes_the_snap(self) -> None:
        self.recording("snap")
        self.fake("ghostty", "#!/bin/sh\n", directory=self.snap_bin)
        self.assertTrue(self.run_linux(upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading Ghostty\n")
        self.assertEqual(self.called(), ["snap refresh ghostty"])

    def test_linux_leaves_a_ghostty_from_elsewhere(self) -> None:
        self.recording("snap")
        self.fake("ghostty", "#!/bin/sh\n")
        self.assertTrue(self.run_linux(upgrade=True))
        self.assertEqual(self.said(), "[install] Ghostty installed outside snap; skipping\n")
        self.assertEqual(self.called(), [])

    def test_linux_without_snapd(self) -> None:
        self.assertTrue(self.run_linux())
        self.assertEqual(self.said(), "[install] Ghostty: snapd not installed; skipping\n")

    def test_linux_snap_that_leaves_nothing_runnable(self) -> None:
        self.recording("snap")
        self.assertFalse(self.run_linux())

    def test_macos(self) -> None:
        self.installer("brew", creates="ghostty", into=self.app_bin)
        self.assertTrue(self.run_step(STEPS["install_ghostty"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] Installing Ghostty\n")
        self.assertEqual(self.called(), ["brew install --cask ghostty"])

    def test_macos_upgrade(self) -> None:
        self.fake("ghostty", "#!/bin/sh\n", directory=self.app_bin)
        self.recording("brew")
        self.assertTrue(
            self.run_step(STEPS["install_ghostty"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(self.said(), "[install] Upgrading Ghostty\n")
        self.assertEqual(self.called(), ["brew upgrade --cask ghostty"])

    def test_macos_ignores_a_ghostty_on_path(self) -> None:
        # The cask links no binary, so a ghostty on PATH says nothing about the app.
        self.fake("ghostty", "#!/bin/sh\n")
        self.installer("brew", creates="ghostty", into=self.app_bin)
        self.assertTrue(self.run_step(STEPS["install_ghostty"], system="Darwin", machine="arm64"))
        self.assertEqual(self.called(), ["brew install --cask ghostty"])
