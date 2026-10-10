from __future__ import annotations

from installer import pins
from installer.steps import PORTED

from .support import StepCase, prints, sha256

API = "https://api.github.com/repos"


def url(pin: str, asset: str, tag: str | None = None) -> str:
    tag = tag or pins.pin(pin)
    return f"https://github.com/{pins.repository(pin)}/releases/download/{tag}/{asset}"


class ReleaseToolTest(StepCase):
    def local(self, name: str) -> str:
        return str(self.home / ".local/bin" / name)

    def serve_gitleaks(self, body: bytes | None = None) -> None:
        version = pins.pin("GITLEAKS_VERSION").removeprefix("v")
        asset = f"gitleaks_{version}_linux_arm64.tar.gz"
        tarball = self.tarball({"gitleaks": prints("gitleaks 1"), "README.md": "x"})
        self.serve(url("GITLEAKS_VERSION", asset), tarball)
        self.serve(
            url("GITLEAKS_VERSION", f"gitleaks_{version}_checksums.txt"),
            f"{sha256(body or tarball)}  {asset}\n",
        )

    def test_install_on_linux(self) -> None:
        self.serve_gitleaks()
        self.assertTrue(self.run_step(PORTED["install_gitleaks"], machine="aarch64"))
        self.assertEqual(self.said(), "[install] Installing gitleaks\n")
        self.assertIn("gitleaks 1", (self.home / ".local/bin/gitleaks").read_text())
        # A pinned install asks the API nothing.
        self.assertFalse(any("api.github.com" in request for request in self.requests()))

    def test_checksum_mismatch_installs_nothing(self) -> None:
        self.serve_gitleaks(body=b"something else")
        self.assertFalse(self.run_step(PORTED["install_gitleaks"], machine="aarch64"))
        self.assertIn("ERROR: Checksum mismatch for gitleaks_", self.said())
        self.assertIn("ERROR: Step failed: install_gitleaks\n", self.said())
        self.assertFalse((self.home / ".local/bin/gitleaks").exists())

    def test_present_is_skipped_and_upgraded(self) -> None:
        self.fake("gitleaks", prints("gitleaks 0"))
        self.assertTrue(self.run_step(PORTED["install_gitleaks"], machine="aarch64"))
        self.assertEqual(self.said(), "[install] gitleaks already installed; skipping\n")
        self.assertEqual(self.requests(), [])

        self.serve_gitleaks()
        tag = pins.pin("GITLEAKS_VERSION")
        self.serve(f"{API}/gitleaks/gitleaks/releases/latest", f'{{"tag_name":"{tag}"}}')
        self.assertTrue(self.run_step(PORTED["install_gitleaks"], machine="aarch64", upgrade=True))
        self.assertIn("[install] Upgrading gitleaks\n", self.said())
        # The copy in the fakes directory comes first on PATH.
        self.assertIn(
            f"Note: gitleaks on PATH is {self.bin}/gitleaks, which shadows the copy just"
            f" installed at {self.local('gitleaks')}\n",
            self.said(),
        )

    def test_binary_inside_a_directory(self) -> None:
        version = pins.pin("GLOW_VERSION").removeprefix("v")
        name = f"glow_{version}_Linux_x86_64"
        tarball = self.tarball(
            {f"{name}/glow": prints("glow"), f"{name}/completions/glow.bash": "x"}
        )
        self.serve(url("GLOW_VERSION", f"{name}.tar.gz"), tarball)
        self.serve(url("GLOW_VERSION", "checksums.txt"), f"{sha256(tarball)}  {name}.tar.gz\n")
        self.assertTrue(self.run_step(PORTED["install_glow"]))
        self.assertTrue((self.home / ".local/bin/glow").is_file())

    def test_unsupported_arch(self) -> None:
        self.assertTrue(self.run_step(PORTED["install_glow"], machine="riscv64"))
        self.assertEqual(
            self.said(),
            "[install] Installing glow\n"
            "[install] Unsupported arch riscv64 for glow install; skipping\n",
        )

    def ripgrep_all(self, files: dict[str, str]) -> bool:
        tag = pins.pin("RIPGREP_ALL_VERSION")
        asset = f"ripgrep_all-{tag}-x86_64-unknown-linux-musl.tar.gz"
        self.serve(url("RIPGREP_ALL_VERSION", asset), self.tarball(files))
        return self.run_step(PORTED["install_ripgrep_all"])

    def test_two_binaries(self) -> None:
        self.assertTrue(
            self.ripgrep_all({"r/rga": prints("rga"), "r/rga-preproc": "#!/bin/sh\nexit 1\n"})
        )
        self.assertEqual(self.said(), "[install] Installing ripgrep-all\n")
        self.assertTrue((self.home / ".local/bin/rga-preproc").is_file())

    def test_a_binary_missing_from_the_tarball(self) -> None:
        self.assertFalse(self.ripgrep_all({"r/rga": prints("rga")}))
        self.assertIn("ERROR: No rga-preproc binary inside ripgrep_all-", self.said())

    def test_homebrew_on_macos(self) -> None:
        self.recording("brew", failing="list")
        self.fake("rga", prints("rga"))
        self.fake("gitleaks", '#!/bin/sh\n[ "$1" = version ]\n')
        for step in ("install_ripgrep_all", "install_gitleaks"):
            self.assertTrue(self.run_step(PORTED[step], system="Darwin", machine="arm64"))
        self.assertEqual(
            self.called(),
            [
                "brew list --formula ripgrep-all",
                "brew install ripgrep-all",
                "brew list --formula gitleaks",
                "brew install gitleaks",
            ],
        )
        self.assertEqual(self.requests(), [])

    def test_homebrew_formula_already_there(self) -> None:
        self.recording("brew")
        self.fake("glow", prints("glow"))
        self.assertTrue(self.run_step(PORTED["install_glow"], system="Darwin", machine="arm64"))
        self.assertTrue(
            self.run_step(PORTED["install_glow"], system="Darwin", machine="arm64", upgrade=True)
        )
        self.assertEqual(
            self.said(), "[install] glow already installed; skipping\n[install] Upgrading glow\n"
        )
        self.assertEqual(self.called()[-1], "brew upgrade glow")


