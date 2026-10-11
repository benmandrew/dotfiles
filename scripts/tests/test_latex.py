from __future__ import annotations

import hashlib
import os
from pathlib import Path
from unittest import mock

from installer.steps import PORTED, latex

from .support import StepCase

MIRROR = "https://ctan.example.org/tex/systems/texlive/tlnet"
# The curl of the tests answers a header probe with the mirror, and serves
# everything else as usual.
CURL = f"""#!/bin/sh
for word; do
    if [ "$word" = -w ]; then echo "curl $*" >>"$FAKE_CALLS"; printf '%s/' "{MIRROR}"; exit 0; fi
done
exec "$(dirname "$0")/curl-served" "$@"
"""
# An install-tl that lays down what the profile asks for.
INSTALL_TL = """#!/bin/sh
echo "install-tl $*" >>"$FAKE_CALLS"
profile="${1#--profile=}"
texdir="$(awk '$1 == "TEXDIR" { print $2 }' "$profile")"
mkdir -p "$texdir/bin/x86_64-linux" "$HOME/.local/bin"
for tool in tlmgr latexmk biber; do
    printf '#!/bin/sh\\necho "%s $*" >>"$FAKE_CALLS"\\n' "$tool" >"$texdir/bin/x86_64-linux/$tool"
    chmod +x "$texdir/bin/x86_64-linux/$tool"
    ln -sf "$texdir/bin/x86_64-linux/$tool" "$HOME/.local/bin/$tool"
done
cp "$profile" "$HOME/profile"
"""


class LatexLinuxTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        (self.bin / "curl").rename(self.bin / "curl-served")
        self.fake("curl", CURL)
        # The tests' perl runs the script it is given, which is a shell script.
        self.fake("perl", '#!/bin/sh\nexec sh "$@"\n')
        self.fake("dpkg", "#!/bin/sh\nexit 1\n")
        self.root = self.home / ".local/texlive"
        self.publish("2026")

    def publish(self, year: str, checksum: str | None = None) -> None:
        tarball = self.tarball(
            {
                "install-tl-20261001/install-tl": INSTALL_TL,
                "install-tl-20261001/release-texlive.txt": (
                    f"TeX Live (https://tug.org/texlive) version {year}\n\nmore\n"
                ),
            }
        )
        digest = checksum or hashlib.sha512(tarball).hexdigest()
        self.serve(f"{MIRROR}/install-tl-unx.tar.gz", tarball)
        self.serve(f"{MIRROR}/install-tl-unx.tar.gz.sha512", f"{digest}  install-tl-unx.tar.gz\n")

    def tree(self, year: str, complete: bool = True) -> Path:
        """A TeX Live year as install-tl leaves it."""
        texdir = self.root / year
        bin_dir = texdir / "bin/x86_64-linux"
        for tool in ("tlmgr", "latexmk", "biber"):
            self.fake(tool, f'#!/bin/sh\necho "{tool} $*" >>"$FAKE_CALLS"\n', bin_dir)
        if complete:
            (texdir / ".dotfiles-complete").touch()
        return texdir

    def step(self, upgrade: bool = False) -> bool:
        return self.run_step(PORTED["install_latex"], upgrade=upgrade)

    def test_install(self) -> None:
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(),
            f"[install] Installing TeX Live 2026 into {self.root}; this is a download of several"
            " gigabytes\n",
        )
        texdir = self.root / "2026"
        self.assertTrue((texdir / ".dotfiles-complete").is_file())
        calls = self.called()
        self.assertTrue(calls[0].endswith(f"-w %{{url_effective}} {latex.REPOSITORY}/"))
        self.assertRegex(
            calls[1], rf"^install-tl --profile=\S+/dotfiles\.profile --repository={MIRROR}$"
        )
        self.assertEqual(
            calls[2:],
            [f"tlmgr option repository {latex.REPOSITORY}", "latexmk -v", "biber --version"],
        )
        profile = (self.home / "profile").read_text().splitlines()
        self.assertEqual(profile[:2], ["selected_scheme scheme-custom", f"TEXDIR {texdir}"])
        self.assertIn("collection-luatex 1", profile)
        self.assertIn(f"tlpdbopt_sys_bin {self.home}/.local/bin", profile)
        self.assertEqual(len(profile), 26)
        # Every request after the probe goes to the one mirror.
        self.assertTrue(all(url.startswith(MIRROR) for url in self.requests()))

    def test_present(self) -> None:
        self.tree("2025")
        self.assertTrue(self.step())
        self.assertEqual(self.said(), "[install] TeX Live 2025 already installed; skipping\n")
        self.assertEqual(self.called(), [])

    def test_an_old_tree_with_every_collection_counts_and_is_marked(self) -> None:
        texdir = self.tree("2025", complete=False)
        database = texdir / "tlpkg/texlive.tlpdb"
        database.parent.mkdir()
        database.write_text("".join(f"name {name}\nx\n" for name in latex.COLLECTIONS))
        self.assertTrue(self.step())
        self.assertIn("already installed", self.said())
        self.assertTrue((texdir / ".dotfiles-complete").is_file())

    def test_an_interrupted_install_is_replaced(self) -> None:
        texdir = self.tree("2026", complete=False)
        (texdir / "left-over").touch()
        self.assertTrue(self.step())
        self.assertEqual(
            self.said().splitlines()[0],
            "[install] Removing the incomplete TeX Live 2026 left by an earlier run",
        )
        self.assertFalse((texdir / "left-over").exists())

    def test_upgrade_within_a_year(self) -> None:
        self.tree("2026")
        self.assertTrue(self.step(upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading TeX Live 2026 packages\n")
        self.assertEqual(
            self.called()[1:], ["tlmgr update --self --all", "latexmk -v", "biber --version"]
        )

    def test_upgrade_to_a_new_year_removes_the_old_one(self) -> None:
        old = self.tree("2025")
        links = self.home / ".local/bin"
        links.mkdir(parents=True)
        (links / "pdftex-old").symlink_to(old / "bin/x86_64-linux/pdftex-old")
        (links / "other").symlink_to(self.home / "elsewhere")
        self.assertTrue(self.step(upgrade=True))
        self.assertEqual(
            self.said(),
            f"[install] Installing TeX Live 2026 into {self.root}; this is a download of several"
            " gigabytes\n[install] Removing TeX Live 2025\n",
        )
        self.assertFalse(old.exists())
        self.assertFalse(os.path.lexists(links / "pdftex-old"))
        self.assertTrue(os.path.lexists(links / "other"))
        self.assertTrue((links / "latexmk").exists())

    def test_a_mirror_a_year_behind(self) -> None:
        self.tree("2027")
        self.assertTrue(self.step(upgrade=True))
        self.assertEqual(
            self.said(),
            f"[install] TeX Live 2027 is newer than the 2026 installer on {MIRROR}; skipping\n",
        )
        self.assertTrue((self.root / "2027").is_dir())

    def test_a_checksum_that_does_not_match(self) -> None:
        self.publish("2026", checksum="0" * 128)
        self.assertFalse(self.step())
        self.assertIn(f"Checksum mismatch for install-tl-unx.tar.gz from {MIRROR}", self.said())
        self.assertFalse(self.root.exists())

    def test_a_release_file_without_a_year(self) -> None:
        self.publish("next")
        self.assertFalse(self.step())
        self.assertIn("Could not read the TeX Live year from", self.said())

    def test_no_mirror(self) -> None:
        self.fake("curl", "#!/bin/sh\nexit 6\n")
        self.assertFalse(self.step())
        self.assertIn(f"Could not resolve a CTAN mirror from {latex.REPOSITORY}", self.said())

    def test_the_apt_tex_live_is_pointed_out(self) -> None:
        self.fake("dpkg", "#!/bin/sh\nexit 0\n")
        self.assertTrue(self.step())
        self.assertIn(
            "[install]   sudo apt-get purge 'texlive*' latexmk biber && sudo apt-get autoremove\n",
            self.said(),
        )


class LatexMacosTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.texbin = Path(self.scratch) / "texbin"
        patch = mock.patch.object(latex, "TEXBIN", self.texbin)
        patch.start()
        self.addCleanup(patch.stop)
        for tool in ("latexmk", "biber"):
            self.fake(tool, "#!/bin/sh\n", self.texbin)

    def mac(self, upgrade: bool = False) -> bool:
        return self.run_step(
            PORTED["install_latex"], system="Darwin", machine="arm64", upgrade=upgrade
        )

    def test_install(self) -> None:
        self.recording("brew", failing="list")
        self.assertTrue(self.mac())
        self.assertEqual(
            self.said(),
            "[install] Installing MacTeX (no GUI); this is a download of several gigabytes\n",
        )
        self.assertEqual(self.called()[-1], "brew install --cask mactex-no-gui")

    def test_present_and_upgrade(self) -> None:
        self.recording("brew")
        self.assertTrue(self.mac())
        self.assertEqual(self.said(), "[install] MacTeX already installed; skipping\n")
        self.assertTrue(self.mac(upgrade=True))
        self.assertEqual(self.called()[-1], "brew upgrade --cask mactex-no-gui")

    def test_a_latexmk_that_does_not_run(self) -> None:
        self.recording("brew", failing="list")
        (self.texbin / "latexmk").unlink()
        self.assertFalse(self.mac())
