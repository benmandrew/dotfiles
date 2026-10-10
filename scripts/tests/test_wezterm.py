from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import tools
from installer.steps import PORTED

from .support import StepCase, sha256

BASE = "https://github.com/wezterm/wezterm/releases/download/nightly"


class WeztermTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.os_release = Path(self.scratch) / "os-release"
        self.os_release.write_text('VERSION_ID="24.04"\n')
        patch = mock.patch.object(tools, "OS_RELEASE", self.os_release)
        patch.start()
        self.addCleanup(patch.stop)

    def publish(self, ubuntu: str) -> None:
        deb = f"wezterm-nightly.Ubuntu{ubuntu}.deb"
        self.serve(f"{BASE}/{deb}", b"deb")
        self.serve(f"{BASE}/{deb}.sha256", f"{sha256(b'deb')}  {deb}\n")

    def test_headless_linux(self) -> None:
        self.assertTrue(self.run_step(PORTED["install_wezterm"]))
        self.assertEqual(
            self.said(),
            "[install] WezTerm: no display session detected; skipping on headless Linux\n",
        )

    def test_present(self) -> None:
        self.env["WAYLAND_DISPLAY"] = "wayland-0"
        self.fake("wezterm", "#!/bin/sh\n")
        self.assertTrue(self.run_step(PORTED["install_wezterm"]))
        self.assertEqual(self.said(), "[install] WezTerm already installed; skipping\n")

    def test_install_the_package_for_this_ubuntu(self) -> None:
        self.env["DISPLAY"] = ":0"
        self.publish("24.04")
        self.installer("apt-get", creates="wezterm")
        self.assertTrue(self.run_step(PORTED["install_wezterm"]))
        self.assertEqual(self.said(), "[install] Installing WezTerm\n")
        (call,) = self.called()
        self.assertTrue(call.startswith("apt-get install -y /"))
        self.assertTrue(call.endswith("/wezterm-nightly.Ubuntu24.04.deb"))

    def test_an_unknown_ubuntu_takes_the_22_04_package(self) -> None:
        self.env["DISPLAY"] = ":0"
        self.os_release.write_text("VERSION_ID=25.10\n")
        self.publish("22.04")
        self.fake("wezterm", "#!/bin/sh\n")
        self.recording("apt-get")
        self.assertTrue(self.run_step(PORTED["install_wezterm"], upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading WezTerm\n")
        self.assertTrue(self.called()[0].endswith("/wezterm-nightly.Ubuntu22.04.deb"))

    def test_a_package_that_fails_its_checksum(self) -> None:
        self.env["DISPLAY"] = ":0"
        deb = "wezterm-nightly.Ubuntu24.04.deb"
        self.serve(f"{BASE}/{deb}", b"deb")
        self.serve(f"{BASE}/{deb}.sha256", f"{sha256(b'other')}  {deb}\n")
        self.recording("apt-get")
        self.assertFalse(self.run_step(PORTED["install_wezterm"]))
        self.assertEqual(self.called(), [])

    def test_arm64_linux(self) -> None:
        self.env["DISPLAY"] = ":0"
        self.assertTrue(self.run_step(PORTED["install_wezterm"], machine="aarch64"))
        self.assertEqual(
            self.said(),
            "[install] Installing WezTerm\n"
            "[install] WezTerm: no official binary for aarch64; skipping\n",
        )

    def test_macos(self) -> None:
        self.installer("brew", creates="wezterm")
        self.assertTrue(self.run_step(PORTED["install_wezterm"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] Installing WezTerm\n")
        self.assertEqual(self.called(), ["brew install --cask wezterm@nightly"])

    def test_a_failed_cask_upgrade_keeps_the_install(self) -> None:
        self.fake("wezterm", "#!/bin/sh\n")
        self.recording("brew", failing="upgrade")
        self.assertTrue(
            self.run_step(PORTED["install_wezterm"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(
            self.said(),
            "[install] Upgrading WezTerm\n"
            "[install] WezTerm nightly upgrade failed (likely upstream cask bug); keeping"
            " existing install; skipping\n",
        )


QUERY = """Name: x-terminal-emulator
Link: /usr/bin/x-terminal-emulator
Status: auto
Best: /usr/bin/gnome-terminal.wrapper
Value: {value}

Alternative: /usr/bin/gnome-terminal.wrapper
Priority: 40

Alternative: /usr/bin/open-wezterm-here
Priority: 20
"""


class DefaultTerminalTest(StepCase):
    def alternatives(self, query: str) -> None:
        (Path(self.scratch) / "query").write_text(query)
        self.fake(
            "update-alternatives",
            f'#!/bin/sh\nif [ "$1" = --query ]; then cat "{self.scratch}/query"; exit 0; fi\n'
            'echo "update-alternatives $*" >>"$FAKE_CALLS"\n',
        )

    def test_set(self) -> None:
        self.alternatives(QUERY.format(value="/usr/bin/gnome-terminal.wrapper"))
        self.assertTrue(self.run_step(PORTED["set_default_terminal_wezterm"]))
        self.assertEqual(self.said(), "[install] Setting x-terminal-emulator to WezTerm\n")
        self.assertEqual(
            self.called(),
            ["update-alternatives --set x-terminal-emulator /usr/bin/open-wezterm-here"],
        )

    def test_already_set(self) -> None:
        self.alternatives(QUERY.format(value="/usr/bin/open-wezterm-here"))
        self.assertTrue(self.run_step(PORTED["set_default_terminal_wezterm"]))
        self.assertEqual(self.said(), "[install] x-terminal-emulator already WezTerm; skipping\n")

    def test_not_registered(self) -> None:
        for query in (None, QUERY.format(value="x").split("Alternative: /usr/bin/open")[0]):
            if query is not None:
                self.alternatives(query)
            self.assertTrue(self.run_step(PORTED["set_default_terminal_wezterm"]))
        line = (
            "[install] x-terminal-emulator: /usr/bin/open-wezterm-here not registered; skipping\n"
        )
        self.assertEqual(self.said(), line * 2)
        self.assertEqual(self.called(), [])
