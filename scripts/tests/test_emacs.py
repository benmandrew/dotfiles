from __future__ import annotations

from pathlib import Path

from installer.steps import STEPS

from .support import StepCase, prints

LISTING = """Name:               emacs-nox
Flake attribute:    legacyPackages.x86_64-linux.emacs-nox
Original flake URL: flake:nixpkgs
"""

# Records each call with the Emacs it was told to run, as bin/doom reads it.
DOOM = '#!/bin/sh\necho "doom $* EMACS=$EMACS" >>"$FAKE_CALLS"\n'


class DoomEmacsTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.root = self.home / ".config" / "emacs"
        self.nix_emacs = self.home / ".nix-profile" / "bin" / "emacs"
        self.listing = Path(self.scratch) / "profile"
        self.listing.write_text("")
        # `nix profile install` leaves an emacs in the profile and lists it.
        self.fake(
            "nix",
            f'#!/bin/sh\nif [ "$2" = list ]; then cat "{self.listing}"; exit 0; fi\n'
            'echo "nix $*" >>"$FAKE_CALLS"\n'
            f'mkdir -p "{self.nix_emacs.parent}"\n'
            f'printf \'#!/bin/sh\\necho "GNU Emacs 31.1"\\n\' >"{self.nix_emacs}"\n'
            f'chmod +x "{self.nix_emacs}"\n',
        )
        # `git clone` leaves a clone holding bin/doom.
        doom = self.fake("doom", DOOM, Path(self.scratch) / "doom")
        self.fake(
            "git",
            '#!/bin/sh\necho "git $*" >>"$FAKE_CALLS"\n'
            'for dir; do :; done\nmkdir -p "$dir/.git" "$dir/bin"\n'
            f'cp "{doom}" "$dir/bin/doom"\n',
        )

    def run_linux(self, upgrade: bool = False) -> bool:
        return self.run_step(STEPS["install_doom_emacs"], upgrade=upgrade)

    def test_install_on_linux(self) -> None:
        self.assertTrue(self.run_linux())
        self.assertEqual(
            self.said(),
            "[install] Installing Emacs from nixpkgs#emacs-nox\n[install] Installing Doom Emacs\n",
        )
        self.assertEqual(
            self.called(),
            [
                "nix profile install nixpkgs#emacs-nox",
                f"git clone --depth 1 https://github.com/doomemacs/core {self.root}",
                f"doom --force install --no-config --no-env EMACS={self.nix_emacs}",
            ],
        )
        self.assertFalse((self.home / ".config" / "doom").exists())

    def test_an_old_emacs_is_shadowed(self) -> None:
        self.fake("emacs", prints("GNU Emacs 27.1"))
        self.assertTrue(self.run_linux())
        said = self.said()
        self.assertIn("[install] Emacs 27.1 < 29.1; installing nixpkgs#emacs-nox\n", said)
        self.assertIn(f"EMACS={self.nix_emacs}", self.called()[-1])

    def test_a_new_enough_emacs_is_kept(self) -> None:
        apt = self.fake("emacs", prints("GNU Emacs 29.3\nCopyright"))
        self.assertTrue(self.run_linux())
        self.assertIn("[install] Emacs 29.3 already installed; skipping\n", self.said())
        self.assertNotIn("nix profile install nixpkgs#emacs-nox", self.called())
        self.assertIn(f"EMACS={apt}", self.called()[-1])

    def test_present_and_upgrade(self) -> None:
        self.assertTrue(self.run_linux())
        self.listing.write_text(LISTING)
        self.calls.unlink()

        self.assertTrue(self.run_linux())
        self.assertEqual(self.called(), [])
        self.assertTrue(self.run_linux(upgrade=True))
        self.assertEqual(
            self.called(),
            ["nix profile upgrade emacs-nox", f"doom --force upgrade EMACS={self.nix_emacs}"],
        )
        self.assertTrue(
            self.said().endswith(
                "[install] Emacs already installed; skipping\n"
                "[install] Doom Emacs already installed; skipping\n"
                "[install] Upgrading Emacs\n"
                "[install] Upgrading Doom Emacs\n"
            )
        )

    def test_another_config_in_the_way_fails(self) -> None:
        (self.root / "init.el").parent.mkdir(parents=True)
        (self.root / "init.el").write_text("")
        self.assertFalse(self.run_linux())
        self.assertIn(f"{self.root} exists but is not a git clone", self.said())
        self.assertFalse((self.root / ".git").exists())

    def test_emacs_d_is_named(self) -> None:
        (self.home / ".emacs.d").mkdir()
        self.assertTrue(self.run_linux())
        self.assertIn(
            f"[install] Note: {self.home / '.emacs.d'} exists, so Emacs will load it in place"
            " of Doom\n",
            self.said(),
        )

    def test_homebrew_on_macos(self) -> None:
        self.fake(
            "brew",
            '#!/bin/sh\necho "brew $*" >>"$FAKE_CALLS"\n[ "$1" = list ] && exit 1\n'
            f'printf \'#!/bin/sh\\necho "GNU Emacs 31.1"\\n\' >"{self.bin}/emacs"\n'
            f'chmod +x "{self.bin}/emacs"\n',
        )
        step = STEPS["install_doom_emacs"]
        self.assertTrue(self.run_step(step, system="Darwin", machine="arm64"))
        self.assertEqual(
            self.said(), "[install] Installing emacs\n[install] Installing Doom Emacs\n"
        )
        self.assertEqual(self.called()[1], "brew install emacs")
        self.assertEqual(
            self.called()[-1], f"doom --force install --no-config --no-env EMACS={self.bin}/emacs"
        )
