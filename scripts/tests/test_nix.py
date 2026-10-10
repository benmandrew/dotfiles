from __future__ import annotations

from pathlib import Path

from installer.steps import PORTED

from .support import StepCase

LISTING = """Name:               {name}
Flake attribute:    legacyPackages.aarch64-darwin.{name}
Original flake URL: flake:nixpkgs
"""


class NixDirenvTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.listing = Path(self.scratch) / "profile"
        self.listing.write_text("")
        self.fake(
            "nix",
            f'#!/bin/sh\nif [ "$2" = list ]; then cat "{self.listing}"; exit 0; fi\n'
            'echo "nix $*" >>"$FAKE_CALLS"\n',
        )
        self.profile = self.home / ".nix-profile"

    def has(self, *names: str) -> None:
        self.listing.write_text("\n".join(LISTING.format(name=name) for name in names))

    def linked(self) -> None:
        share = self.profile / "share" / "nix-direnv"
        share.mkdir(parents=True)
        (share / "direnvrc").write_text("")

    def run_nix_direnv(self, system: str = "Linux", upgrade: bool = False) -> bool:
        return self.run_step(PORTED["install_nix_direnv"], system=system, upgrade=upgrade)

    def test_install_on_linux(self) -> None:
        self.linked()
        self.assertTrue(self.run_nix_direnv())
        self.assertEqual(
            self.said(),
            "[install] Installing nix-direnv\n[install] Wiring nix-direnv into direnvrc\n",
        )
        self.assertEqual(self.called(), ["nix profile install nixpkgs#nix-direnv"])
        self.assertEqual(
            (self.home / ".config/direnv/direnvrc").read_text(),
            "source $HOME/.nix-profile/share/nix-direnv/direnvrc\n",
        )

    def test_present(self) -> None:
        self.linked()
        self.has("nix-direnv")
        direnvrc = self.home / ".config" / "direnv" / "direnvrc"
        direnvrc.parent.mkdir(parents=True)
        direnvrc.write_text("# mine\nsource ~/.nix-profile/share/nix-direnv/direnvrc\n")
        self.assertTrue(self.run_nix_direnv())
        self.assertEqual(self.said(), "[install] nix-direnv already installed; skipping\n")
        self.assertEqual(self.called(), [])
        self.assertTrue(direnvrc.read_text().startswith("# mine\n"))

    def test_another_package_ending_in_the_name_does_not_count(self) -> None:
        self.linked()
        self.has("not-nix-direnv")
        self.assertTrue(self.run_nix_direnv())
        self.assertIn("[install] Installing nix-direnv\n", self.said())

    def test_macos_gets_a_modern_bash_first(self) -> None:
        self.linked()
        self.fake("bash", "#!/bin/sh\n", self.profile / "bin")
        self.assertTrue(self.run_nix_direnv(system="Darwin"))
        self.assertEqual(
            self.said(),
            "[install] Installing modern bash (nix-direnv requires >= 4.4)\n"
            "[install] Installing nix-direnv\n"
            "[install] Wiring nix-direnv into direnvrc\n",
        )
        self.has("bash", "nix-direnv")
        self.assertTrue(self.run_nix_direnv(system="Darwin"))
        self.assertIn(
            "[install] Modern bash already installed; skipping\n"
            "[install] nix-direnv already installed; skipping\n",
            self.said(),
        )
        self.assertTrue(self.run_nix_direnv(system="Darwin", upgrade=True))
        self.assertEqual(
            self.called()[-2:], ["nix profile upgrade bash", "nix profile upgrade nix-direnv"]
        )

    def test_a_package_that_did_not_link_fails_the_step(self) -> None:
        self.assertFalse(self.run_nix_direnv())
        self.assertIn(
            "ERROR: nix-direnv is not in the nix profile"
            " (~/.nix-profile/share/nix-direnv/direnvrc missing)\n",
            self.said(),
        )
        self.assertFalse((self.home / ".config/direnv/direnvrc").exists())

    def test_without_nix(self) -> None:
        (self.bin / "nix").unlink()
        self.assertFalse(self.run_nix_direnv())
        self.assertTrue(self.said().startswith("[install] ERROR: Missing required command: nix\n"))
