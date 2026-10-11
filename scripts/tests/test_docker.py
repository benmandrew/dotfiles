from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import apt, tools
from installer.steps import STEPS, docker

from .support import StepCase

FINGERPRINT = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
GPG = f"#!/bin/sh\necho 'pub:-:4096:1:8D81803C0EBFCD88:'\necho 'fpr:::::::::{FINGERPRINT}:'\n"
# A dpkg that has the packages named in $HOME/packages.
DPKG = '#!/bin/sh\ngrep -qx "$2" "$HOME/packages" 2>/dev/null\n'
ALL = "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"


class DockerLinuxTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        root = Path(self.scratch)
        self.os_release = root / "os-release"
        self.os_release.write_text('ID=ubuntu\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME="jammy"\n')
        self.keyrings = root / "keyrings"
        self.sources = root / "sources.list.d"
        self.sources.mkdir()
        self.systemd = root / "systemd"
        for target, name, value in (
            (tools, "OS_RELEASE", self.os_release),
            (apt, "KEYRINGS", self.keyrings),
            (apt, "SOURCES", self.sources),
            (docker, "SYSTEMD", self.systemd),
        ):
            patch = mock.patch.object(target, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        self.fake("gpg", GPG)
        self.fake("dpkg", DPKG)
        self.fake(
            "id", '#!/bin/sh\nif [ "$1" = -un ]; then echo ben; else cat "$HOME/groups"; fi\n'
        )
        (self.home / "groups").write_text("ben sudo\n")
        self.recording("usermod")
        self.serve("https://download.docker.com/linux/ubuntu/gpg", "key")

    def step(self, upgrade: bool = False) -> bool:
        return self.run_step(STEPS["install_docker"], upgrade=upgrade)

    def test_install(self) -> None:
        self.installer("apt-get", creates="docker")
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(),
            "[install] Adding Docker's apt signing key\n"
            "[install] Adding Docker's apt repository\n"
            f"[install] Installing Docker packages: {ALL}\n"
            "[install] Adding ben to the docker group; log out and back in for it to apply\n"
            "[install] Docker: systemd is not running; not enabling docker.service\n",
        )
        self.assertEqual(
            self.called(),
            ["apt-get update", f"apt-get install -y {ALL}", "usermod -aG docker ben"],
        )
        self.assertEqual((self.keyrings / "docker.asc").read_text(), "key")
        self.assertEqual(
            (self.sources / "docker.sources").read_text(),
            "Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: jammy\n"
            f"Components: stable\nSigned-By: {self.keyrings}/docker.asc\n",
        )

    def test_a_machine_already_set_up(self) -> None:
        self.keyrings.mkdir()
        (self.keyrings / "docker.asc").touch()
        (self.sources / "docker.sources").touch()
        (self.home / "packages").write_text(ALL.replace(" ", "\n") + "\n")
        (self.home / "groups").write_text("ben docker\n")
        self.systemd.mkdir()
        self.fake("systemctl", "#!/bin/sh\nexit 0\n")
        self.recording("apt-get")
        self.assertTrue(self.step())
        self.assertEqual(self.said(), "[install] Docker packages already installed; skipping\n")
        self.assertEqual(self.called(), [])
        self.assertEqual(self.requests(), [])

    def test_only_the_missing_packages_and_the_unit(self) -> None:
        self.keyrings.mkdir()
        (self.keyrings / "docker.asc").touch()
        (self.sources / "docker.sources").touch()
        (self.home / "packages").write_text("docker-ce\ndocker-ce-cli\ncontainerd.io\n")
        (self.home / "groups").write_text("docker\n")
        self.systemd.mkdir()
        self.recording("systemctl", failing="is-enabled")
        self.installer("apt-get", creates="docker")
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(),
            "[install] Installing Docker packages: docker-buildx-plugin docker-compose-plugin\n"
            "[install] Enabling docker.service\n",
        )
        self.assertEqual(
            self.called()[1:],
            [
                "apt-get install -y docker-buildx-plugin docker-compose-plugin",
                "systemctl is-enabled --quiet docker.service",
                "systemctl enable --now docker.service",
            ],
        )

    def test_upgrade_takes_every_package(self) -> None:
        (self.home / "packages").write_text(ALL.replace(" ", "\n") + "\n")
        self.installer("apt-get", creates="docker")
        self.assertTrue(self.step(upgrade=True))
        self.assertIn("[install] Upgrading Docker\n", self.said())
        self.assertIn(f"apt-get install -y {ALL}", self.called())

    def test_a_key_with_another_fingerprint(self) -> None:
        self.fake("gpg", GPG.replace(FINGERPRINT, "0" * 40))
        self.recording("apt-get")
        self.assertFalse(self.step())
        self.assertIn("Docker's apt key does not carry the pinned fingerprint", self.said())
        self.assertFalse(self.keyrings.exists())
        self.assertEqual(self.called(), [])

    def test_a_derivative_takes_the_ubuntu_suite(self) -> None:
        self.os_release.write_text("ID=linuxmint\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble\n")
        self.installer("apt-get", creates="docker")
        self.assertTrue(self.step())
        self.assertIn("Suites: noble\n", (self.sources / "docker.sources").read_text())

    def test_debian(self) -> None:
        self.os_release.write_text("ID=debian\nVERSION_CODENAME=trixie\n")
        self.serve("https://download.docker.com/linux/debian/gpg", "key")
        self.installer("apt-get", creates="docker")
        self.assertTrue(self.step())
        self.assertIn(
            "URIs: https://download.docker.com/linux/debian\nSuites: trixie\n",
            (self.sources / "docker.sources").read_text(),
        )

    def test_distros_without_a_repository(self) -> None:
        self.os_release.write_text("ID=fedora\nVERSION_CODENAME=\n")
        self.assertTrue(self.step())
        self.os_release.write_text("ID=debian\n")
        self.assertTrue(self.step())
        self.os_release.unlink()
        self.assertTrue(self.step())
        self.assertEqual(
            self.said(),
            "[install] Docker: no apt repository for fedora; skipping\n"
            "[install] Docker: no release codename in /etc/os-release; skipping\n"
            "[install] Docker: no apt repository for this distro; skipping\n",
        )


class DockerMacosTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.cli = self.bin / "docker-desktop-cli"
        self.app = Path(self.scratch) / "Docker.app"
        for name, value in (("DESKTOP_CLI", str(self.cli)), ("DESKTOP_APP", self.app)):
            patch = mock.patch.object(docker, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def mac(self, upgrade: bool = False) -> bool:
        return self.run_step(
            STEPS["install_docker"], system="Darwin", machine="arm64", upgrade=upgrade
        )

    def test_install(self) -> None:
        self.fake(
            "brew",
            '#!/bin/sh\n[ "$1" = list ] && exit 1\necho "brew $*" >>"$FAKE_CALLS"\n'
            f'printf "#!/bin/sh\\n" >"{self.cli}"; chmod +x "{self.cli}"\n',
        )
        self.assertTrue(self.mac())
        self.assertEqual(
            self.said(),
            "[install] Installing Docker Desktop\n"
            "[install] Open Docker.app once to start the engine and accept its licence\n",
        )
        self.assertEqual(self.called(), ["brew install --cask docker-desktop"])

    def test_an_app_installed_by_hand(self) -> None:
        self.app.mkdir()
        self.recording("brew", failing="list")
        for upgrade in (False, True):
            self.assertTrue(self.mac(upgrade=upgrade))
        self.assertEqual(
            self.said(),
            "[install] Docker Desktop already installed outside Homebrew; skipping\n" * 2,
        )
        self.assertEqual(self.called(), ["brew list --cask docker-desktop"] * 2)

    def test_present_and_upgrade(self) -> None:
        self.recording("brew")
        self.fake(self.cli.name, "#!/bin/sh\n")
        self.assertTrue(self.mac())
        self.assertEqual(self.said(), "[install] Docker Desktop already installed; skipping\n")
        self.assertTrue(self.mac(upgrade=True))
        self.assertEqual(self.called()[-1], "brew upgrade --cask docker-desktop")

    def test_a_client_that_does_not_run(self) -> None:
        self.recording("brew", failing="list")
        self.assertFalse(self.mac())
        self.assertIn("does not run after installing", self.said())
