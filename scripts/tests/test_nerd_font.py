from __future__ import annotations

from installer import pins
from installer.steps import PORTED

from .support import StepCase, sha256

NAME = "CodeNewRoman Nerd Font"
TAG = pins.pin("NERD_FONTS_VERSION")
BASE = "https://github.com/ryanoasis/nerd-fonts/releases/download"
LATEST = "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest"

# Stands in for unzip: `unzip -oq <archive> -d <directory>`.
UNZIP = '#!/bin/sh\necho "unzip $1 $3" >>"$FAKE_CALLS"\ncp "$2" "$4/Font.ttf"\n'


class NerdFontTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.env["DISPLAY"] = ":0"
        self.fake("unzip", UNZIP)
        self.fonts = self.home / ".local/share/fonts/CodeNewRomanNerdFont"

    def serve_release(self, tag: str = TAG) -> None:
        self.serve(f"{BASE}/{tag}/CodeNewRoman.zip", f"fonts {tag}")
        digest = sha256(f"fonts {tag}".encode())
        self.serve(
            f"{BASE}/{tag}/SHA-256.txt", f"{'0' * 64}  Other.zip\n{digest}  CodeNewRoman.zip\n"
        )

    def test_headless_linux_is_skipped(self) -> None:
        del self.env["DISPLAY"]
        self.assertTrue(self.run_step(PORTED["install_nerd_font"]))
        self.assertEqual(
            self.said(),
            f"[install] {NAME}: no display session detected; skipping on headless Linux\n",
        )
        self.env["WAYLAND_DISPLAY"] = "wayland-0"
        self.serve_release()
        self.assertTrue(self.run_step(PORTED["install_nerd_font"]))
        self.assertIn(f"[install] Installing {NAME}\n", self.said())

    def test_install_then_skip(self) -> None:
        self.serve_release()
        self.assertTrue(self.run_step(PORTED["install_nerd_font"]))
        self.assertEqual((self.fonts / "Font.ttf").read_text(), f"fonts {TAG}")
        self.assertEqual((self.fonts / ".version").read_text(), f"{TAG}\n")
        self.assertEqual(self.called(), ["unzip -oq -d"])

        requests = len(self.requests())
        self.assertTrue(self.run_step(PORTED["install_nerd_font"]))
        self.assertEqual(
            self.said(),
            f"[install] Installing {NAME}\n[install] {NAME} already installed; skipping\n",
        )
        self.assertEqual(len(self.requests()), requests)

    def test_an_interrupted_extract_is_redone(self) -> None:
        self.fonts.mkdir(parents=True)
        (self.fonts / "Half.ttf").write_text("partial")
        self.serve_release()
        self.assertTrue(self.run_step(PORTED["install_nerd_font"]))
        self.assertEqual(self.said(), f"[install] Installing {NAME}\n")

    def test_upgrade(self) -> None:
        self.fonts.mkdir(parents=True)
        (self.fonts / ".version").write_text(f"{TAG}\n")
        self.serve(LATEST, f'{{"tag_name":"{TAG}"}}')
        self.assertTrue(self.run_step(PORTED["install_nerd_font"], upgrade=True))
        self.assertEqual(
            self.said(),
            f"[install] Upgrading {NAME}\n[install] {NAME} {TAG} already at latest; skipping\n",
        )

        self.serve(LATEST, '{"tag_name":"v9.9.9"}')
        self.serve_release("v9.9.9")
        self.assertTrue(self.run_step(PORTED["install_nerd_font"], upgrade=True))
        self.assertEqual((self.fonts / ".version").read_text(), "v9.9.9\n")

    def test_no_unzip(self) -> None:
        (self.bin / "unzip").unlink()
        self.env["PATH"] = str(self.bin)
        self.assertFalse(self.run_step(PORTED["install_nerd_font"]))
        self.assertIn("ERROR: Missing required command: unzip\n", self.said())

    def test_cask_on_macos(self) -> None:
        cask = "font-code-new-roman-nerd-font"
        self.recording("brew", failing="list")
        self.assertTrue(
            self.run_step(PORTED["install_nerd_font"], system="Darwin", machine="arm64")
        )
        self.recording("brew")
        self.assertTrue(
            self.run_step(PORTED["install_nerd_font"], system="Darwin", machine="arm64")
        )
        self.assertTrue(
            self.run_step(
                PORTED["install_nerd_font"], system="Darwin", machine="arm64", upgrade=True
            )
        )
        self.assertEqual(
            self.called(),
            [
                f"brew list --cask {cask}",
                f"brew install --cask {cask}",
                f"brew list --cask {cask}",
                f"brew list --cask {cask}",
                f"brew upgrade --cask {cask}",
            ],
        )
