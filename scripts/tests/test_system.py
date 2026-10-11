from __future__ import annotations

import os
import pwd
from dataclasses import replace
from pathlib import Path
from unittest import mock

from installer.runner import Fatal
from installer.steps import STEPS, system

from .support import StepCase

USER = pwd.getpwuid(os.geteuid()).pw_name


class SystemCase(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.etc = Path(self.scratch) / "etc"
        self.etc.mkdir()

    def patch(self, name: str, value: object) -> None:
        patch = mock.patch.object(system, name, value)
        patch.start()
        self.addCleanup(patch.stop)


class HomebrewTest(SystemCase):
    def run_homebrew(self) -> bool:
        step = replace(STEPS["install_homebrew"], interactive=True, fatal=True)
        return self.run_step(step, system="Darwin", machine="arm64")

    def test_present(self) -> None:
        self.fake("brew", "#!/bin/sh\n")
        self.assertTrue(self.run_homebrew())
        self.assertEqual(self.said(), "[install] Homebrew already installed\n")
        self.assertEqual(self.requests(), [])

    def test_install_puts_brew_in_the_environment(self) -> None:
        prefix = Path(self.scratch) / "homebrew"
        brew = prefix / "bin" / "brew"
        self.patch("BREW", brew)
        # brew is told which shell to write for, its parent here being python.
        shellenv = (
            f'export HOMEBREW_PREFIX=\\"{prefix}\\";\\nexport PATH=\\"{prefix}/bin:\\$PATH\\";\\n'
        )
        self.serve(
            system.HOMEBREW_URL,
            f'#!/bin/bash\necho "installer" >>"$FAKE_CALLS"\nmkdir -p "{brew.parent}"\n'
            f'printf \'#!/bin/sh\\n[ "$*" = "shellenv bash" ] && printf "{shellenv}"\\n\''
            f' >"{brew}"\nchmod +x "{brew}"\n',
        )
        before = self.env["PATH"]
        self.assertTrue(self.run_homebrew())
        self.assertEqual(self.said(), "[install] Installing Homebrew\n")
        self.assertEqual(self.called(), ["installer"])
        self.assertEqual(self.env["HOMEBREW_PREFIX"], str(prefix))
        self.assertEqual(self.env["PATH"], f"{prefix}/bin:{before}")

    def test_a_failed_installer_fails_the_step(self) -> None:
        self.serve(system.HOMEBREW_URL, "#!/bin/bash\nexit 1\n")
        # The plan marks this step fatal, so its failure ends the run.
        with self.assertRaises(Fatal):
            self.run_homebrew()


class LoginShellTest(SystemCase):
    def setUp(self) -> None:
        super().setUp()
        self.zsh = self.fake("zsh", "#!/bin/sh\n", self.etc / "usr-bin")
        self.shells = self.etc / "shells"
        self.shells.write_text(f"/bin/sh\n{self.zsh}\n")
        self.passwd = self.etc / "passwd"
        self.passwd.write_text(f"root:x:0:0::/root:/bin/sh\n{USER}:x:1000:1000::/home:/bin/bash\n")
        self.patch("ZSH_CANDIDATES", (self.etc / "missing" / "zsh", self.zsh))
        self.patch("SHELLS", self.shells)
        self.patch("PASSWD", self.passwd)
        # An account database of one line, which chsh rewrites.
        self.record = self.etc / "login-shell"
        self.record.write_text("/bin/bash\n")
        self.fake("getent", f'#!/bin/sh\necho "$2:x:1000:1000::/home:$(cat "{self.record}")"\n')
        self.fake("dscl", f'#!/bin/sh\necho "UserShell: $(cat "{self.record}")"\n')
        self.fake(
            "chsh", f'#!/bin/sh\necho "chsh $*" >>"$FAKE_CALLS"\necho "$2" >"{self.record}"\n'
        )

    def test_change(self) -> None:
        self.assertTrue(self.run_step(STEPS["install_login_shell"]))
        self.assertEqual(
            self.said(), f"[install] Changing login shell from /bin/bash to {self.zsh}\n"
        )
        self.assertEqual(self.called(), [f"chsh -s {self.zsh} {USER}"])

    def test_a_listed_zsh_is_kept(self) -> None:
        # One chosen by hand, which is not the system zsh.
        own = self.fake("zsh", "#!/bin/sh\n", self.home / "bin")
        self.record.write_text(f"{own}\n")
        self.shells.write_text(f"{own}\n")
        for system_name in ("Linux", "Darwin"):
            self.assertTrue(self.run_step(STEPS["install_login_shell"], system=system_name))
        line = f"[install] Login shell is already {own}; skipping\n"
        self.assertEqual(self.said(), line * 2)
        self.assertEqual(self.called(), [])

    def test_an_unlisted_shell_is_added_to_etc_shells(self) -> None:
        self.shells.write_text("/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_login_shell"]))
        self.assertEqual(self.shells.read_text(), f"/bin/sh\n{self.zsh}\n")

    def test_an_account_outside_etc_passwd_is_left(self) -> None:
        self.passwd.write_text("root:x:0:0::/root:/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_login_shell"]))
        self.assertEqual(
            self.said(),
            f"[install] {USER} is not in /etc/passwd, so chsh cannot change its shell; skipping\n",
        )
        # macOS keeps its accounts elsewhere, and chsh reaches them.
        self.assertTrue(self.run_step(STEPS["install_login_shell"], system="Darwin"))
        self.assertEqual(self.called(), [f"chsh -s {self.zsh} {USER}"])

    def test_no_zsh(self) -> None:
        self.fake("zsh", "#!/bin/sh\nexit 1\n", self.etc / "usr-bin")
        self.assertFalse(self.run_step(STEPS["install_login_shell"]))
        self.assertIn("ERROR: No working zsh at /usr/bin/zsh or /bin/zsh\n", self.said())

    def test_a_chsh_that_changes_nothing_fails_the_step(self) -> None:
        self.recording("chsh")
        self.assertFalse(self.run_step(STEPS["install_login_shell"]))
        self.assertIn("ERROR: chsh exited 0 but the login shell is still /bin/bash\n", self.said())

    def test_an_unknown_shell(self) -> None:
        self.fake("getent", "#!/bin/sh\nexit 2\n")
        self.recording("chsh")
        self.assertFalse(self.run_step(STEPS["install_login_shell"]))
        self.assertIn(f"[install] Changing login shell from unknown to {self.zsh}\n", self.said())
        self.assertIn("ERROR: chsh exited 0 but the login shell is still unknown\n", self.said())


