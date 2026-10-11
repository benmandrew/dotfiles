from __future__ import annotations

from pathlib import Path
from unittest import mock

from installer import pins
from installer.steps import STEPS, opam

from .support import StepCase

TAG = pins.pin("OPAM_VERSION")
VERSION = TAG.removeprefix("v")

# An opam with a root, a default switch and both tools, which records the rest.
OPAM = f"""#!/bin/sh
case "$*" in
    --version) echo "${{OPAM_SAYS:-{VERSION}}}" ;;
    "switch list") exit 0 ;;
    "switch list --short") cat "$HOME/switches" 2>/dev/null ;;
    "list --switch default --installed --short") cat "$HOME/installed" 2>/dev/null ;;
    *) echo "opam $*" >>"$FAKE_CALLS" ;;
esac
"""


class OpamTest(StepCase):
    def setUp(self) -> None:
        super().setUp()
        self.root = self.home / ".opam"

    def ready(self, switches: str = "default\n", installed: str = "") -> None:
        """An opam on PATH with an initialised root."""
        self.fake("opam", OPAM)
        self.root.mkdir(exist_ok=True)
        (self.root / "config").write_text("")
        (self.home / "switches").write_text(switches)
        (self.home / "installed").write_text(installed)

    def test_everything_present(self) -> None:
        self.ready(installed="dune\nocaml-lsp-server\nocamlformat\n")
        self.assertTrue(self.run_step(STEPS["install_opam"]))
        self.assertEqual(
            self.said(),
            "[install] opam already installed; skipping\n"
            "[install] opam already initialised; skipping opam init\n"
            "[install] ocaml-lsp-server and ocamlformat already installed; skipping\n",
        )
        self.assertEqual(self.called(), [])

    def test_linux_binary(self) -> None:
        self.serve(
            f"https://github.com/ocaml/opam/releases/download/{TAG}/opam-{VERSION}-arm64-linux",
            OPAM,
        )
        self.env["PATH"] = f"{self.home}/.local/bin:{self.env['PATH']}"
        self.fake("bwrap", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_opam"], machine="aarch64"))
        self.assertEqual(
            self.said(),
            "[install] Installing opam\n"
            "[install] Creating the default opam switch\n"
            "[install] Installing ocaml-lsp-server ocamlformat into the default opam switch\n",
        )
        self.assertEqual(
            self.called(),
            [
                "opam init --bare --yes --no-setup",
                "opam switch create default --packages=ocaml-base-compiler --yes",
                "opam install --switch default --yes ocaml-lsp-server ocamlformat",
            ],
        )

    def test_no_sandbox_and_a_system_compiler(self) -> None:
        self.fake("opam", OPAM)
        self.fake("ocamlc", "#!/bin/sh\n")
        self.assertTrue(self.run_step(STEPS["install_opam"]))
        self.assertIn(
            "[install] bwrap sandboxing unavailable (container/VM); initialising opam with"
            " --disable-sandboxing\n",
            self.said(),
        )
        self.assertEqual(
            self.called()[:2],
            [
                "opam init --bare --yes --no-setup --disable-sandboxing",
                "opam switch create default --packages=ocaml-system --yes",
            ],
        )

    def test_an_unreadable_root_is_moved_aside(self) -> None:
        self.fake("opam", OPAM)
        self.root.mkdir()
        (self.root / "half").write_text("")
        self.assertTrue(self.run_step(STEPS["install_opam"]))
        (aside,) = self.home.glob(".opam.broken.*")
        self.assertIn(
            f"[install] {self.root} is unusable; moving it to {aside} and initialising afresh\n",
            self.said(),
        )
        self.assertTrue((aside / "half").is_file())

    def test_one_tool_missing(self) -> None:
        self.ready(installed="ocamlformat\n")
        self.assertTrue(self.run_step(STEPS["install_opam"]))
        self.assertIn(
            "[install] Installing ocaml-lsp-server into the default opam switch\n", self.said()
        )
        self.assertEqual(self.called(), ["opam install --switch default --yes ocaml-lsp-server"])

    def test_upgrade_at_the_latest(self) -> None:
        self.ready(installed="ocaml-lsp-server\nocamlformat\n")
        self.serve(
            "https://api.github.com/repos/ocaml/opam/releases/latest", '{"tag_name": "9.9.9"}'
        )
        self.env["OPAM_SAYS"] = "9.9.9"
        self.assertTrue(self.run_step(STEPS["install_opam"], upgrade=True))
        self.assertEqual(
            self.said(),
            "[install] Upgrading opam\n"
            "[install] opam 9.9.9 already at latest; skipping\n"
            "[install] opam already initialised; skipping opam init\n"
            "[install] Upgrading ocaml-lsp-server and ocamlformat\n",
        )
        self.assertEqual(
            self.called(), ["opam upgrade --switch default --yes ocaml-lsp-server ocamlformat"]
        )

    def test_a_failed_install_fails_the_step(self) -> None:
        self.ready()
        self.fake("opam", OPAM.replace("*) echo", "install*) exit 1 ;;\n    *) echo"))
        self.assertFalse(self.run_step(STEPS["install_opam"]))

    def test_macos(self) -> None:
        include = Path(self.scratch) / "zlib" / "include"
        include.mkdir(parents=True)
        (include / "zlib.h").write_text("")
        self.ready(installed="ocaml-lsp-server\nocamlformat\n")
        self.recording("brew")
        self.env["CPATH"] = "/somewhere"
        with mock.patch.object(opam, "ZLIB_INCLUDES", (Path("/no/such/include"), include)):
            self.assertTrue(
                self.run_step(STEPS["install_opam"], system="Darwin", machine="arm64", upgrade=True)
            )
        self.assertEqual(self.called()[0], "brew upgrade opam")
        self.assertEqual(self.env["CPATH"], f"{include}:/somewhere")
        self.assertEqual(self.env["LIBRARY_PATH"], str(include.parent / "lib"))

    def test_macos_without_zlib(self) -> None:
        self.ready()
        # An SDK without the header. With no xcrun the SDK path is empty and
        # the search lands on /usr/include, where a CI runner has a zlib.h.
        self.fake("xcrun", f"#!/bin/sh\necho {self.scratch}/sdk\n")
        missing = Path("/no/such/include")
        with (
            mock.patch.object(opam, "ZLIB_INCLUDES", (missing,)),
            mock.patch.object(opam, "CLT_INCLUDE", missing),
        ):
            self.assertFalse(self.run_step(STEPS["install_opam"], system="Darwin", machine="arm64"))
        self.assertIn(
            "ERROR: No zlib.h on this Mac; opam packages with C stubs will not build\n", self.said()
        )