class MoorTest(StepCase):
    def test_release_binary_on_x86_64(self) -> None:
        tag = pins.pin("MOOR_VERSION")
        self.serve(url("MOOR_VERSION", f"moor-{tag}-linux-amd64"), prints("moor"))
        self.assertTrue(self.run_step(PORTED["install_moor"]))
        self.assertEqual(self.said(), "[install] Installing moor\n")
        self.assertIn("moor", (self.home / ".local/bin/moor").read_text())

    def test_built_with_go_on_aarch64(self) -> None:
        gobin = self.home / "go/bin"
        self.fake("moor", prints("moor"), gobin)
        self.fake(
            "go",
            '#!/bin/sh\necho "go $* GOTOOLCHAIN=$GOTOOLCHAIN" >>"$FAKE_CALLS"\n'
            f'[ "$2" = GOPATH ] && echo "{self.home}/go"\nexit 0\n',
        )
        self.assertTrue(self.run_step(PORTED["install_moor"], machine="aarch64"))
        tag = pins.pin("MOOR_VERSION")
        self.assertEqual(
            self.called()[0],
            f"go install github.com/walles/moor/v2/cmd/moor@{tag} GOTOOLCHAIN=auto",
        )
        self.assertEqual(self.requests(), [])

    def test_homebrew_on_macos(self) -> None:
        self.recording("brew")
        self.assertTrue(self.run_step(PORTED["install_moor"], system="Darwin", machine="arm64"))
        self.assertEqual(self.said(), "[install] moor already installed; skipping\n")


class TreehouseTest(StepCase):
    def serve_release(self, tag: str, system: str = "linux", arch: str = "amd64") -> None:
        asset = f"treehouse-{tag}-{system}-{arch}.tar.gz"
        tarball = self.tarball({"treehouse": prints(f"treehouse version {tag}")})
        self.serve(url("TREEHOUSE_VERSION", asset, tag), tarball)
        self.serve(url("TREEHOUSE_VERSION", "checksums.txt", tag), f"{sha256(tarball)}  {asset}\n")

    def test_install_on_macos_too(self) -> None:
        tag = pins.pin("TREEHOUSE_VERSION")
        self.serve_release(tag, "darwin", "arm64")
        self.assertTrue(
            self.run_step(PORTED["install_treehouse"], system="Darwin", machine="arm64")
        )
        self.assertEqual(self.said(), f"[install] Installing treehouse {tag}\n")

    def test_present_costs_no_request(self) -> None:
        self.fake("treehouse", prints("treehouse version v1.0.0"))
        self.assertTrue(self.run_step(PORTED["install_treehouse"]))
        self.assertEqual(self.said(), "[install] treehouse v1.0.0 already installed; skipping\n")
        self.assertEqual(self.requests(), [])

    def test_upgrade(self) -> None:
        self.fake("treehouse", prints("treehouse version v1.0.0"))
        latest = f"{API}/kunchenguid/treehouse/releases/latest"
        self.serve(latest, '{"tag_name":"v1.0.0"}')
        self.assertTrue(self.run_step(PORTED["install_treehouse"], upgrade=True))
        self.assertEqual(self.said(), "[install] treehouse v1.0.0 already at latest; skipping\n")

        self.serve(latest, '{"tag_name":"v9.0.0"}')
        self.serve_release("v9.0.0")
        self.assertTrue(self.run_step(PORTED["install_treehouse"], upgrade=True))
        self.assertIn("[install] Upgrading treehouse to v9.0.0\n", self.said())
        self.assertIn("v9.0.0", (self.home / ".local/bin/treehouse").read_text())
