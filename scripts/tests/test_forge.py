from __future__ import annotations

import json

from installer.steps import STEPS

from .support import StepCase, prints

UUID = "forge@jmmaranan.com"
INFO = f"https://extensions.gnome.org/extension-info/?uuid={UUID}&shell_version=42"
ZIP = f"https://extensions.gnome.org/download-extension/{UUID}.shell-extension.zip"

# Stands in for `gnome-extensions install --force <zip>`. The served "zip" is
# the metadata.json itself, which is all the step reads back.
GNOME_EXTENSIONS = f"""#!/bin/sh
echo "gnome-extensions $*" >>"$FAKE_CALLS"
dir="$HOME/.local/share/gnome-shell/extensions/{UUID}"
mkdir -p "$dir"
cp "$3" "$dir/metadata.json"
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


class ForgeTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake("gnome-shell", prints("GNOME Shell 42.9"))
        self.fake("gnome-extensions", GNOME_EXTENSIONS)
        self.fake("gsettings", GSETTINGS)
        self.env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/1000/bus"
        self.extension = self.home / ".local/share/gnome-shell/extensions" / UUID

    def offer(self, version: int) -> None:
        tag = 40000 + version
        self.serve(
            INFO,
            json.dumps(
                {
                    "version": version,
                    "download_url": f"/download-extension/{UUID}.shell-extension.zip"
                    f"?version_tag={tag}",
                }
            ),
        )
        self.serve(f"{ZIP}?version_tag={tag}", json.dumps({"uuid": UUID, "version": version}))

    def setting(self, key: str) -> str:
        return (self.home / "dconf" / key).read_text()

    def test_install_then_skip(self) -> None:
        self.offer(68)
        (self.home / "dconf").mkdir()
        (self.home / "dconf/enabled-extensions").write_text("['other@example.com']\n")
        self.assertTrue(self.run_step(STEPS["install_forge_extension"]))
        self.assertEqual(json.loads((self.extension / "metadata.json").read_text())["version"], 68)
        self.assertEqual(self.setting("enabled-extensions"), f"['other@example.com', '{UUID}']\n")

        requests = len(self.requests())
        self.assertTrue(self.run_step(STEPS["install_forge_extension"]))
        self.assertEqual(
            self.said(),
            "[install] Installing Forge 68\n"
            "[install] Enabled Forge; it starts at the next login\n"
            "[install] Forge already installed; skipping\n",
        )
        self.assertEqual(len(self.requests()), requests)
        # Enabled once, not appended again.
        self.assertEqual(
            [call for call in self.called() if call.startswith("gsettings")],
            [f"gsettings set enabled-extensions ['other@example.com', '{UUID}']"],
        )

    def test_disabled_entry_is_cleared(self) -> None:
        self.offer(68)
        (self.home / "dconf").mkdir()
        (self.home / "dconf/disabled-extensions").write_text(f"['{UUID}', 'b@example.com']\n")
        self.assertTrue(self.run_step(STEPS["install_forge_extension"]))
        self.assertEqual(self.setting("disabled-extensions"), "['b@example.com']\n")
        self.assertEqual(self.setting("enabled-extensions"), f"['{UUID}']\n")

    def test_upgrade(self) -> None:
        self.offer(67)
        self.assertTrue(self.run_step(STEPS["install_forge_extension"]))
        self.offer(67)
        self.assertTrue(self.run_step(STEPS["install_forge_extension"], upgrade=True))
        self.offer(68)
        self.assertTrue(self.run_step(STEPS["install_forge_extension"], upgrade=True))
        self.assertEqual(json.loads((self.extension / "metadata.json").read_text())["version"], 68)
        self.assertEqual(
            self.said(),
            "[install] Installing Forge 67\n"
            "[install] Enabled Forge; it starts at the next login\n"
            "[install] Forge 67 already at latest; skipping\n"
            "[install] Upgrading Forge to 68\n",
        )

    def test_no_session_bus(self) -> None:
        del self.env["DBUS_SESSION_BUS_ADDRESS"]
        self.offer(68)
        self.assertTrue(self.run_step(STEPS["install_forge_extension"]))
        self.assertTrue((self.extension / "metadata.json").is_file())
        self.assertEqual(
            self.said(),
            "[install] Installing Forge 68\n"
            "[install] Forge: no session bus; installed but not enabled."
            f" Run `gnome-extensions enable {UUID}` from a desktop session\n",
        )
        self.assertFalse((self.home / "dconf/enabled-extensions").exists())

    def test_no_gnome_shell(self) -> None:
        (self.bin / "gnome-shell").unlink()
        self.assertTrue(self.run_step(STEPS["install_forge_extension"]))
        self.assertEqual(self.said(), "[install] Forge: no GNOME Shell; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_macos_is_skipped(self) -> None:
        self.assertTrue(
            self.run_step(STEPS["install_forge_extension"], system="Darwin", machine="arm64")
        )
        self.assertEqual(self.said(), "")
        self.assertEqual(self.requests(), [])

    def test_no_release_for_this_shell(self) -> None:
        self.assertFalse(self.run_step(STEPS["install_forge_extension"]))
        self.assertIn(f"ERROR: No Forge release for GNOME Shell 42 from {INFO}", self.said())

    def test_install_that_leaves_nothing_fails(self) -> None:
        self.offer(68)
        self.fake("gnome-extensions", "#!/bin/sh\nexit 0\n")
        self.assertFalse(self.run_step(STEPS["install_forge_extension"]))
        self.assertIn(f"ERROR: Forge 68 is not in {self.extension} after installing", self.said())

    def test_other_host_in_reply_is_refused(self) -> None:
        self.serve(INFO, '{"version": 68, "download_url": "https://evil.example/x.zip"}')
        self.assertFalse(self.run_step(STEPS["install_forge_extension"]))
        self.assertIn("ERROR: Forge: unexpected reply from", self.said())
