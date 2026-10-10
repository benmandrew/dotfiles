from __future__ import annotations

import os
import pwd
from pathlib import Path
from unittest import mock

from installer.steps import PORTED, nix

from .support import StepCase

USER = pwd.getpwuid(os.geteuid()).pw_name

# What the nix installer leaves: nix outside PATH, and a profile script that
# puts it there.
INSTALLER = """#!/bin/sh
echo "installer $*" >>"$FAKE_CALLS"
mkdir -p "$HOME/nix/bin" "$HOME/.nix-profile/etc/profile.d"
printf '#!/bin/sh\\n' >"$HOME/nix/bin/nix"
chmod +x "$HOME/nix/bin/nix"
echo 'export PATH="$HOME/nix/bin:$PATH"' >"$HOME/.nix-profile/etc/profile.d/nix.sh"
"""


class NixTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        root = Path(self.scratch) / "root"
        root.mkdir()
        self.system_conf = root / "nix.conf"
        self.system_conf.write_text(f"trusted-users = root {USER}\n")
        self.daemon_script = root / "nix-daemon.sh"
        self.default_nix = root / "default" / "nix"
        for name, value in (
            ("SYSTEM_CONF", self.system_conf),
            ("DEFAULT_NIX", self.default_nix),
            ("PROFILE_SCRIPTS", (self.daemon_script, root / "nix.sh")),
        ):
            patch = mock.patch.object(nix, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.conf = self.home / ".config" / "nix" / "nix.conf"

    def flakes_on(self) -> None:
        self.conf.parent.mkdir(parents=True)
        self.conf.write_text("experimental-features = nix-command flakes\n")

    def test_present_and_set_up(self) -> None:
        self.fake("nix", "#!/bin/sh\n")
        self.flakes_on()
        self.assertTrue(self.run_step(PORTED["install_nix"]))
        self.assertEqual(self.said(), "[install] Nix already installed; skipping\n")
        self.assertEqual(self.called(), [])

    def test_present_gets_flakes_and_a_trusted_user(self) -> None:
        self.fake("nix", "#!/bin/sh\n")
        self.system_conf.write_text("trusted-users = root\n")
        self.recording("systemctl")
        self.assertTrue(self.run_step(PORTED["install_nix"]))
        self.assertEqual(
            self.said(),
            "[install] Nix already installed; skipping\n"
            "[install] Enabling Nix flakes\n"
            f"[install] Adding {USER} to Nix trusted-users\n",
        )
        self.assertEqual(
            self.conf.read_text(), "extra-experimental-features = nix-command flakes\n"
        )
        self.assertEqual(
            self.system_conf.read_text(), f"trusted-users = root\nextra-trusted-users = {USER}\n"
        )
        self.assertEqual(self.called(), ["systemctl restart nix-daemon"])

    def test_macos_restarts_the_daemon_through_launchctl(self) -> None:
        self.fake("nix", "#!/bin/sh\n")
        self.flakes_on()
        self.system_conf.write_text("")
        self.recording("launchctl")
        self.assertTrue(self.run_step(PORTED["install_nix"], system="Darwin", machine="arm64"))
        self.assertEqual(self.called(), ["launchctl kickstart -k system/org.nixos.nix-daemon"])

    def test_a_daemon_that_will_not_restart_fails_the_step(self) -> None:
        self.fake("nix", "#!/bin/sh\n")
        self.system_conf.write_text("")
        self.recording("systemctl", failing="restart")
        self.assertFalse(self.run_step(PORTED["install_nix"]))

    def test_a_conf_that_cannot_be_written_fails_the_step(self) -> None:
        self.fake("nix", "#!/bin/sh\n")
        self.recording("systemctl")
        missing = Path(self.scratch) / "no-such-directory" / "nix.conf"
        with mock.patch.object(nix, "SYSTEM_CONF", missing):
            self.assertFalse(self.run_step(PORTED["install_nix"]))
        self.assertEqual(self.called(), [])

    def test_an_installed_nix_off_path_is_sourced(self) -> None:
        # The daemon script returns early when this is set, as a shell that
        # inherited it with a PATH that has since lost nix would find.
        self.env["__ETC_PROFILE_NIX_SOURCED"] = "1"
        self.fake("nix", "#!/bin/sh\n", self.default_nix.parent)
        self.daemon_script.write_text(
            'if [ -n "${__ETC_PROFILE_NIX_SOURCED:-}" ]; then return; fi\n'
            "export __ETC_PROFILE_NIX_SOURCED=1\n"
            f'export PATH="{self.default_nix.parent}:$PATH"\n'
            "echo sourced\n"
        )
        self.flakes_on()
        before = dict(self.env)
        self.assertTrue(self.run_step(PORTED["install_nix"], upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading Nix\n")
        self.assertEqual(self.env["PATH"], f"{self.default_nix.parent}:{before['PATH']}")
        self.assertEqual(
            {name: value for name, value in self.env.items() if name != "PATH"},
            {name: value for name, value in before.items() if name != "PATH"},
        )

    def test_install(self) -> None:
        self.serve(nix.INSTALL_URL, INSTALLER)
        self.flakes_on()
        self.assertTrue(self.run_step(PORTED["install_nix"]))
        self.assertEqual(self.said(), "[install] Installing Nix\n")
        self.assertEqual(self.called(), ["installer --daemon --yes"])
        # The steps that follow find nix.
        self.assertTrue(self.env["PATH"].startswith(f"{self.home}/nix/bin:"))

    def test_an_install_that_leaves_no_nix_fails_the_step(self) -> None:
        self.serve(nix.INSTALL_URL, "#!/bin/sh\n")
        self.assertFalse(self.run_step(PORTED["install_nix"]))
        self.assertIn("ERROR: nix does not run after installing (not on PATH", self.said())

    def test_upgrade_retries_once(self) -> None:
        marker = self.home / "tried"
        self.fake(
            "nix",
            '#!/bin/sh\necho "nix $*" >>"$FAKE_CALLS"\n[ "$1" = upgrade-nix ] || exit 0\n'
            f'[ -e "{marker}" ] && exit 0\n: >"{marker}"\nexit 1\n',
        )
        self.flakes_on()
        self.assertTrue(self.run_step(PORTED["install_nix"], upgrade=True))
        self.assertEqual(
            self.said(), "[install] Upgrading Nix\n[install] sudo failed; retrying once\n"
        )
        self.assertEqual(self.called(), ["nix upgrade-nix", "nix upgrade-nix", "nix --version"])


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
