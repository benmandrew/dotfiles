from __future__ import annotations

from installer import pins
from installer.steps import STEPS

from .support import StepCase, sha256

STEP = STEPS["install_terminal_font"]
NAME = "Iosevka Term Slab"
TAG = pins.pin("IOSEVKA_VERSION")
BASE = "https://github.com/be5invis/Iosevka/releases/download"
LATEST = "https://api.github.com/repos/be5invis/Iosevka/releases/latest"
FACES = (
    "IosevkaTermSlab-SemiBold.ttf IosevkaTermSlab-SemiBoldItalic.ttf"
    " IosevkaTermSlab-Heavy.ttf IosevkaTermSlab-HeavyItalic.ttf"
    " IosevkaTermSlab-Light.ttf IosevkaTermSlab-LightItalic.ttf"
)

# Stands in for unzip: `unzip -joq <archive> <pattern>... -d <directory>`. It
# writes each pattern's basename, holding the archive's text, into the
# directory, and records the patterns.
UNZIP = """#!/bin/sh
archive="$2"
shift 2
patterns=""
while [ "$1" != "-d" ]; do patterns="$patterns ${1##*/}"; shift; done
echo "unzip$patterns" >>"$FAKE_CALLS"
for name in $patterns; do cp "$archive" "$2/$name"; done
"""


class TerminalFontTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.env["DISPLAY"] = ":0"
        self.fake("unzip", UNZIP)
        self.fonts = self.home / ".local/share/fonts/IosevkaTermSlab"

    def serve_release(self, tag: str = TAG) -> None:
        asset = f"PkgTTF-Unhinted-IosevkaTermSlab-{tag.removeprefix('v')}.zip"
        self.serve(f"{BASE}/{tag}/{asset}", f"iosevka {tag}")
        digest = sha256(f"iosevka {tag}".encode())
        self.serve(f"{BASE}/{tag}/SHA-256.txt", f"{'0' * 64}  Other.zip\n{digest}  {asset}\n")

    def test_headless_linux_is_skipped(self) -> None:
        del self.env["DISPLAY"]
        self.assertTrue(self.run_step(STEP))
        self.assertEqual(
            self.said(),
            f"[install] {NAME}: no display session detected; skipping on headless Linux\n",
        )

    def test_install_then_skip(self) -> None:
        self.serve_release()
        self.assertTrue(self.run_step(STEP))
        self.assertEqual(
            (self.fonts / "IosevkaTermSlab-SemiBold.ttf").read_text(), f"iosevka {TAG}"
        )
        self.assertEqual((self.fonts / ".version").read_text(), f"{TAG}\n")
        self.assertEqual(self.called(), [f"unzip {FACES}"])

        requests = len(self.requests())
        self.assertTrue(self.run_step(STEP))
        self.assertEqual(
            self.said(),
            f"[install] Installing {NAME}\n[install] {NAME} already installed; skipping\n",
        )
        self.assertEqual(len(self.requests()), requests)

    def test_a_bad_checksum_fails(self) -> None:
        self.serve_release()
        asset = f"PkgTTF-Unhinted-IosevkaTermSlab-{TAG.removeprefix('v')}.zip"
        self.serve(f"{BASE}/{TAG}/{asset}", "tampered")
        self.assertFalse(self.run_step(STEP))
        self.assertFalse((self.fonts / ".version").exists())

    def test_upgrade(self) -> None:
        self.fonts.mkdir(parents=True)
        (self.fonts / ".version").write_text(f"{TAG}\n")
        self.serve(LATEST, f'{{"tag_name":"{TAG}"}}')
        self.assertTrue(self.run_step(STEP, upgrade=True))
        self.assertEqual(
            self.said(),
            f"[install] Upgrading {NAME}\n[install] {NAME} {TAG} already at latest; skipping\n",
        )

        self.serve(LATEST, '{"tag_name":"v99.0.0"}')
        self.serve_release("v99.0.0")
        self.assertTrue(self.run_step(STEP, upgrade=True))
        self.assertEqual((self.fonts / ".version").read_text(), "v99.0.0\n")

    def test_no_unzip(self) -> None:
        (self.bin / "unzip").unlink()
        self.env["PATH"] = str(self.bin)
        self.assertFalse(self.run_step(STEP))
        self.assertIn("ERROR: Missing required command: unzip\n", self.said())

    def test_release_zip_on_macos(self) -> None:
        self.serve_release()
        self.assertTrue(self.run_step(STEP, system="Darwin", machine="arm64"))
        fonts = self.home / "Library/Fonts/IosevkaTermSlab"
        self.assertEqual((fonts / ".version").read_text(), f"{TAG}\n")
        self.assertEqual(self.called(), [f"unzip {FACES}"])
