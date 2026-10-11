from __future__ import annotations

from installer.steps import STEPS, clones

from .support import StepCase


class ClonesTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.recording("git")
        self.data = self.home / ".local" / "share"

    def test_install(self) -> None:
        self.assertTrue(self.run_step(STEPS["install_zinit"]))
        self.assertTrue(self.run_step(STEPS["install_fzf_tab"]))
        self.assertEqual(self.said(), "[install] Installing zinit\n[install] Installing fzf-tab\n")
        self.assertEqual(
            self.called(),
            [
                # zinit updates itself from its clone, so it gets the history.
                "git clone https://github.com/zdharma-continuum/zinit.git"
                f" {self.data}/zinit/zinit.git",
                f"git clone --depth 1 https://github.com/Aloxaf/fzf-tab.git {self.data}/fzf-tab",
            ],
        )
        self.assertTrue((self.data / "zinit").is_dir())

    def test_present(self) -> None:
        for clone in clones.CLONES:
            (self.data / clone.directory / ".git").mkdir(parents=True)
            self.assertTrue(self.run_step(STEPS[clone.step]))
        self.assertEqual(
            self.said(),
            "[install] zinit already installed; skipping\n"
            "[install] fzf-tab already installed; skipping\n"
            "[install] zsh-autosuggestions already installed; skipping\n"
            "[install] fzf-git.sh already installed; skipping\n",
        )
        self.assertEqual(self.called(), [])

    def test_upgrade_resets_to_the_remote_branch(self) -> None:
        self.env["XDG_DATA_HOME"] = str(self.home / "data")
        directory = self.home / "data" / "fzf-git.sh"
        (directory / ".git").mkdir(parents=True)
        self.assertTrue(self.run_step(STEPS["install_fzf_git"], upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading fzf-git.sh\n")
        git = f"git -c safe.directory={directory} -C {directory}"
        self.assertEqual(self.called(), [f"{git} fetch origin", f"{git} reset --hard origin/main"])

    def test_a_failed_fetch_fails_the_step(self) -> None:
        (self.data / "fzf-tab" / ".git").mkdir(parents=True)
        self.fake("git", '#!/bin/sh\necho "git $*" >>"$FAKE_CALLS"\nexit 1\n')
        self.assertFalse(self.run_step(STEPS["install_fzf_tab"], upgrade=True))
        self.assertEqual(len(self.called()), 1)


FZF_INSTALL = """#!/bin/sh
echo "install $*" >>"$FAKE_CALLS"
mkdir -p "$HOME/.fzf/bin"
printf '#!/bin/sh\\n' >"$HOME/.fzf/bin/fzf"
chmod +x "$HOME/.fzf/bin/fzf"
"""


class FzfTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.recording("git")

    def test_install_over_an_existing_clone(self) -> None:
        self.fake("install", FZF_INSTALL, self.home / ".fzf")
        self.assertTrue(self.run_step(STEPS["install_fzf"]))
        self.assertEqual(
            self.said(), "[install] Installing fzf\n[install] fzf already cloned; skipping\n"
        )
        self.assertEqual(self.called(), ["install --bin --no-update-rc --no-bash --no-fish"])

    def test_a_clone_that_did_not_arrive_fails_the_step(self) -> None:
        self.assertFalse(self.run_step(STEPS["install_fzf"]))
        self.assertEqual(self.called(), [f"git clone --depth 1 {clones.FZF_URL} {self.home}/.fzf"])

    def test_upgrade(self) -> None:
        self.fake("fzf", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_fzf"]))
        self.assertEqual(self.said(), "[install] fzf already installed; skipping\n")
        # An fzf with no clone behind it is somebody else's to upgrade.
        self.assertTrue(self.run_step(STEPS["install_fzf"], upgrade=True))
        self.assertEqual(self.called(), [])
        self.fake("install", FZF_INSTALL, self.home / ".fzf")
        self.assertTrue(self.run_step(STEPS["install_fzf"], upgrade=True))
        root = self.home / ".fzf"
        self.assertEqual(self.called()[0], f"git -c safe.directory={root} -C {root} pull")
        self.assertIn(f"Note: fzf on PATH is {self.bin}/fzf", self.said())


class TmuxPluginsTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.recording("git")
        self.tpm = self.home / ".tmux" / "plugins" / "tpm"

    def test_install_before_chezmoi_apply(self) -> None:
        self.assertTrue(self.run_step(STEPS["install_tmux_plugins"]))
        self.assertEqual(self.said(), "[install] Installing tmux plugin manager (tpm)\n")
        self.assertEqual(self.called(), [f"git clone {clones.TPM_URL} {self.tpm}"])

    def test_plugins_wait_for_a_config_that_sources_tpm(self) -> None:
        self.fake("install_plugins", '#!/bin/sh\necho plugins >>"$FAKE_CALLS"\n', self.tpm / "bin")
        self.assertTrue(self.run_step(STEPS["install_tmux_plugins"]))
        self.assertEqual(
            self.said(),
            "[install] tmux plugin manager (tpm) already installed; skipping\n"
            "[install] No ~/.tmux.conf sourcing tpm yet; skipping plugin install"
            " (re-run after chezmoi apply)\n",
        )
        (self.home / ".tmux.conf").write_text("run '~/.tmux/plugins/tpm/tpm'\n")
        self.assertTrue(self.run_step(STEPS["install_tmux_plugins"], upgrade=True))
        self.assertIn("[install] Installing tmux plugins\n", self.said())
        self.assertEqual(self.called()[-1], "plugins")
        self.assertEqual(len(self.called()), 3)
