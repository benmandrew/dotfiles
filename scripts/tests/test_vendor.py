from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer.steps import STEPS, vendor

from .support import StepCase


def installs(name: str, directory: str = "$HOME/.local/bin") -> str:
    """A vendor install script: records its arguments and leaves `name` behind."""
    return (
        f'#!/bin/sh\necho "{name}-installer $* bin_path=$bin_path" >>"$FAKE_CALLS"\n'
        f'mkdir -p "{directory}"\n'
        f"printf '#!/bin/sh\\n' >\"{directory}/{name}\"\n"
        f'chmod +x "{directory}/{name}"\n'
    )


class VendorTest(StepCase):
    def test_uv(self) -> None:
        self.serve(vendor.UV_URL, installs("uv"))
        self.assertTrue(self.run_step(STEPS["install_uv"]))
        self.assertEqual(self.said(), "[install] Installing uv\n")
        # The steps that follow find uv.
        self.assertTrue(self.env["PATH"].startswith(f"{self.home}/.local/bin:"))
        self.assertTrue(self.run_step(STEPS["install_uv"]))
        self.assertIn("[install] uv already installed; skipping\n", self.said())

    def test_uv_upgrades_itself(self) -> None:
        self.recording("uv")
        self.assertTrue(self.run_step(STEPS["install_uv"], upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading uv\n")
        self.assertEqual(self.called(), ["uv self update", "uv --version"])
        self.assertEqual(self.requests(), [])

    def test_starship_goes_to_local_bin(self) -> None:
        self.serve(vendor.STARSHIP_URL, installs("starship"))
        self.assertTrue(self.run_step(STEPS["install_starship"]))
        self.assertEqual(self.said(), "[install] Installing Starship\n")
        self.assertEqual(
            self.called(), [f"starship-installer -y -b {self.home}/.local/bin bin_path="]
        )

    def test_starship_removes_the_copy_it_used_to_install(self) -> None:
        stale = self.fake("starship", "#!/bin/sh\n", Path(self.scratch) / "usr-local-bin")
        self.serve(vendor.STARSHIP_URL, installs("starship"))
        with mock.patch.object(vendor, "STALE_STARSHIP", stale):
            self.assertTrue(self.run_step(STEPS["install_starship"]))
        self.assertEqual(
            self.said(),
            "[install] Installing Starship\n"
            f"[install] Removing stale {stale}, superseded by {self.home}/.local/bin/starship\n",
        )
        self.assertFalse(stale.exists())

    def test_starship_present(self) -> None:
        self.fake("starship", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_starship"]))
        self.assertEqual(self.said(), "[install] Starship already installed; skipping\n")

    def test_direnv_is_told_where_to_go(self) -> None:
        self.serve(vendor.DIRENV_URL, installs("direnv"))
        self.assertTrue(self.run_step(STEPS["install_direnv"]))
        self.assertEqual(self.said(), "[install] Installing direnv\n")
        self.assertEqual(self.called(), [f"direnv-installer  bin_path={self.home}/.local/bin"])

    def test_a_truncated_direnv_is_reinstalled(self) -> None:
        self.fake("direnv", "#!/bin/sh\nexit 126\n")
        self.serve(vendor.DIRENV_URL, installs("direnv"))
        self.assertTrue(self.run_step(STEPS["install_direnv"]))
        self.assertIn("[install] Installing direnv\n", self.said())

    def test_claude_code(self) -> None:
        self.serve(vendor.CLAUDE_URL, installs("claude"))
        self.assertTrue(self.run_step(STEPS["install_claude_code"]))
        self.assertEqual(self.said(), "[install] Installing Claude Code\n")
        self.fake("claude", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_claude_code"]))
        self.assertIn("[install] Claude Code already installed; skipping\n", self.said())

    def test_claude_code_upgrade_names_an_npm_install(self) -> None:
        package = self.home / "lib" / "node_modules" / "claude" / "cli.js"
        self.fake("cli.js", '#!/bin/sh\necho "claude $*" >>"$FAKE_CALLS"\n', package.parent)
        (self.bin / "claude").symlink_to(package)
        self.assertTrue(self.run_step(STEPS["install_claude_code"], upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Upgrading Claude Code\n"
            f"[install] Claude Code is an npm install ({package}); run 'claude install' to"
            " switch to the native build\n"
            f"[install] Note: claude on PATH is {self.bin}/claude, which shadows the copy just"
            f" installed at {self.home}/.local/bin/claude\n",
        )
        self.assertEqual(self.called(), ["claude update", "claude --version"])

    def test_claude_code_upgrade_must_leave_a_binary_that_runs(self) -> None:
        # The update exits 0 and leaves a placeholder behind.
        self.fake("claude", '#!/bin/sh\n[ "$1" = update ]\n')
        self.assertFalse(self.run_step(STEPS["install_claude_code"], upgrade=True))
        said = self.said()
        self.assertIn("ERROR: claude does not run after installing", said)
        self.assertIn("ERROR: Reinstall Claude Code with https://claude.ai/install.sh\n", said)

    def test_tailscale_on_linux(self) -> None:
        self.serve(vendor.TAILSCALE_URL, installs("tailscale", str(self.bin)))
        self.assertTrue(self.run_step(STEPS["install_tailscale"]))
        self.assertEqual(self.said(), "[install] Installing Tailscale\n")
        self.assertTrue(self.run_step(STEPS["install_tailscale"]))
        self.assertIn("[install] Tailscale already installed; skipping\n", self.said())

    def test_tailscale_on_macos_is_a_cask(self) -> None:
        self.recording("brew", failing="list")
        self.assertTrue(self.run_step(STEPS["install_tailscale"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] Installing Tailscale\n")
        self.assertEqual(
            self.called(), ["brew list --cask tailscale", "brew install --cask tailscale"]
        )
        self.recording("brew")
        self.assertTrue(
            self.run_step(
                STEPS["install_tailscale"], system="Darwin", machine="arm64", upgrade=True
            )
        )
        self.assertEqual(self.called()[-1], "brew upgrade --cask tailscale")
