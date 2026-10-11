from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import github, pins, tools
from installer.steps import STEPS, builds

from .support import StepCase, prints

PIN = pins.pin("TMUX_VERSION")

# A make that says where and how it ran, and installs when asked to.
MAKE = """#!/bin/sh
echo "make $* [$(basename "$PWD") PATH=$PATH CC=${CC:-} CXX=${CXX:-}]" >>"$FAKE_CALLS"
"""


class BuildCase(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.target = Path(self.scratch) / "usr-local-bin" / "tmux"
        # The pruned PATH a build runs with, which here must still hold the fakes.
        self.system_path = f"{self.bin}:{self.system}"
        for owner, name, value in (
            (builds, "TMUX", self.target),
            (builds, "SYSTEM_PATH", self.system_path),
            (tools, "cpu_count", lambda: 3),
        ):
            patch = mock.patch.object(owner, name, value)
            patch.start()
            self.addCleanup(patch.stop)


class TmuxTest(BuildCase):
    def release(self, version: str) -> None:
        configure = '#!/bin/sh\necho "configure [PATH=$PATH CC=$CC]" >>"$FAKE_CALLS"\n'
        self.serve(
            f"https://github.com/tmux/tmux/releases/download/{version}/tmux-{version}.tar.gz",
            self.tarball({f"tmux-{version}/configure": configure}),
        )
        self.fake(
            "make",
            MAKE + f'case "$*" in *install) mkdir -p "{self.target.parent}"; '
            f'printf \'#!/bin/sh\\n\' >"{self.target}"; chmod +x "{self.target}" ;; esac\n',
        )

    def test_new_enough_is_skipped(self) -> None:
        for reported, current in (("tmux 3.4", "3.4"), ("tmux 3.6b", "3.6"), ("tmux 4.0", "4.0")):
            self.fake("tmux", prints(reported))
            self.assertTrue(self.run_step(STEPS["install_tmux_from_source"]))
            self.assertIn(
                f"[install] tmux {current} already satisfies >= 3.4; skipping\n", self.said()
            )
        self.assertEqual(self.requests(), [])

    def test_build(self) -> None:
        self.release(PIN)
        self.assertTrue(self.run_step(STEPS["install_tmux_from_source"]))
        self.assertEqual(self.said(), "[install] Installing tmux from source\n")
        system = f"PATH={self.system_path} CC=/usr/bin/gcc"
        source = f"tmux-{PIN}"
        self.assertEqual(self.called()[0], f"configure [{system}]")
        self.assertEqual(self.called()[1], f"make -j3 [{source} {system} CXX=]")
        self.assertTrue(self.called()[2].startswith("make -C "))
        self.assertIn(f"/{source} install [", self.called()[2])

    def test_an_old_tmux_is_rebuilt(self) -> None:
        self.fake("tmux", prints("tmux 3.3a"))
        self.release(PIN)
        self.assertTrue(self.run_step(STEPS["install_tmux_from_source"]))
        self.assertEqual(
            self.said(),
            "[install] tmux 3.3 < 3.4; building from source\n"
            f"[install] Note: tmux on PATH is {self.bin}/tmux, which shadows the copy just"
            f" installed at {self.target}\n",
        )

    def test_a_failed_configure_fails_the_step(self) -> None:
        self.serve(
            f"https://github.com/tmux/tmux/releases/download/{PIN}/tmux-{PIN}.tar.gz",
            self.tarball({f"tmux-{PIN}/configure": "#!/bin/sh\nexit 1\n"}),
        )
        self.recording("make")
        self.assertFalse(self.run_step(STEPS["install_tmux_from_source"]))
        self.assertEqual(self.called(), [])

    def test_upgrade(self) -> None:
        self.serve(f"{github.API}/tmux/tmux/releases/latest", '{"tag_name": "3.7"}')
        self.release("3.7")
        self.assertTrue(self.run_step(STEPS["install_tmux_from_source"], upgrade=True))
        self.assertEqual(self.said(), "[install] Installing tmux 3.7\n")
        self.fake("tmux", prints("tmux 3.6b"))
        self.assertTrue(self.run_step(STEPS["install_tmux_from_source"], upgrade=True))
        self.assertIn("[install] Upgrading tmux to 3.7\n", self.said())
        self.fake("tmux", prints("tmux 3.7"))
        self.assertTrue(self.run_step(STEPS["install_tmux_from_source"], upgrade=True))
        self.assertIn("[install] tmux 3.7 already at latest; skipping\n", self.said())


# A git whose clone leaves a btop tree behind.
GIT = """#!/bin/sh
echo "git $*" >>"$FAKE_CALLS"
for last; do :; done
mkdir -p "$last/bin" "$last/themes"
printf '#!/bin/sh\\n' >"$last/bin/btop"
echo theme >"$last/themes/nord.theme"
"""


class BtopTest(BuildCase):
    def setUp(self) -> None:
        super().setUp()
        self.version = pins.pin("BTOP_VERSION")
        self.fake("dpkg", "#!/bin/sh\nexit 1\n")
        self.fake("make", MAKE)

    def test_build(self) -> None:
        self.fake("git", GIT)
        self.assertTrue(self.run_step(STEPS["install_btop"]))
        self.assertEqual(self.said(), f"[install] Installing btop {self.version}\n")
        clone, make = self.called()
        self.assertTrue(
            clone.startswith(
                f"git clone --quiet --depth 1 --branch v{self.version} {builds.BTOP_URL} "
            )
        )
        self.assertIn(" -j3 [", make)
        self.assertIn(f"PATH={self.system_path} CC= CXX=/usr/bin/g++]", make)
        self.assertTrue((self.home / ".local/bin/btop").is_file())
        self.assertEqual((self.home / ".config/btop/themes/nord.theme").read_text(), "theme\n")

    def test_present(self) -> None:
        # Bold around the number, and the commit it was built from after it.
        self.fake("btop", f"#!/bin/sh\nprintf 'btop version: \\033[1m{self.version}+0f398ab\\n'\n")
        self.assertTrue(self.run_step(STEPS["install_btop"]))
        self.assertEqual(
            self.said(), f"[install] btop {self.version} already installed; skipping\n"
        )
        self.assertTrue(self.run_step(STEPS["install_btop"], upgrade=True))
        self.assertIn(
            f"[install] btop {self.version} already at pinned version; skipping\n", self.said()
        )
        self.assertEqual(self.called(), [])

    def test_upgrade_builds_the_pin(self) -> None:
        self.fake("btop", prints("btop version: 1.3.0"))
        self.fake("git", GIT)
        self.assertTrue(self.run_step(STEPS["install_btop"], upgrade=True))
        self.assertTrue(self.said().startswith(f"[install] Upgrading btop to {self.version}\n"))
        self.assertEqual(self.requests(), [])

    def test_the_apt_package_is_purged(self) -> None:
        self.fake("dpkg", "#!/bin/sh\n")
        apt_btop = self.fake("btop", prints("btop version: 1.2.3"), self.home / "apt")
        self.env["PATH"] = f"{self.env['PATH']}:{apt_btop.parent}"
        self.fake("apt-get", f'#!/bin/sh\necho "apt-get $*" >>"$FAKE_CALLS"\nrm "{apt_btop}"\n')
        self.fake("git", GIT)
        self.assertTrue(self.run_step(STEPS["install_btop"]))
        self.assertEqual(
            self.said(),
            "[install] Removing apt btop (predates GPU support, and shadows ~/.local/bin)\n"
            f"[install] Installing btop {self.version}\n",
        )
        self.assertEqual(self.called()[0], "apt-get purge -y btop")

    def test_a_failed_clone(self) -> None:
        self.recording("git", failing="clone")
        self.assertFalse(self.run_step(STEPS["install_btop"]))
        self.assertIn(f"ERROR: Failed to clone btop v{self.version}\n", self.said())

    def test_macos_is_a_formula(self) -> None:
        self.installer("brew", creates="btop")
        self.assertTrue(self.run_step(STEPS["install_btop"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] Installing btop\n")
        self.assertEqual(self.called(), ["brew install btop"])
        self.assertTrue(
            self.run_step(STEPS["install_btop"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(self.called()[-1], "brew upgrade btop")
