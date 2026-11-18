from __future__ import annotations

from installer.steps import STEPS, zathura

from .support import StepCase

# A brew whose answers come from files under $HOME: `formulae` lists what is
# installed, `tapped` and `trusted` exist once the tap is.
BREW = """#!/bin/sh
case "$*" in
    tap) [ -e "$HOME/tapped" ] && echo homebrew-zathura/zathura; exit 0 ;;
    "trust --json v1")
        if [ -e "$HOME/trusted" ]; then echo '{"taps": ["homebrew-zathura/zathura"]}'
        else echo '{"taps": []}'; fi
        exit 0 ;;
    "list --formula "*) grep -qx "$3" "$HOME/formulae" 2>/dev/null; exit ;;
    "--prefix "*) echo "$HOME/opt/$2"; exit 0 ;;
esac
echo "brew $*" >>"$FAKE_CALLS"
case "$1" in install) echo "$2" >>"$HOME/formulae" ;; esac
[ "$*" != "$FAKE_BREW_FAILS" ]
"""
HINT = (
    "[install] zathura on macOS is a command-line tool. To also get a /Applications bundle\n"
    "[install]   that opens PDFs on double-click, run the tap's convert-into-app.sh:\n"
    "[install]   https://github.com/homebrew-zathura/homebrew-zathura\n"
)


class ZathuraMacosTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake("brew", BREW)
        self.fake("zathura", "#!/bin/sh\n")
        self.plugin = self.home / "opt/zathura-pdf-poppler/libpdf-poppler.dylib"
        self.plugin.parent.mkdir(parents=True)
        self.plugin.touch()

    def mac(self, upgrade: bool = False) -> bool:
        return self.run_step(
            STEPS["install_zathura"], system="Darwin", machine="arm64", upgrade=upgrade
        )

    def test_install(self) -> None:
        self.assertTrue(self.mac())
        self.assertEqual(
            self.said(),
            "[install] Tapping homebrew-zathura/zathura\n"
            "[install] Trusting tap homebrew-zathura/zathura\n"
            "[install] Installing zathura\n"
            "[install] Installing zathura-pdf-poppler\n" + HINT,
        )
        self.assertEqual(
            self.called(),
            [
                "brew tap homebrew-zathura/zathura",
                "brew trust --tap homebrew-zathura/zathura",
                "brew install zathura --with-synctex",
                "brew install zathura-pdf-poppler",
            ],
        )
        link = self.home / "opt/zathura/lib/zathura/libpdf-poppler.dylib"
        self.assertEqual(link.resolve(), self.plugin.resolve())

    def test_present_and_upgrade(self) -> None:
        for name in ("tapped", "trusted"):
            (self.home / name).touch()
        (self.home / "formulae").write_text("zathura\nzathura-pdf-poppler\n")
        self.assertTrue(self.mac())
        self.assertEqual(self.said(), "[install] zathura already installed; skipping\n" + HINT)
        self.assertEqual(self.called(), [])
        self.assertTrue(self.mac(upgrade=True))
        self.assertEqual(
            self.called(),
            ["brew upgrade zathura --with-synctex", "brew upgrade zathura-pdf-poppler"],
        )

    def test_a_viewer_without_its_backend_gets_one(self) -> None:
        for name in ("tapped", "trusted"):
            (self.home / name).touch()
        (self.home / "formulae").write_text("zathura\n")
        self.assertTrue(self.mac())
        self.assertEqual(self.called(), ["brew install zathura-pdf-poppler"])

    def test_an_untrusted_tap_that_stays_untrusted(self) -> None:
        self.env["FAKE_BREW_FAILS"] = "trust --tap homebrew-zathura/zathura"
        self.assertFalse(self.mac())
        self.assertEqual(len(self.called()), 2)

    def test_a_backend_without_the_plugin(self) -> None:
        self.plugin.unlink()
        self.assertFalse(self.mac())
        self.assertIn("upstream layout changed", self.said())
        self.assertNotIn("convert-into-app", self.said())


class ZathuraLinuxTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.env["WAYLAND_DISPLAY"] = "wayland-0"
        self.zathura = self.home / ".nix-profile" / "bin" / "zathura"
        self.listing = self.home / "profile.json"
        self.listing.write_text('{"elements": {}}')
        # `nix profile install` leaves a zathura in the profile and lists it.
        self.fake(
            "nix",
            f'#!/bin/sh\nif [ "$2" = list ]; then cat "{self.listing}"; exit 0; fi\n'
            'echo "nix $*" >>"$FAKE_CALLS"\n'
            f'mkdir -p "{self.zathura.parent}"\n'
            f"printf '#!/bin/sh\\n' >\"{self.zathura}\"\n"
            f'chmod +x "{self.zathura}"\n',
        )

    def linux(self, upgrade: bool = False) -> bool:
        return self.run_step(STEPS["install_zathura"], upgrade=upgrade)

    def test_headless(self) -> None:
        del self.env["WAYLAND_DISPLAY"]
        self.assertTrue(self.linux())
        self.assertEqual(
            self.said(),
            "[install] zathura: no display session detected; skipping on headless Linux\n",
        )
        self.assertEqual(self.called(), [])

    def test_install(self) -> None:
        self.assertTrue(self.linux())
        self.assertEqual(self.said(), "[install] Installing zathura\n")
        self.assertEqual(self.called(), [f"nix profile install --impure --expr {zathura.NIX_EXPR}"])

    def test_present_and_upgrade(self) -> None:
        self.listing.write_text('{"elements": {"zathura-with-plugins": {"active": true}}}')
        self.assertTrue(self.linux())
        self.assertEqual(self.said(), "[install] zathura already installed; skipping\n")
        self.assertEqual(self.called(), [])
        self.assertTrue(self.linux(upgrade=True))
        self.assertEqual(
            self.called(),
            [
                "nix profile remove zathura-with-plugins",
                f"nix profile install --impure --expr {zathura.NIX_EXPR}",
            ],
        )

    def test_an_unreadable_listing_installs(self) -> None:
        self.listing.write_text("not json")
        self.assertTrue(self.linux())
        self.assertEqual(self.said(), "[install] Installing zathura\n")
