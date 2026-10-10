from __future__ import annotations

import os

from installer import pins
from installer.steps import PORTED

from .support import StepCase, prints

NAME = "lua-language-server"
TAG = pins.pin("LUA_LS_VERSION")
BASE = "https://github.com/LuaLS/lua-language-server/releases/download"


class LuaLsTest(StepCase):
    def serve_release(self, tag: str, arch: str = "linux-x64") -> None:
        files = {f"bin/{NAME}": prints(tag), "main.lua": "-- lua"}
        self.serve(f"{BASE}/{tag}/{NAME}-{tag}-{arch}.tar.gz", self.tarball(files))

    def test_install_on_linux(self) -> None:
        self.serve_release(TAG, "linux-arm64")
        self.assertTrue(self.run_step(PORTED["install_lua_ls"], machine="aarch64"))
        self.assertEqual(self.said(), f"[install] Installing {NAME}\n")
        tree = self.home / ".local/opt" / NAME
        link = self.home / ".local/bin" / NAME
        self.assertEqual(os.readlink(link), str(tree / "bin" / NAME))
        self.assertTrue((tree / "main.lua").is_file())
        self.assertEqual(sorted(path.name for path in tree.parent.iterdir()), [NAME])

    def test_upgrade_swaps_the_tree(self) -> None:
        self.env["PATH"] = f"{self.home}/.local/bin:{self.env['PATH']}"
        self.serve_release(TAG)
        self.assertTrue(self.run_step(PORTED["install_lua_ls"]))
        tree = self.home / ".local/opt" / NAME
        (tree / "stale").write_text("from the old release")

        latest = "https://api.github.com/repos/LuaLS/lua-language-server/releases/latest"
        self.serve(latest, f'{{"tag_name":"{TAG}"}}')
        self.assertTrue(self.run_step(PORTED["install_lua_ls"], upgrade=True))
        self.assertIn(f"[install] {NAME} {TAG} already at latest; skipping\n", self.said())
        self.assertTrue((tree / "stale").exists())

        self.serve(latest, '{"tag_name":"9.9.9"}')
        self.serve_release("9.9.9")
        self.assertTrue(self.run_step(PORTED["install_lua_ls"], upgrade=True))
        self.assertFalse((tree / "stale").exists())
        self.assertIn("9.9.9", (tree / "bin" / NAME).read_text())
        self.assertEqual(sorted(path.name for path in tree.parent.iterdir()), [NAME])

    def test_present_is_skipped(self) -> None:
        self.fake(NAME, prints(TAG))
        self.assertTrue(self.run_step(PORTED["install_lua_ls"]))
        self.assertEqual(self.said(), f"[install] {NAME} already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_macos(self) -> None:
        self.recording("brew")
        self.assertFalse(self.run_step(PORTED["install_lua_ls"], system="Darwin", machine="arm64"))
        self.fake(NAME, prints(TAG))
        self.assertTrue(
            self.run_step(PORTED["install_lua_ls"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(self.called(), [f"brew install {NAME}", f"brew upgrade {NAME}"])
