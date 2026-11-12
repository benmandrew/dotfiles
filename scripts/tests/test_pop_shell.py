from __future__ import annotations

import json

from installer.steps import STEPS
from installer.steps.pop_shell import COMMIT, FORGE_UUID, UUID

from .support import StepCase, prints

TIP = "1" * 40
REMOTE = "https://github.com/pop-os/shell.git"

# Stands in for `npm install --prefix <dir> typescript@...`, leaving a tsc.
NPM = """#!/bin/sh
echo "npm $*" >>"$FAKE_CALLS"
while [ "$1" != "--prefix" ]; do shift; done
mkdir -p "$2/node_modules/.bin"
printf '#!/bin/sh\\n' >"$2/node_modules/.bin/tsc"
chmod +x "$2/node_modules/.bin/tsc"
"""

# Stands in for `make compile`, which needs tsc on PATH and leaves _build.
MAKE = f"""#!/bin/sh
echo "make $*" >>"$FAKE_CALLS"
command -v tsc >/dev/null || exit 1
mkdir -p _build
printf '{{"uuid": "{UUID}", "version": 2}}' >_build/metadata.json
: >_build/extension.js
"""

# gsettings over one file per key, as dconf would keep them.
GSETTINGS = """#!/bin/sh
store="$HOME/dconf"
mkdir -p "$store"
case "$1" in
    get) if [ -f "$store/$3" ]; then cat "$store/$3"; else echo '@as []'; fi ;;
    set) echo "gsettings set $3 $4" >>"$FAKE_CALLS"; printf '%s\\n' "$4" >"$store/$3" ;;
esac
"""


class PopShellTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake("gnome-shell", prints("GNOME Shell 42.9"))
        self.fake("gnome-extensions", "#!/bin/sh\nexit 0\n")
        self.fake("glib-compile-schemas", "#!/bin/sh\nexit 0\n")
        self.fake("gsettings", GSETTINGS)
        self.fake("npm", NPM)
        self.fake("make", MAKE)
        self.fake("git", f"#!/bin/sh\necho '{TIP}\trefs/heads/master_jammy'\n")
        self.env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/1000/bus"
        self.extension = self.home / ".local/share/gnome-shell/extensions" / UUID

    def offer(self, commit: str) -> None:
        self.serve(
            f"https://github.com/pop-os/shell/archive/{commit}.tar.gz",
            self.tarball({f"shell-{commit}/Makefile": ""}),
        )

    def setting(self, key: str) -> str:
        return (self.home / "dconf" / key).read_text()

    def commit(self) -> str:
        return (self.extension / ".commit").read_text().strip()

    def test_install_then_skip(self) -> None:
        self.offer(COMMIT)
        (self.home / "dconf").mkdir()
        (self.home / "dconf/enabled-extensions").write_text("['other@example.com']\n")
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertEqual(json.loads((self.extension / "metadata.json").read_text())["uuid"], UUID)
        self.assertEqual(self.commit(), COMMIT)
        self.assertEqual(self.setting("enabled-extensions"), f"['other@example.com', '{UUID}']\n")

        requests = len(self.requests())
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertEqual(
            self.said(),
            f"[install] Installing Pop Shell {COMMIT[:7]}\n"
            "[install] Enabled Pop Shell; it starts at the next login\n"
            "[install] Pop Shell already installed; skipping\n",
        )
        self.assertEqual(len(self.requests()), requests)
        # Enabled once, not appended again.
        self.assertEqual(
            [call for call in self.called() if call.startswith("gsettings")],
            [f"gsettings set enabled-extensions ['other@example.com', '{UUID}']"],
        )

    def test_forge_is_disabled(self) -> None:
        self.offer(COMMIT)
        (self.home / "dconf").mkdir()
        (self.home / "dconf/enabled-extensions").write_text(f"['{FORGE_UUID}', 'a@example.com']\n")
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertEqual(self.setting("enabled-extensions"), f"['a@example.com', '{UUID}']\n")
        self.assertIn("[install] Disabled Forge, which Pop Shell replaces\n", self.said())

    def test_disabled_entry_is_cleared(self) -> None:
        self.offer(COMMIT)
        (self.home / "dconf").mkdir()
        (self.home / "dconf/disabled-extensions").write_text(f"['{UUID}', 'b@example.com']\n")
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertEqual(self.setting("disabled-extensions"), "['b@example.com']\n")
        self.assertEqual(self.setting("enabled-extensions"), f"['{UUID}']\n")

    def test_upgrade_takes_the_branch_tip(self) -> None:
        self.offer(COMMIT)
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.offer(TIP)
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"], upgrade=True))
        self.assertEqual(self.commit(), TIP)
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"], upgrade=True))
        self.assertEqual(
            self.said(),
            f"[install] Installing Pop Shell {COMMIT[:7]}\n"
            "[install] Enabled Pop Shell; it starts at the next login\n"
            f"[install] Upgrading Pop Shell to {TIP[:7]}\n"
            f"[install] Pop Shell {TIP[:7]} already at latest; skipping\n",
        )

    def test_no_session_bus(self) -> None:
        del self.env["DBUS_SESSION_BUS_ADDRESS"]
        self.offer(COMMIT)
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertTrue((self.extension / "metadata.json").is_file())
        self.assertEqual(
            self.said(),
            f"[install] Installing Pop Shell {COMMIT[:7]}\n"
            "[install] Pop Shell: no session bus; installed but not enabled."
            f" Run `gnome-extensions enable {UUID}` from a desktop session\n",
        )
        self.assertFalse((self.home / "dconf/enabled-extensions").exists())

    def test_no_gnome_shell(self) -> None:
        (self.bin / "gnome-shell").unlink()
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertEqual(self.said(), "[install] Pop Shell: no GNOME Shell; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_macos_is_skipped(self) -> None:
        self.assertTrue(
            self.run_step(STEPS["install_pop_shell_extension"], system="Darwin", machine="arm64")
        )
        self.assertEqual(self.said(), "")
        self.assertEqual(self.requests(), [])

    def test_newer_shell_is_refused(self) -> None:
        self.fake("gnome-shell", prints("GNOME Shell 46.0"))
        self.assertFalse(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertIn(
            "ERROR: Pop Shell's master_jammy branch supports GNOME Shell 40 to 44, not 46",
            self.said(),
        )
        self.assertEqual(self.requests(), [])

    def test_build_that_leaves_nothing_fails(self) -> None:
        self.offer(COMMIT)
        self.fake("make", "#!/bin/sh\nexit 0\n")
        self.assertFalse(self.run_step(STEPS["install_pop_shell_extension"]))
        self.assertIn("ERROR: Pop Shell: the build left no extension.js", self.said())
        self.assertFalse(self.extension.exists())

    def test_unreadable_branch_tip_fails(self) -> None:
        self.offer(COMMIT)
        self.assertTrue(self.run_step(STEPS["install_pop_shell_extension"]))
        self.fake("git", "#!/bin/sh\nexit 2\n")
        self.assertFalse(self.run_step(STEPS["install_pop_shell_extension"], upgrade=True))
        self.assertIn("ERROR: Pop Shell: could not read the tip of master_jammy from", self.said())
        self.assertEqual(self.commit(), COMMIT)
