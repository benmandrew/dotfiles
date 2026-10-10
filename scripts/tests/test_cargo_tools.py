from __future__ import annotations

import string
from pathlib import Path
from unittest import mock

from installer import pins
from installer.steps import PORTED, cargo_tools

from .support import StepCase, prints, sha256

API = "https://api.github.com/repos"
MUSL_X86 = "x86_64-unknown-linux-musl"


def url(pin: str, asset: str) -> str:
    tag = pins.pin(pin)
    return f"https://github.com/{pins.repository(pin)}/releases/download/{tag}/{asset}"


class TableTest(StepCase):
    def test_every_tool_has_a_pin_and_known_fields(self) -> None:
        for tool in cargo_tools.TOOLS.values():
            with self.subTest(tool=tool.command):
                self.assertIn(tool.pin, pins.UPSTREAM)
                fields = {name for _, name, _, _ in string.Formatter().parse(tool.asset) if name}
                self.assertLessEqual(fields, {"tag", "version", "triple"})
                self.assertIn("triple", fields)

    def test_every_extra_is_in_the_table(self) -> None:
        self.assertLessEqual(set(cargo_tools.EXTRAS), set(cargo_tools.TOOLS))


class CargoToolCase(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.system_completions = Path(self.scratch) / "site-functions"
        patch = mock.patch.object(cargo_tools, "SYSTEM_COMPLETION_DIRS", (self.system_completions,))
        patch.start()
        self.addCleanup(patch.stop)

    def local(self, name: str) -> Path:
        return self.home / ".local/bin" / name

    def serve_tool(self, pin: str, asset: str, files: dict[str, str], checksum: str = "") -> None:
        tarball = self.tarball(files)
        self.serve(url(pin, asset), tarball)
        if checksum:
            self.serve(url(pin, checksum), f"{sha256(tarball)}\n")

    def serve_ripgrep(self) -> None:
        name = f"ripgrep-{pins.pin('RIPGREP_VERSION')}-{MUSL_X86}"
        self.serve_tool(
            "RIPGREP_VERSION",
            f"{name}.tar.gz",
            {f"{name}/rg": prints("ripgrep 15.2.0"), f"{name}/complete/_rg": "#compdef rg"},
            checksum=f"{name}.tar.gz.sha256",
        )


class ReleaseBinaryTest(CargoToolCase):
    def test_install_with_a_checksum_and_a_completion(self) -> None:
        self.serve_ripgrep()
        (self.home / ".zcompdump").write_text("stale")
        self.assertTrue(self.run_step(PORTED["install_ripgrep"]))
        self.assertEqual(
            self.said(),
            "[install] Installing rg\n[install] Installed the zsh completion shipped with rg\n",
        )
        self.assertIn("ripgrep", self.local("rg").read_text())
        completion = self.home / ".local/share/zsh/site-functions/_rg"
        self.assertEqual(completion.read_text(), "#compdef rg")
        self.assertFalse((self.home / ".zcompdump").exists())
        # A pinned install asks the API nothing.
        self.assertFalse(any("api.github.com" in request for request in self.requests()))

    def test_a_system_completion_is_left_alone(self) -> None:
        self.serve_ripgrep()
        self.system_completions.mkdir()
        (self.system_completions / "_rg").write_text("from a package")
        self.assertTrue(self.run_step(PORTED["install_ripgrep"]))
        self.assertEqual(self.said(), "[install] Installing rg\n")
        self.assertFalse((self.home / ".local/share/zsh/site-functions/_rg").exists())

    def test_wrong_checksum(self) -> None:
        self.serve_ripgrep()
        name = f"ripgrep-{pins.pin('RIPGREP_VERSION')}-{MUSL_X86}.tar.gz"
        self.serve(url("RIPGREP_VERSION", f"{name}.sha256"), f"{'a' * 64}\n")
        self.assertFalse(self.run_step(PORTED["install_ripgrep"]))
        self.assertIn(f"ERROR: Checksum mismatch for {name}", self.said())
        self.assertFalse(self.local("rg").exists())

    def test_present_is_skipped(self) -> None:
        self.fake("rg", prints("ripgrep 15.2.0"))
        self.assertTrue(self.run_step(PORTED["install_ripgrep"]))
        self.assertEqual(self.said(), "[install] rg already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_a_cargo_build_is_replaced(self) -> None:
        cargo_bin = self.home / ".cargo/bin"
        self.fake("rg", prints("ripgrep 14.0.0"), cargo_bin)
        self.env["PATH"] = f"{cargo_bin}:{self.env['PATH']}"
        self.serve_ripgrep()
        self.assertTrue(self.run_step(PORTED["install_ripgrep"]))
        self.assertIn("[install] Replacing cargo-built rg with the prebuilt binary\n", self.said())
        self.assertFalse((cargo_bin / "rg").exists())
        self.assertTrue(self.local("rg").is_file())

    def test_asset_names(self) -> None:
        # One tool of each naming shape, on the platform that picks the triple.
        tag = pins.pin("FD_VERSION")
        self.serve_tool(
            "FD_VERSION",
            f"fd-{tag}-aarch64-apple-darwin.tar.gz",
            {f"fd-{tag}-aarch64-apple-darwin/fd": prints("fd 10.5.0")},
        )
        self.assertTrue(self.run_step(PORTED["install_fd"], system="Darwin", machine="arm64"))

        # eza publishes gnu alone for aarch64, and no version in the name.
        self.serve_tool(
            "EZA_VERSION", "eza_aarch64-unknown-linux-gnu.tar.gz", {"eza": prints("v0.23.5")}
        )
        self.assertTrue(self.run_step(PORTED["install_eza"], machine="aarch64"))

        # The crate name is part of the nextest tag, and the binary is fat.
        tag = pins.pin("CARGO_NEXTEST_VERSION")
        self.assertTrue(tag.startswith("cargo-nextest-"))
        self.serve_tool(
            "CARGO_NEXTEST_VERSION",
            f"{tag}-universal-apple-darwin.tar.gz",
            {"cargo-nextest": '#!/bin/sh\n[ "$1" = nextest ] && echo cargo-nextest\n'},
            checksum=f"{tag}-universal-apple-darwin.sha256",
        )
        self.assertTrue(
            self.run_step(PORTED["install_cargo_nextest"], system="Darwin", machine="arm64")
        )
        self.assertEqual(self.said().count("Installing"), 3)

    def test_upgrade_already_at_latest(self) -> None:
        tag = pins.pin("CARGO_NEXTEST_VERSION")
        version = tag.removeprefix("cargo-nextest-")
        self.fake(
            "cargo-nextest",
            f'#!/bin/sh\n[ "$1" = nextest ] && echo "cargo-nextest {version} (abc 2026)"\n',
        )
        self.serve(f"{API}/nextest-rs/nextest/releases/latest", f'{{"tag_name":"{tag}"}}')
        self.assertTrue(self.run_step(PORTED["install_cargo_nextest"], upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Upgrading cargo-nextest\n"
            f"[install] cargo-nextest {version} already at latest; skipping\n",
        )

    def test_typst_is_ported(self) -> None:
        self.serve_tool(
            "TYPST_VERSION",
            f"typst-{MUSL_X86}.tar.xz",
            {f"typst-{MUSL_X86}/typst": prints("typst 0.15.1")},
        )
        self.assertTrue(self.run_step(PORTED["install_typst"]))
        self.assertTrue(self.local("typst").is_file())


FAKE_CARGO = """#!/bin/sh
echo "cargo $*" >>"$FAKE_CALLS"
mkdir -p "$HOME/.cargo/bin"
printf '#!/bin/sh\\necho built\\n' >"$HOME/.cargo/bin/$3"
chmod +x "$HOME/.cargo/bin/$3"
"""


class SourceBuildTest(CargoToolCase):
    def test_no_asset_for_the_platform(self) -> None:
        # cross publishes x86_64 alone.
        self.fake("cargo", FAKE_CARGO)
        self.assertTrue(self.run_step(PORTED["install_cargo_extras"], machine="riscv64"))
        self.assertEqual(
            self.called(), [f"cargo install --locked {name}" for name in cargo_tools.EXTRAS]
        )
        self.assertEqual(self.requests(), [])

    def test_the_crate_name(self) -> None:
        self.fake("cargo", FAKE_CARGO.replace("$3", "delta"))
        self.assertTrue(self.run_step(PORTED["install_git_delta"], machine="riscv64"))
        self.assertEqual(self.called(), ["cargo install --locked git-delta"])

    def test_cargo_from_its_env_file(self) -> None:
        cargo_bin = self.home / ".cargo/bin"
        self.fake("cargo", FAKE_CARGO, cargo_bin)
        (self.home / ".cargo/env").write_text("# rustup writes this\n")
        self.assertTrue(self.run_step(PORTED["install_eza"], system="Darwin", machine="arm64"))
        self.assertEqual(self.called(), ["cargo install --locked eza"])
        # The steps that follow see cargo's directory too.
        self.assertTrue(self.env["PATH"].startswith(f"{cargo_bin}:"))

    def test_no_cargo(self) -> None:
        self.assertFalse(self.run_step(PORTED["install_eza"], system="Darwin", machine="arm64"))
        self.assertIn("ERROR: Missing required command: cargo\n", self.said())


class ExtrasTest(CargoToolCase):
    def test_every_tool_is_tried(self) -> None:
        audit = pins.pin("CARGO_AUDIT_VERSION")
        self.assertTrue(audit.startswith("cargo-audit/v"))
        version = audit.removeprefix("cargo-audit/v")
        self.serve_tool(
            "CARGO_AUDIT_VERSION",
            f"cargo-audit-{MUSL_X86}-v{version}.tgz",
            {"cargo-audit": '#!/bin/sh\n[ "$1" = audit ]\n'},
        )
        self.serve_tool(
            "CROSS_VERSION", f"cross-{MUSL_X86}.tar.gz", {"cross": prints("cross 0.2.5")}
        )
        self.assertFalse(self.run_step(PORTED["install_cargo_extras"]))
        said = self.said()
        for name in cargo_tools.EXTRAS:
            self.assertIn(f"[install] Installing {name}\n", said)
        self.assertIn(
            "ERROR: cargo tools failed to install: cargo-fuzz cargo-llvm-cov samply\n", said
        )
        self.assertTrue(self.local("cargo-audit").is_file())
        self.assertTrue(self.local("cross").is_file())
        # The tag is a path, which goes into the download URL as it is.
        self.assertIn(
            f"https://github.com/rustsec/rustsec/releases/download/cargo-audit/v{version}/"
            f"cargo-audit-{MUSL_X86}-v{version}.tgz",
            self.requests(),
        )


class GitAbsorbTest(CargoToolCase):
    def test_homebrew_on_macos(self) -> None:
        self.recording("brew", failing="list")
        self.fake("git-absorb", prints("git-absorb 0.9.0"))
        self.assertTrue(
            self.run_step(PORTED["install_git_absorb"], system="Darwin", machine="arm64")
        )
        self.assertEqual(self.called()[-1], "brew install git-absorb")

    def test_release_binary_on_linux(self) -> None:
        version = pins.pin("GIT_ABSORB_VERSION")
        name = f"git-absorb-{version}-{MUSL_X86}"
        self.serve_tool(
            "GIT_ABSORB_VERSION", f"{name}.tar.gz", {f"{name}/git-absorb": prints("git-absorb")}
        )
        self.assertTrue(self.run_step(PORTED["install_git_absorb"]))
        self.assertTrue(self.local("git-absorb").is_file())
