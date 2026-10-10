from __future__ import annotations

import os
import subprocess

from installer import pins
from installer.runner import Settings, StepContext

from .support import StepCase

API = "https://api.github.com/repos"


class PinsFileTest(StepCase):
    def test_every_assignment_is_a_pin(self) -> None:
        # Bash sources the file and Python parses it, so a line only one of
        # them can read would give the two different versions.
        text = pins.PINS_FILE.read_text()
        lines = [line for line in text.splitlines() if line and not line.startswith("#")]
        self.assertEqual(
            len(lines), len(pins.parse(text)), 'a line that is not NAME_VERSION="value"'
        )

    def test_every_pin_has_an_upstream(self) -> None:
        self.assertEqual(set(pins.load()), {*pins.UPSTREAM, pins.GO_PIN})

    def test_bash_reads_the_same_values(self) -> None:
        script = f'source "{pins.PINS_FILE}"; ' + "; ".join(
            f'echo "{name}=${{{name}}}"' for name in pins.load()
        )
        shown = subprocess.run(
            ["/bin/bash", "-euc", script], capture_output=True, text=True, check=True
        )
        self.assertEqual(shown.stdout.splitlines(), [f"{k}={v}" for k, v in pins.load().items()])

    def test_parse(self) -> None:
        text = '# comment\nA_VERSION="v1.2.3"\nB_VERSION="$(oops)"\nother="x"\n'
        self.assertEqual(pins.parse(text), {"A_VERSION": "v1.2.3"})


class PinnedTagTest(StepCase):
    def test_pin_unless_upgrading(self) -> None:
        self.serve(f"{API}/charmbracelet/glow/releases/latest", '{"tag_name":"v99.0.0"}')
        tags: list[str] = []

        def ask(context: StepContext) -> None:
            tags.append(pins.pinned_tag(context, "GLOW_VERSION"))

        self.assertTrue(self.run_action(ask))
        self.assertTrue(self.run_action(ask, upgrade=True))
        self.assertEqual(tags, [pins.pin("GLOW_VERSION"), "v99.0.0"])
        # The pinned run asked nothing of the network.
        self.assertEqual(len(self.requests()), 1)

    def test_report(self) -> None:
        for name, repo in pins.UPSTREAM.items():
            path, _, prefix = repo.partition(":")
            tag = {"tag_name": pins.pin(name)}
            if prefix:
                self.serve(f"{API}/{path}/releases?per_page=50", f"[{tag!s}]".replace("'", '"'))
            elif name == "GLOW_VERSION":
                self.serve(f"{API}/{path}/releases/latest", '{"tag_name":"v99.0.0"}')
            elif name != "MOOR_VERSION":
                self.serve(f"{API}/{path}/releases/latest", f"{tag!s}".replace("'", '"'))
        self.serve("https://go.dev/VERSION?m=text", "go9.9.9\ntime 2026-01-01\n")

        with open(os.devnull, "wb") as discard:
            context = StepContext(self.console, Settings(), self.env, discard, False)
            lines = pins.report(context)
            context.cleanup()

        by_name = {line.split()[0]: line for line in lines}
        self.assertEqual(list(by_name), [*pins.UPSTREAM, pins.GO_PIN])
        bat = pins.pin("BAT_VERSION")
        self.assertEqual(by_name["BAT_VERSION"], f"{'BAT_VERSION':<24} {bat:<30} up to date")
        self.assertTrue(by_name["CARGO_AUDIT_VERSION"].endswith("up to date"))
        self.assertTrue(by_name["GLOW_VERSION"].endswith("-> v99.0.0"))
        self.assertTrue(
            by_name["MOOR_VERSION"].endswith(
                "(upstream unreachable: GitHub API request failed for walles/moor (no response))"
            )
        )
        self.assertTrue(by_name["GO_VERSION"].endswith("-> go9.9.9"))
