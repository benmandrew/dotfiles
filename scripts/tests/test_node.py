from __future__ import annotations

from installer.steps import STEPS, node

from .support import StepCase, prints

# An npm that leaves the package's launcher where the pinned prefix puts it.
NPM = """#!/bin/sh
echo "npm $*" >>"$FAKE_CALLS"
if [ "$1" = install ]; then
    mkdir -p "$HOME/.local/bin"
    printf '#!/bin/sh\\n' >"$HOME/.local/bin/$3"
    chmod +x "$HOME/.local/bin/$3"
fi
"""


class NodeTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake("dpkg", "#!/bin/sh\nexit 1\n")
        self.serve(
            node.SETUP_URL,
            '#!/bin/bash\necho "setup DEBIAN_FRONTEND=$DEBIAN_FRONTEND" >>"$FAKE_CALLS"\n',
        )

    def test_new_enough_is_skipped(self) -> None:
        self.fake("node", prints("v22.11.0"))
        self.assertTrue(self.run_step(STEPS["install_node"]))
        self.assertEqual(self.said(), "[install] Node.js 22 already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_install(self) -> None:
        self.installer("apt-get", creates="node", output="v22.11.0")
        self.env["DEBIAN_FRONTEND"] = "noninteractive"
        self.assertTrue(self.run_step(STEPS["install_node"]))
        self.assertEqual(self.said(), "[install] Installing Node.js LTS\n")
        self.assertEqual(
            self.called(), ["setup DEBIAN_FRONTEND=noninteractive", "apt-get install -y nodejs"]
        )

    def test_the_distro_node_is_replaced(self) -> None:
        self.fake("node", prints("v12.22.9"))
        self.fake("dpkg", "#!/bin/sh\n")
        self.installer("apt-get", creates="node", output="v22.11.0")
        self.assertTrue(self.run_step(STEPS["install_node"]))
        self.assertEqual(
            self.said(),
            "[install] Node.js 12 < 20; upgrading to LTS\n"
            "[install] Removing distro libnode-dev (conflicts with NodeSource nodejs package)\n",
        )
        self.assertEqual(self.called()[0], "apt-get remove -y libnode-dev")

    def test_apt_leaving_the_old_node_fails_the_step(self) -> None:
        self.fake("node", prints("v12.22.9"))
        self.recording("apt-get")
        self.assertFalse(self.run_step(STEPS["install_node"]))
        self.assertIn("ERROR: Node.js is 12 after installing; need at least 20\n", self.said())

    def test_a_failed_setup_script(self) -> None:
        self.serve(node.SETUP_URL, "#!/bin/bash\nexit 1\n")
        self.recording("apt-get")
        self.assertFalse(self.run_step(STEPS["install_node"]))
        self.assertIn("ERROR: NodeSource setup script failed\n", self.said())
        self.assertEqual(self.called(), [])

    def test_upgrade_goes_through_the_setup_script_again(self) -> None:
        self.fake("node", prints("v22.11.0"))
        self.recording("apt-get")
        self.assertTrue(self.run_step(STEPS["install_node"], upgrade=True))
        self.assertEqual(self.said(), "[install] Upgrading Node.js to the current LTS\n")
        self.assertEqual(len(self.called()), 2)


class NpmGlobalsTest(StepCase):
    def test_install(self) -> None:
        self.fake("npm", NPM)
        for step, package in (
            ("install_pyright", "pyright"),
            ("install_bash_ls", "bash-language-server"),
            ("install_ccusage", "ccusage"),
        ):
            with self.subTest(step):
                self.assertTrue(self.run_step(STEPS[step]))
                self.assertIn(f"[install] Installing {package}\n", self.said())
                self.assertEqual(
                    self.called()[-2:],
                    [f"npm config set prefix {self.home}/.local", f"npm install -g {package}"],
                )

    def test_present(self) -> None:
        self.fake("npm", NPM)
        self.fake("pyright", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_pyright"]))
        self.assertEqual(self.said(), "[install] pyright already installed; skipping\n")
        self.assertTrue(self.run_step(STEPS["install_pyright"], upgrade=True))
        self.assertIn(
            f"[install] Note: pyright on PATH is {self.bin}/pyright, which shadows the copy"
            f" just installed at {self.home}/.local/bin/pyright\n",
            self.said(),
        )

    def test_without_npm(self) -> None:
        # ccusage asks for npm before it looks for itself; the other two after.
        self.fake("ccusage", "#!/bin/sh\n")
        self.assertFalse(self.run_step(STEPS["install_ccusage"]))
        self.assertTrue(self.said().startswith("[install] ERROR: Missing required command: npm\n"))
        self.assertFalse(self.run_step(STEPS["install_bash_ls"]))
        self.assertIn(
            "[install] Installing bash-language-server\n"
            "[install] ERROR: Missing required command: npm\n",
            self.said(),
        )
