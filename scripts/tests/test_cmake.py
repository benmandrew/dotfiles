from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import pins
from installer.steps import PORTED, cmake

from .support import StepCase, prints

VERSION = pins.pin("CMAKE_VERSION").removeprefix("v")
BASE = f"https://github.com/Kitware/CMake/releases/download/v{VERSION}"

# Stands in for Kitware's self-extracting installer.
INSTALLER = """#!/bin/sh
echo "installer $*" >>"$FAKE_CALLS"
for arg in "$@"; do
    case "$arg" in --prefix=*) prefix="${arg#--prefix=}" ;; esac
done
mkdir -p "$prefix/bin"
printf '#!/bin/sh\\necho cmake version NEW\\n' >"$prefix/bin/cmake"
chmod +x "$prefix/bin/cmake"
"""


class CmakeTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.prefix = Path(self.scratch) / "prefix"
        patch = mock.patch.object(cmake, "PREFIX", self.prefix)
        patch.start()
        self.addCleanup(patch.stop)

    def serve_installer(self, arch: str) -> None:
        import hashlib

        name = f"cmake-{VERSION}-{arch}.sh"
        self.serve(f"{BASE}/{name}", INSTALLER)
        digest = hashlib.sha256(INSTALLER.encode()).hexdigest()
        self.serve(f"{BASE}/cmake-{VERSION}-SHA-256.txt", f"{digest}  {name}\n")

    def test_install_on_linux(self) -> None:
        self.serve_installer("linux-aarch64")
        self.assertTrue(self.run_step(PORTED["install_cmake"], machine="aarch64"))
        self.assertEqual(self.said(), f"[install] Installing cmake {VERSION}\n")
        self.assertTrue((self.prefix / "bin/cmake").is_file())
        (call,) = self.called()
        self.assertTrue(call.endswith(f"--prefix={self.prefix} --skip-license"))

    def test_new_enough_is_skipped(self) -> None:
        self.fake("cmake", prints("cmake version 99.0.0"))
        self.assertTrue(self.run_step(PORTED["install_cmake"]))
        self.assertEqual(
            self.said(), f"[install] cmake 99.0.0 already satisfies >= {VERSION}; skipping\n"
        )
        self.assertEqual(self.requests(), [])

    def test_too_old_is_replaced(self) -> None:
        self.fake("cmake", prints("cmake version 3.22.1"))
        self.serve_installer("linux-x86_64")
        self.assertTrue(self.run_step(PORTED["install_cmake"]))
        said = self.said()
        self.assertIn(f"[install] cmake 3.22.1 < {VERSION}; installing {VERSION}\n", said)
        self.assertIn(f"Note: cmake on PATH is {self.bin}/cmake, which shadows", said)

    def test_upgrade_already_at_latest(self) -> None:
        self.fake("cmake", prints(f"cmake version {VERSION}"))
        self.serve(
            "https://api.github.com/repos/Kitware/CMake/releases/latest",
            f'{{"tag_name":"v{VERSION}"}}',
        )
        self.assertTrue(self.run_step(PORTED["install_cmake"], upgrade=True))
        self.assertEqual(self.said(), f"[install] cmake {VERSION} already at latest; skipping\n")

    def test_macos(self) -> None:
        def run(**kwargs: bool) -> bool:
            return self.run_step(
                PORTED["install_cmake"], system="Darwin", machine="arm64", **kwargs
            )

        self.recording("brew", failing="list")
        self.fake("cmake", prints("cmake version 3.0.0"))
        self.assertTrue(run())
        self.recording("brew")
        self.assertTrue(run(upgrade=True))
        self.assertEqual(
            self.said(),
            f"[install] cmake 3.0.0 < {VERSION}; upgrading\n[install] Upgrading cmake\n",
        )
        self.assertEqual(
            self.called(),
            [
                "brew list --formula cmake",
                "brew install cmake",
                "brew list --formula cmake",
                "brew upgrade cmake",
            ],
        )
