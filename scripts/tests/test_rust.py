from __future__ import annotations

from installer.steps import STEPS, rust

from .support import StepCase

# What rustup-init leaves: the env file and the proxies.
RUSTUP_INIT = """#!/bin/sh
echo "rustup-init $*" >>"$FAKE_CALLS"
mkdir -p "$HOME/.cargo/bin"
: >"$HOME/.cargo/env"
for tool in cargo rustup; do
    printf '#!/bin/sh\\necho "%s $*" >>"$FAKE_CALLS"\\n' "$tool" >"$HOME/.cargo/bin/$tool"
    chmod +x "$HOME/.cargo/bin/$tool"
done
"""


class RustTest(StepCase):
    def test_install(self) -> None:
        self.serve(rust.RUSTUP_URL, RUSTUP_INIT)
        self.assertTrue(self.run_step(STEPS["install_rust"]))
        self.assertEqual(self.said(), "[install] Installing Rust\n")
        self.assertEqual(self.called(), ["rustup-init -y", "cargo --version"])
        # The steps that follow find cargo.
        self.assertTrue(self.env["PATH"].startswith(f"{self.home}/.cargo/bin:"))

        self.assertTrue(self.run_step(STEPS["install_rust"]))
        self.assertIn("[install] Rust already installed; skipping\n", self.said())
        self.assertEqual(self.env["PATH"].count(".cargo/bin"), 1)

    def test_a_cargo_with_no_toolchain_is_reinstalled(self) -> None:
        # What an interrupted rustup-init leaves: proxies that do not run.
        self.fake("rustup", "#!/bin/sh\n")
        self.fake("cargo", "#!/bin/sh\necho 'error: no default toolchain' >&2\nexit 1\n")
        self.serve(rust.RUSTUP_URL, RUSTUP_INIT)
        self.assertTrue(self.run_step(STEPS["install_rust"]))
        self.assertEqual(self.said(), "[install] Installing Rust\n")

    def test_upgrade_retries_once(self) -> None:
        self.fake("cargo", "#!/bin/sh\n")
        marker = self.home / "tried"
        self.fake(
            "rustup",
            f'#!/bin/sh\necho "rustup $*" >>"$FAKE_CALLS"\n'
            f'[ -e "{marker}" ] && exit 0\n: >"{marker}"\nexit 1\n',
        )
        self.assertTrue(self.run_step(STEPS["install_rust"], upgrade=True))
        self.assertEqual(
            self.said(), "[install] Upgrading Rust\n[install] rustup failed; retrying once\n"
        )
        self.assertEqual(self.called(), ["rustup update", "rustup update"])

    def test_no_installer_no_rust(self) -> None:
        self.assertFalse(self.run_step(STEPS["install_rust"]))
        self.assertIn(f"ERROR: Download failed: {rust.RUSTUP_URL}\n", self.said())


class RustAnalyzerTest(StepCase):
    def test_the_proxy_alone_does_not_count(self) -> None:
        marker = self.home / "component"
        self.fake("rust-analyzer", f'#!/bin/sh\n[ -e "{marker}" ]\n')
        self.fake("rustup", f'#!/bin/sh\necho "rustup $*" >>"$FAKE_CALLS"\n: >"{marker}"\n')
        self.assertTrue(self.run_step(STEPS["install_rust_analyzer"]))
        self.assertEqual(self.said(), "[install] Installing rust-analyzer\n")
        self.assertEqual(self.called(), ["rustup component add rust-analyzer"])

        self.assertTrue(self.run_step(STEPS["install_rust_analyzer"]))
        self.assertIn("[install] rust-analyzer already installed; skipping\n", self.said())
        self.assertTrue(self.run_step(STEPS["install_rust_analyzer"], upgrade=True))
        self.assertIn("[install] Upgrading rust-analyzer\n", self.said())

    def test_without_rustup(self) -> None:
        self.assertFalse(self.run_step(STEPS["install_rust_analyzer"]))
        self.assertIn("ERROR: Missing required command: rustup\n", self.said())
