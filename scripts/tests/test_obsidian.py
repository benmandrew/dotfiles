from __future__ import annotations

import os
from pathlib import Path
from unittest import mock

from installer.steps import PORTED, obsidian

from .support import StepCase

RELEASES = (
    "https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/desktop-releases.json"
)
DOWNLOAD = "https://github.com/obsidianmd/obsidian-releases/releases/download"
LISTING = """{
    "minimumVersion": "0.14.5",
    "latestVersion": "1.13.7",
    "beta": {
        "latestVersion": "1.14.0"
    }
}
"""
HINT = (
    "[install] Obsidian CLI needs a one-time manual step: open Obsidian, then\n"
    "[install]   Settings -> General -> enable 'Command line interface'\n"
    "[install]   and follow the prompt to register it (installs the 'obsidian' command)\n"
)
NOTE = "[install] Obsidian CLI linked as 'obsidian'; it needs the app running to do anything\n"


class ObsidianCase(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.app = Path(self.scratch) / "Obsidian.app"
        for name, value in (("APP", self.app), ("BOOTSTRAP_WAIT", 0.0)):
            patch = mock.patch.object(obsidian, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def app_step(self, **kwargs: object) -> bool:
        return self.run_action(obsidian.install_obsidian, **kwargs)

    def sync_step(self, **kwargs: object) -> bool:
        return self.run_action(obsidian.install_obsync, **kwargs)


class ObsidianLinuxTest(ObsidianCase):
    def setUp(self) -> None:
        super().setUp()
        self.env["DISPLAY"] = ":0"
        self.serve(RELEASES, LISTING)

    def test_headless(self) -> None:
        del self.env["DISPLAY"]
        self.assertTrue(self.app_step())
        self.assertEqual(
            self.said(),
            "[install] Obsidian: no display session detected; skipping on headless Linux\n",
        )
        self.assertEqual(self.requests(), [])

    def test_the_deb_of_the_desktop_version(self) -> None:
        self.fake("dpkg", "#!/bin/sh\nexit 1\n")
        self.recording("apt-get")
        self.serve(f"{DOWNLOAD}/v1.13.7/obsidian_1.13.7_amd64.deb", b"deb")
        self.assertTrue(self.app_step())
        self.assertEqual(self.said(), "[install] Installing Obsidian 1.13.7\n" + HINT)
        (call,) = self.called()
        self.assertTrue(call.startswith("apt-get install -y /"))
        self.assertTrue(call.endswith("/obsidian_1.13.7_amd64.deb"))

    def test_an_installed_deb(self) -> None:
        self.fake("dpkg", "#!/bin/sh\nexit 0\n")
        self.fake("dpkg-query", "#!/bin/sh\nprintf 1.13.7\n")
        self.recording("apt-get")
        self.assertTrue(self.app_step())
        self.assertTrue(self.app_step(upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Obsidian 1.13.7 already installed; skipping\n"
            + HINT
            + "[install] Obsidian 1.13.7 already at latest; skipping\n"
            + HINT,
        )
        self.assertEqual(self.called(), [])

    def test_an_older_deb_is_upgraded(self) -> None:
        self.fake("dpkg", "#!/bin/sh\nexit 0\n")
        self.fake("dpkg-query", "#!/bin/sh\nprintf 1.12.0\n")
        self.recording("apt-get")
        self.serve(f"{DOWNLOAD}/v1.13.7/obsidian_1.13.7_amd64.deb", b"deb")
        self.assertTrue(self.app_step(upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading Obsidian to 1.13.7\n" + HINT)
        self.assertEqual(len(self.called()), 1)

    def test_a_listing_without_a_version(self) -> None:
        self.serve(RELEASES, "{}\n")
        self.assertFalse(self.app_step())
        self.assertIn("no latestVersion in desktop-releases.json", self.said())

    def test_the_arm64_tarball(self) -> None:
        self.recording("chown", failing="root:root")
        files = {
            "obsidian-1.13.7-arm64/obsidian": "#!/bin/sh\n",
            "obsidian-1.13.7-arm64/chrome-sandbox": "",
        }
        self.serve(f"{DOWNLOAD}/v1.13.7/obsidian-1.13.7-arm64.tar.gz", self.tarball(files))
        self.assertTrue(self.app_step(machine="aarch64"))
        self.assertEqual(
            self.said(),
            "[install] Installing Obsidian 1.13.7\n"
            "[install] Obsidian: could not setuid chrome-sandbox; skipping"
            " (launch with --no-sandbox if the app refuses to start)\n" + HINT,
        )
        dest = self.home / ".local/share/obsidian"
        self.assertEqual((dest / ".version").read_text(), "1.13.7\n")
        launcher = self.home / ".local/bin/obsidian-app"
        self.assertEqual(os.readlink(launcher), str(dest / "obsidian"))
        self.assertEqual(self.called(), [f"chown root:root {dest}/chrome-sandbox"])

        self.assertTrue(self.app_step(machine="aarch64"))
        self.assertIn("[install] Obsidian 1.13.7 already installed; skipping\n", self.said())

    def test_a_tarball_without_the_binary(self) -> None:
        files = {"obsidian-1.13.7-arm64/readme": ""}
        self.serve(f"{DOWNLOAD}/v1.13.7/obsidian-1.13.7-arm64.tar.gz", self.tarball(files))
        self.assertFalse(self.app_step(machine="aarch64"))
        self.assertIn("upstream layout changed", self.said())
        self.assertFalse((self.home / ".local/share/obsidian").exists())

    def test_another_architecture(self) -> None:
        self.assertTrue(self.app_step(machine="riscv64"))
        self.assertEqual(
            self.said(), "[install] Unsupported arch riscv64 for Obsidian install; skipping\n"
        )


# A brew whose cask is installed when $HOME/cask exists, and which reports the
# cask's version as 1.13.7.
BREW = """#!/bin/sh
case "$*" in
    "list --cask obsidian") [ -e "$HOME/cask" ]; exit ;;
    "info --cask --json=v2 obsidian") echo '{"casks": [{"version": "1.13.7"}]}'; exit ;;
esac
echo "brew $*" >>"$FAKE_CALLS"
[ "$*" != "$FAKE_BREW_FAILS" ]
"""


class ObsidianMacosTest(ObsidianCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake("brew", BREW)

    def mac(self, **kwargs: object) -> bool:
        return self.app_step(system="Darwin", machine="arm64", **kwargs)

    def bundle(self, version: str) -> None:
        self.app.mkdir()
        buddy = self.fake("PlistBuddy", f"#!/bin/sh\necho {version}\n")
        patch = mock.patch.object(obsidian, "PLIST_BUDDY", str(buddy))
        patch.start()
        self.addCleanup(patch.stop)

    def test_install(self) -> None:
        self.assertTrue(self.mac())
        self.assertEqual(self.said(), "[install] Installing Obsidian\n" + NOTE)
        self.assertEqual(self.called(), ["brew install --cask obsidian"])

    def test_a_failed_install(self) -> None:
        self.env["FAKE_BREW_FAILS"] = "install --cask obsidian"
        self.assertFalse(self.mac())

    def test_present(self) -> None:
        (self.home / "cask").touch()
        self.assertTrue(self.mac())
        self.assertEqual(self.said(), "[install] Obsidian already installed; skipping\n" + NOTE)
        self.assertEqual(self.called(), [])

    def test_a_failed_upgrade_is_not_a_failure(self) -> None:
        (self.home / "cask").touch()
        self.env["FAKE_BREW_FAILS"] = "upgrade --cask obsidian"
        self.assertTrue(self.mac(upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading Obsidian\n" + NOTE)
        self.assertEqual(self.called(), ["brew upgrade --cask obsidian"])

    def test_a_hand_installed_app_at_the_cask_version_is_adopted(self) -> None:
        self.bundle("1.13.7")
        self.assertTrue(self.mac())
        self.assertEqual(
            self.said(), "[install] Adopting the existing Obsidian 1.13.7 into brew\n" + NOTE
        )
        self.assertEqual(self.called(), ["brew install --cask --adopt obsidian"])

    def test_a_hand_installed_app_at_another_version_is_left(self) -> None:
        self.bundle("1.12.0")
        self.assertTrue(self.mac())
        self.assertEqual(
            self.said(),
            "[install] Obsidian 1.12.0 at /Applications was not installed by brew;"
            " leaving it alone\n"
            "[install]   to hand it over: rm -rf /Applications/Obsidian.app"
            " && brew install --cask obsidian\n" + HINT,
        )
        self.assertEqual(self.called(), [])

    def test_a_failed_adoption_leaves_the_app(self) -> None:
        self.bundle("1.13.7")
        self.env["FAKE_BREW_FAILS"] = "install --cask --adopt obsidian"
        self.assertTrue(self.mac())
        self.assertIn("[install] Obsidian 1.13.7 at /Applications was not installed", self.said())


# A git that clones by making the directory, and answers for the vault's
# remote when $HOME/remote exists.
GIT = """#!/bin/sh
echo "git $*" >>"$FAKE_CALLS"
case "$*" in
    clone*) for last; do :; done; mkdir -p "$last/.git" ;;
    *"remote get-url personal") [ -e "$HOME/remote" ] && echo ssh://forge/vault ;;
esac
"""
# A crontab kept in $HOME/crontab.
CRONTAB = """#!/bin/sh
if [ "$1" = -l ]; then
    [ -f "$HOME/crontab" ] || { echo "no crontab for user" >&2; exit 1; }
    cat "$HOME/crontab"
else
    cat >"$HOME/crontab"
fi
"""


class ObsyncTest(ObsidianCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake("git", GIT)
        self.dir = self.home / "projects/obsync"
        self.vault = self.home / "projects/obsidian-vault"
        self.line = (
            f"*/15 * * * * cd {self.dir} && /bin/bash obsync.sh {self.vault}"
            f" >> {self.home}/.local/share/obsync/cron.log 2>&1"
        )

    def vault_ready(self) -> None:
        (self.vault / ".git").mkdir(parents=True)
        (self.home / "remote").touch()

    def test_clone_without_a_vault(self) -> None:
        self.assertTrue(self.sync_step())
        self.assertEqual(
            self.said(),
            "[install] Cloning obsync\n"
            f"[install] obsync: no vault at {self.vault}; skipping schedule\n"
            "[install]   clone it there first, naming the remote 'personal':\n"
            f"[install]     git clone -o personal <vault-url> {self.vault}\n",
        )
        self.assertEqual(
            self.called(), [f"git clone https://github.com/benmandrew/obsync.git {self.dir}"]
        )

    def test_a_vault_without_the_remote(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        (self.vault / ".git").mkdir(parents=True)
        self.assertTrue(self.sync_step())
        self.assertEqual(
            self.said(),
            "[install] obsync already cloned; skipping\n"
            "[install] obsync: vault has no 'personal' remote; skipping schedule\n"
            f"[install]   git -C {self.vault} remote add personal <vault-url>\n",
        )

    def test_upgrade(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        self.assertTrue(self.sync_step(upgrade=True))
        git = f"git -c safe.directory={self.dir} -C {self.dir}"
        self.assertEqual(self.called(), [f"{git} fetch origin", f"{git} reset --hard origin/main"])
        self.assertTrue(self.said().startswith("[install] Upgrading obsync\n"))

    def test_a_failed_clone(self) -> None:
        self.fake("git", "#!/bin/sh\nexit 128\n")
        self.assertFalse(self.sync_step())

    def test_cron_without_crontab(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        self.vault_ready()
        self.assertTrue(self.sync_step())
        self.assertIn("[install] obsync: no crontab command; skipping schedule\n", self.said())

    def test_cron_entry(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        self.vault_ready()
        self.fake("crontab", CRONTAB)
        self.assertTrue(self.sync_step())
        self.assertIn("[install] Installing obsync cron entry (every 15 minutes)\n", self.said())
        marker = "# obsync: managed by dotfiles install"
        self.assertEqual((self.home / "crontab").read_text(), f"{marker}\n{self.line}\n")
        self.assertTrue((self.home / ".local/share/obsync").is_dir())

        self.assertTrue(self.sync_step())
        self.assertIn("[install] obsync cron entry already installed; skipping\n", self.said())

    def test_cron_replaces_an_earlier_entry_and_keeps_the_rest(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        self.vault_ready()
        self.fake("crontab", CRONTAB)
        (self.home / "crontab").write_text(
            "MAILTO=me\n*/5 * * * * cd /old && bash obsync.sh /vault\n0 4 * * * backup\n"
        )
        self.assertTrue(self.sync_step())
        self.assertEqual(
            (self.home / "crontab").read_text(),
            f"MAILTO=me\n0 4 * * * backup\n# obsync: managed by dotfiles install\n{self.line}\n",
        )

    def launchctl(self, loaded: bool = False, bootstrap_fails: int = 0) -> None:
        (self.home / "bootstrap-fails").write_text(f"{bootstrap_fails}\n")
        self.fake(
            "launchctl",
            '#!/bin/sh\necho "launchctl $*" >>"$FAKE_CALLS"\ncase "$1" in\n'
            f"    print) exit {0 if loaded else 1} ;;\n"
            "    bootout) exit 1 ;;\n"
            '    bootstrap) n=$(cat "$HOME/bootstrap-fails"); [ "$n" -gt 0 ] || exit 0\n'
            '        echo $((n - 1)) >"$HOME/bootstrap-fails"; exit 5 ;;\n'
            "esac\n",
        )

    def mac_sync(self) -> bool:
        return self.sync_step(system="Darwin", machine="arm64")

    def test_launch_agent(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        self.vault_ready()
        self.launchctl(bootstrap_fails=2)
        self.fake("crontab", CRONTAB)
        (self.home / "crontab").write_text(f"MAILTO=me\n{self.line}\n")
        self.assertTrue(self.mac_sync())
        self.assertEqual(
            self.said(),
            "[install] obsync already cloned; skipping\n"
            "[install] Installing obsync LaunchAgent (every 15 minutes)\n"
            "[install] Removing obsync crontab entry\n",
        )
        plist = self.home / "Library/LaunchAgents/com.benmandrew.obsync.plist"
        text = plist.read_text()
        self.assertTrue(text.startswith('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE'))
        self.assertTrue(text.endswith("</dict>\n</plist>\n"))
        self.assertIn(f"        <string>{self.dir}/obsync.sh</string>\n", text)
        self.assertIn("    <key>StartInterval</key><integer>900</integer>\n", text)
        service = f"gui/{os.getuid()}/com.benmandrew.obsync"
        launchctl = [call for call in self.called() if call.startswith("launchctl")]
        self.assertEqual(
            launchctl,
            [f"launchctl bootout {service}"]
            + [f"launchctl bootstrap gui/{os.getuid()} {plist}"] * 3,
        )
        self.assertEqual((self.home / "crontab").read_text(), "MAILTO=me\n")

        self.launchctl(loaded=True)
        self.assertTrue(self.mac_sync())
        self.assertTrue(
            self.said().endswith(
                "[install] obsync LaunchAgent already loaded and unchanged; skipping\n"
            )
        )

    def test_a_launch_agent_that_never_loads(self) -> None:
        (self.dir / ".git").mkdir(parents=True)
        self.vault_ready()
        self.launchctl(bootstrap_fails=9)
        self.fake("crontab", CRONTAB)
        (self.home / "crontab").write_text(f"{self.line}\n")
        self.assertFalse(self.mac_sync())
        self.assertIn("still failing after 5 attempts", self.said())
        # The crontab entry stays, so the machine is still scheduled.
        self.assertEqual((self.home / "crontab").read_text(), f"{self.line}\n")


class StackTest(ObsidianCase):
    def test_a_failed_app_install_still_sets_up_obsync(self) -> None:
        self.env["DISPLAY"] = ":0"
        self.fake("git", GIT)
        self.assertFalse(self.run_step(PORTED["install_obsidian_stack"]))
        said = self.said()
        self.assertIn("Download failed", said)
        self.assertIn("[install] Cloning obsync\n", said)
        self.assertLess(said.index("Download failed"), said.index("Cloning obsync"))

    def test_a_file_error_in_the_app_install_still_sets_up_obsync(self) -> None:
        self.fake("git", GIT)
        denied = PermissionError(13, "Permission denied", "/opt/obsidian")
        with mock.patch.object(obsidian, "install_obsidian", side_effect=denied):
            self.assertFalse(self.run_step(PORTED["install_obsidian_stack"]))
        said = self.said()
        self.assertIn("Permission denied: '/opt/obsidian'\n", said)
        self.assertIn("[install] Cloning obsync\n", said)

    def test_both_halves(self) -> None:
        self.fake("git", GIT)
        self.assertTrue(self.run_step(PORTED["install_obsidian_stack"]))
        self.assertTrue(
            self.said().startswith(
                "[install] Obsidian: no display session detected; skipping on headless Linux\n"
                "[install] Cloning obsync\n"
            )
        )
