from __future__ import annotations

from installer import pins
from installer.steps import STEPS

from .support import StepCase, sha256

STEP = STEPS["install_site_fonts"]
LIBERTINUS = pins.pin("LIBERTINUS_VERSION")
IOSEVKA = pins.pin("IOSEVKA_VERSION")
LIBERTINUS_BASE = "https://github.com/alerque/libertinus/releases/download"
IOSEVKA_BASE = "https://github.com/be5invis/Iosevka/releases/download"
IOSEVKA_LATEST = "https://api.github.com/repos/be5invis/Iosevka/releases/latest"

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


class SiteFontsTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.env["DISPLAY"] = ":0"
        self.fake("unzip", UNZIP)
        self.fonts = self.home / ".local/share/fonts"

    def serve_libertinus(self) -> None:
        version = LIBERTINUS.removeprefix("v")
        self.serve(f"{LIBERTINUS_BASE}/{LIBERTINUS}/Libertinus-{version}.zip", "libertinus")

    def serve_iosevka(self, tag: str = IOSEVKA) -> None:
        asset = f"PkgTTF-Unhinted-IosevkaSlab-{tag.removeprefix('v')}.zip"
        self.serve(f"{IOSEVKA_BASE}/{tag}/{asset}", f"iosevka {tag}")
        digest = sha256(f"iosevka {tag}".encode())
        manifest = f"{'0' * 64}  Other.zip\n{digest}  {asset}\n"
        self.serve(f"{IOSEVKA_BASE}/{tag}/SHA-256.txt", manifest)

    def test_headless_linux_is_skipped(self) -> None:
        del self.env["DISPLAY"]
        self.assertTrue(self.run_step(STEP))
        self.assertEqual(
            self.said(),
            "[install] Site fonts: no display session detected; skipping on headless Linux\n",
        )

    def test_install_then_skip(self) -> None:
        self.serve_libertinus()
        self.serve_iosevka()
        self.assertTrue(self.run_step(STEP))
        self.assertEqual(
            (self.fonts / "Libertinus/LibertinusSerif-BoldItalic.ttf").read_text(), "libertinus"
        )
        self.assertEqual(
            (self.fonts / "IosevkaSlab/IosevkaSlab-Extended.ttf").read_text(), f"iosevka {IOSEVKA}"
        )
        self.assertEqual((self.fonts / "Libertinus/.version").read_text(), f"{LIBERTINUS}\n")
        self.assertEqual((self.fonts / "IosevkaSlab/.version").read_text(), f"{IOSEVKA}\n")
        self.assertEqual(
            self.called(),
            [
                "unzip LibertinusSerif-Regular.ttf LibertinusSerif-Italic.ttf"
                " LibertinusSerif-Bold.ttf LibertinusSerif-BoldItalic.ttf",
                "unzip IosevkaSlab-Extended.ttf IosevkaSlab-ExtendedItalic.ttf"
                " IosevkaSlab-ExtendedBold.ttf IosevkaSlab-ExtendedBoldItalic.ttf",
            ],
        )

        requests = len(self.requests())
        self.assertTrue(self.run_step(STEP))
        self.assertEqual(
            self.said(),
            "[install] Installing Libertinus Serif\n"
            "[install] Installing Iosevka Slab\n"
            "[install] Libertinus Serif already installed; skipping\n"
            "[install] Iosevka Slab already installed; skipping\n",
        )
        self.assertEqual(len(self.requests()), requests)

    def test_a_bad_checksum_fails(self) -> None:
        self.serve_libertinus()
        self.serve_iosevka()
        asset = f"PkgTTF-Unhinted-IosevkaSlab-{IOSEVKA.removeprefix('v')}.zip"
        self.serve(f"{IOSEVKA_BASE}/{IOSEVKA}/{asset}", "tampered")
        self.assertFalse(self.run_step(STEP))
        self.assertFalse((self.fonts / "IosevkaSlab/.version").exists())

    def test_upgrade(self) -> None:
        for directory, tag in (("Libertinus", LIBERTINUS), ("IosevkaSlab", IOSEVKA)):
            (self.fonts / directory).mkdir(parents=True)
            (self.fonts / directory / ".version").write_text(f"{tag}\n")
        self.serve(
            "https://api.github.com/repos/alerque/libertinus/releases/latest",
            f'{{"tag_name":"{LIBERTINUS}"}}',
        )
        self.serve(IOSEVKA_LATEST, '{"tag_name":"v99.0.0"}')
        self.serve_iosevka("v99.0.0")
        self.assertTrue(self.run_step(STEP, upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Upgrading Libertinus Serif\n"
            f"[install] Libertinus Serif {LIBERTINUS} already at latest; skipping\n"
            "[install] Upgrading Iosevka Slab\n",
        )
        self.assertEqual((self.fonts / "IosevkaSlab/.version").read_text(), "v99.0.0\n")

    def test_no_unzip(self) -> None:
        (self.bin / "unzip").unlink()
        self.env["PATH"] = str(self.bin)
        self.assertFalse(self.run_step(STEP))
        self.assertIn("ERROR: Missing required command: unzip\n", self.said())

    def test_casks_on_macos(self) -> None:
        self.recording("brew", failing="list")
        self.assertTrue(self.run_step(STEP, system="Darwin", machine="arm64"))
        self.assertEqual(
            self.called(),
            [
                "brew list --cask font-libertinus",
                "brew install --cask font-libertinus",
                "brew list --cask font-iosevka-slab",
                "brew install --cask font-iosevka-slab",
            ],
        )
