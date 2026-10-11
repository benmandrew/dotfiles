from __future__ import annotations

from dataclasses import replace

from installer.steps import STEPS

from .support import StepCase

# A dpkg that knows two packages.
DPKG = '#!/bin/sh\ncase "$2" in git | curl) exit 0 ;; esac\nexit 1\n'


class AptPackagesTest(StepCase):
    def run_apt(self, *packages: str, upgrade: bool = False) -> bool:
        step = replace(STEPS["install_apt_packages_if_missing"], args=packages)
        return self.run_step(step, upgrade=upgrade)

    def setUp(self) -> None:
        super().setUp()
        self.fake("dpkg", DPKG)
        self.recording("apt-get")

    def test_only_the_missing_are_installed(self) -> None:
        self.assertTrue(self.run_apt("git", "zsh", "curl", "entr"))
        self.assertEqual(self.said(), "[install] Installing missing base packages: zsh entr\n")
        self.assertEqual(self.called(), ["apt-get update", "apt-get install -y zsh entr"])

    def test_nothing_missing(self) -> None:
        self.assertTrue(self.run_apt("git", "curl"))
        self.assertEqual(self.said(), "[install] Base packages already installed; skipping\n")
        self.assertEqual(self.called(), [])

    def test_upgrade_takes_the_whole_list(self) -> None:
        self.assertTrue(self.run_apt("git", "zsh", upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading base packages: git zsh\n")
        self.assertEqual(self.called(), ["apt-get update", "apt-get install -y git zsh"])

    def test_a_failed_update_fails_the_step(self) -> None:
        self.recording("apt-get", failing="update")
        self.assertFalse(self.run_apt("zsh"))
        self.assertEqual(self.called(), ["apt-get update"])


class BrewFormulaeTest(StepCase):
    def run_brew(self, *formulae: str, upgrade: bool = False) -> bool:
        step = replace(STEPS["install_brew_formulae_if_missing"], args=formulae)
        return self.run_step(step, upgrade=upgrade, system="Darwin", machine="arm64")

    def test_missing_formulae_are_installed(self) -> None:
        self.recording("brew", failing="list")
        self.assertTrue(self.run_brew("git", "zsh"))
        self.assertEqual(self.said(), "[install] Installing missing Homebrew formulae: git zsh\n")
        self.assertEqual(self.called()[-2:], ["brew update", "brew install git zsh"])

    def test_nothing_missing(self) -> None:
        self.recording("brew")
        self.assertTrue(self.run_brew("git", "zsh"))
        self.assertEqual(self.said(), "[install] Homebrew formulae already installed; skipping\n")

    def test_a_failed_batch_upgrade_is_retried_one_formula_at_a_time(self) -> None:
        # The batch fails, tmux fails again on its own, and node is not there.
        self.fake(
            "brew",
            '#!/bin/sh\necho "brew $*" >>"$FAKE_CALLS"\n'
            'case "$*" in\n'
            '    "upgrade git tmux node" | "upgrade tmux" | "list --formula node") exit 1 ;;\n'
            "esac\n",
        )
        self.assertFalse(self.run_brew("git", "tmux", "node", upgrade=True))
        self.assertTrue(
            self.said().startswith(
                "[install] Upgrading Homebrew formulae: git tmux node\n"
                "[install] Batch upgrade failed; retrying each formula on its own\n"
                "[install] ERROR: Homebrew formulae failed: tmux\n"
            )
        )
        self.assertTrue(
            self.said().endswith(
                "[install] ERROR: Step failed: install_brew_formulae_if_missing git tmux node\n"
            )
        )
        self.assertIn("brew upgrade git", self.called())
        self.assertIn("brew install node", self.called())


class PackageToolsTest(StepCase):
    def test_jq_from_apt(self) -> None:
        self.installer("apt-get", creates="jq")
        self.assertTrue(self.run_step(STEPS["install_jq"]))
        self.assertEqual(self.said(), "[install] Installing jq\n")
        self.assertEqual(self.called(), ["apt-get install -y jq"])

    def test_jq_present(self) -> None:
        self.fake("jq", "#!/bin/sh\n")
        self.recording("apt-get")
        self.assertTrue(self.run_step(STEPS["install_jq"]))
        self.assertEqual(self.said(), "[install] jq already installed; skipping\n")
        self.assertTrue(self.run_step(STEPS["install_jq"], upgrade=True))
        self.assertEqual(self.called(), ["apt-get install -y jq"])

    def test_jq_that_does_not_run_fails_the_step(self) -> None:
        self.recording("apt-get")
        self.assertFalse(self.run_step(STEPS["install_jq"]))
        self.assertIn("ERROR: jq does not run after installing (not on PATH", self.said())

    def test_jq_from_brew(self) -> None:
        self.installer("brew", creates="jq")
        self.assertTrue(self.run_step(STEPS["install_jq"], system="Darwin", machine="arm64"))
        self.assertEqual(self.called(), ["brew install jq"])
        self.assertTrue(
            self.run_step(STEPS["install_jq"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(self.called()[-1], "brew upgrade jq")

    def test_zstd_needs_the_headers_too(self) -> None:
        self.fake("zstd", "#!/bin/sh\n")
        self.fake("dpkg", "#!/bin/sh\nexit 1\n")
        self.recording("apt-get")
        self.assertTrue(self.run_step(STEPS["install_zstd"]))
        self.assertEqual(self.said(), "[install] Installing zstd\n")
        self.assertEqual(self.called(), ["apt-get install -y zstd libzstd-dev"])

    def test_zstd_with_headers_is_skipped(self) -> None:
        self.fake("zstd", "#!/bin/sh\n")
        self.fake("dpkg", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_zstd"]))
        self.assertEqual(self.said(), "[install] zstd already installed; skipping\n")

    def test_zstd_on_macos_is_one_formula(self) -> None:
        self.fake("zstd", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_zstd"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] zstd already installed; skipping\n")

    def test_clangd_on_macos_is_probed_inside_the_keg(self) -> None:
        keg = self.home / "llvm"
        self.fake(
            "brew",
            '#!/bin/sh\necho "brew $*" >>"$FAKE_CALLS"\n'
            f'[ "$1" = --prefix ] && echo "{keg}"\nexit 0\n',
        )
        self.assertFalse(self.run_step(STEPS["install_clangd"], system="Darwin", machine="arm64"))
        self.assertIn(f"ERROR: {keg}/bin/clangd does not run after installing", self.said())
        self.fake("clangd", "#!/bin/sh\n", keg / "bin")
        self.assertTrue(self.run_step(STEPS["install_clangd"], system="Darwin", machine="arm64"))
        self.assertEqual(self.called()[-2:], ["brew install llvm", "brew --prefix llvm"])

    def test_clangd_from_apt(self) -> None:
        self.installer("apt-get", creates="clangd")
        self.assertTrue(self.run_step(STEPS["install_clangd"]))
        self.assertEqual(self.called(), ["apt-get install -y clangd"])