class PerfTest(SystemCase):
    def test_present(self) -> None:
        self.fake("perf", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_perf"]))
        self.assertEqual(self.said(), "[install] perf already installed; skipping\n")

    def test_the_wrapper_alone_does_not_count(self) -> None:
        self.fake("perf", "#!/bin/sh\necho 'perf not found for kernel' >&2\nexit 2\n")
        self.recording("apt-get")
        kernel_tools = f"linux-tools-{os.uname().release}"
        self.assertTrue(self.run_step(STEPS["install_perf"]))
        self.assertEqual(
            self.said(), f"[install] Installing perf (linux-tools-generic and {kernel_tools})\n"
        )
        self.assertEqual(self.called(), [f"apt-get install -y linux-tools-generic {kernel_tools}"])

    def test_a_kernel_with_no_package_only_warns(self) -> None:
        self.recording("apt-get", failing="install")
        self.assertTrue(self.run_step(replace(STEPS["install_perf"], fatal=True)))
        self.assertIn("(perf); skipping, this is expected on some cloud kernels\n", self.said())


class EtcFilesTest(SystemCase):
    def test_inotify_limits(self) -> None:
        conf = self.etc / "60-inotify-watches.conf"
        self.patch("INOTIFY_CONF", conf)
        self.recording("sysctl")
        self.assertTrue(self.run_step(STEPS["install_inotify_limits"]))
        self.assertEqual(self.said(), "[install] Configuring inotify watch/instance limits\n")
        self.assertEqual(
            conf.read_text(),
            "fs.inotify.max_user_watches = 524288\nfs.inotify.max_user_instances = 512\n",
        )
        self.assertEqual(self.called(), [f"sysctl -p {conf}"])
        self.assertTrue(self.run_step(STEPS["install_inotify_limits"]))
        self.assertIn("[install] inotify limits already configured; skipping\n", self.said())
        self.assertEqual(len(self.called()), 1)

    def test_inotify_limits_that_do_not_load(self) -> None:
        self.patch("INOTIFY_CONF", self.etc / "60-inotify-watches.conf")
        self.recording("sysctl", failing="-p")
        self.assertFalse(self.run_step(STEPS["install_inotify_limits"]))

    def test_vscode_origin(self) -> None:
        conf = self.etc / "51unattended-upgrades-vscode"
        self.patch("VSCODE_ORIGIN_CONF", conf)
        self.assertTrue(self.run_step(STEPS["install_vscode_unattended_upgrades"]))
        self.assertEqual(
            self.said(), "[install] unattended-upgrades not installed; skipping VS Code origin\n"
        )
        self.assertFalse(conf.exists())
        self.fake("unattended-upgrade", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_vscode_unattended_upgrades"]))
        self.assertIn("[install] Allowing unattended-upgrades to update VS Code\n", self.said())
        self.assertEqual(
            conf.read_text(),
            'Unattended-Upgrade::Origins-Pattern { "origin=code stable,archive=stable"; };\n',
        )
        self.assertTrue(self.run_step(STEPS["install_vscode_unattended_upgrades"]))
        self.assertIn(
            "[install] unattended-upgrades already allows VS Code; skipping\n", self.said()
        )
