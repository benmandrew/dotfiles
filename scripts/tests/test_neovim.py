from __future__ import annotations

import json
from pathlib import Path
from unittest import mock

from installer import pins
from installer.steps import STEPS, neovim

from .support import StepCase, prints, sha256

TAG = pins.pin("NEOVIM_VERSION")
API = "https://api.github.com/repos/neovim/neovim/releases"

# The tests cannot give a tree to root.
SUDO = '#!/bin/sh\n[ "$1" = -A ] && shift\n[ "$1" = chown ] && exit 0\nexec "$@"\n'


class NeovimTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.opt = Path(self.scratch) / "opt"
        self.opt.mkdir()
        patch = mock.patch.object(neovim, "OPT", self.opt)
        patch.start()
        self.addCleanup(patch.stop)
        self.fake("sudo", SUDO)
        self.nvim = self.opt / "nvim-linux-arm64/bin/nvim"

    def serve_release(self, tag: str = TAG, digest: str = "") -> None:
        name = "nvim-linux-arm64"
        tarball = self.tarball(
            {f"{name}/bin/nvim": prints(f"NVIM {tag}"), f"{name}/share/runtime.vim": "x"}
        )
        self.serve(
            f"https://github.com/neovim/neovim/releases/download/{tag}/{name}.tar.gz", tarball
        )
        asset = {"name": f"{name}.tar.gz", "digest": f"sha256:{digest or sha256(tarball)}"}
        self.serve(f"{API}/tags/{tag}", json.dumps({"tag_name": tag, "assets": [asset]}))

    def run_neovim(self, upgrade: bool = False) -> bool:
        return self.run_step(STEPS["install_neovim_if_missing"], machine="aarch64", upgrade=upgrade)

    def test_install(self) -> None:
        self.serve_release()
        self.assertTrue(self.run_neovim())
        self.assertEqual(self.said(), f"[install] Installing Neovim {TAG}\n")
        self.assertIn(TAG, self.nvim.read_text())

    def test_wrong_digest_leaves_the_old_tree(self) -> None:
        self.fake("nvim", prints("NVIM v0.9.5"), self.nvim.parent)
        self.serve_release(digest="a" * 64)
        self.assertFalse(self.run_neovim())
        said = self.said()
        self.assertIn(f"[install] Neovim v0.9.5 < 0.12.0; installing {TAG}\n", said)
        self.assertIn("ERROR: Checksum mismatch for nvim-linux-arm64.tar.gz", said)
        self.assertIn("v0.9.5", self.nvim.read_text())

    def test_an_old_tree_is_replaced(self) -> None:
        self.fake("nvim", prints("NVIM v0.9.5"), self.nvim.parent)
        (self.nvim.parent / "stale").write_text("from 0.9.5")
        self.serve_release()
        self.assertTrue(self.run_neovim())
        self.assertFalse((self.nvim.parent / "stale").exists())
        self.assertIn(TAG, self.nvim.read_text())

    def test_new_enough_is_skipped(self) -> None:
        # A nightly, whose suffix is not part of the version compared.
        self.fake("nvim", prints("NVIM v0.13.0-dev-123+gabcdef\nBuild type: Release"))
        self.assertTrue(self.run_neovim())
        self.assertEqual(
            self.said(), "[install] Neovim v0.13.0-dev-123+gabcdef already installed; skipping\n"
        )
        self.assertEqual(self.requests(), [])

    def test_upgrade(self) -> None:
        self.fake("nvim", prints(f"NVIM {TAG}"), self.nvim.parent)
        self.serve(f"{API}/latest", f'{{"tag_name":"{TAG}"}}')
        self.assertTrue(self.run_neovim(upgrade=True))
        self.assertEqual(self.said(), f"[install] Neovim {TAG} already at latest; skipping\n")

        self.serve(f"{API}/latest", '{"tag_name":"v0.99.0"}')
        self.serve_release("v0.99.0")
        self.assertTrue(self.run_neovim(upgrade=True))
        self.assertIn(f"[install] Upgrading Neovim {TAG} to v0.99.0\n", self.said())
        self.assertIn("v0.99.0", self.nvim.read_text())

    def test_homebrew_on_macos(self) -> None:
        def run(upgrade: bool = False) -> bool:
            step = STEPS["install_neovim_if_missing"]
            return self.run_step(step, system="Darwin", machine="arm64", upgrade=upgrade)

        self.recording("brew", failing="list")
        self.assertTrue(run())
        self.recording("brew")
        self.assertTrue(run())
        self.assertTrue(run(upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Installing Neovim\n"
            "[install] Neovim already installed; skipping\n"
            "[install] Upgrading Neovim\n",
        )
        self.assertEqual(self.called()[1], "brew install neovim")
        self.assertEqual(self.called()[-1], "brew upgrade neovim")
