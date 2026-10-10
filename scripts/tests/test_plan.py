from __future__ import annotations

import re
import unittest
from collections.abc import Iterator

from installer.legacy import SCRIPTS_DIR
from installer.plan import LINUX, MACOS, OptionalStep, Plan, Require, UnsupportedPlatform, plan_for
from installer.runner import Step

_FUNCTION = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{", re.M)


def functions(*scripts: str) -> set[str]:
    found: set[str] = set()
    for script in scripts:
        found.update(_FUNCTION.findall((SCRIPTS_DIR / script).read_text()))
    return found


def steps(plan: Plan) -> Iterator[Step]:
    for item in plan.items:
        if isinstance(item, OptionalStep):
            yield item.step
        elif isinstance(item, Step):
            yield item


class PlanTest(unittest.TestCase):
    def check_defined(self, plan: Plan, platform_script: str) -> None:
        defined = functions("install-common.sh", platform_script)
        missing = [step.name for step in steps(plan) if step.name not in defined]
        self.assertEqual(missing, [], f"no such bash function in {platform_script}")

    def test_every_linux_step_is_a_bash_function(self) -> None:
        self.check_defined(LINUX, "install-linux.sh")

    def test_every_macos_step_is_a_bash_function(self) -> None:
        self.check_defined(MACOS, "install-macos-arm64.sh")

    def test_no_step_runs_twice(self) -> None:
        for plan in (LINUX, MACOS):
            titles = [step.title for step in steps(plan)]
            self.assertEqual(len(titles), len(set(titles)))

    def test_completions_run_last(self) -> None:
        # install_zsh_completions calls each installed binary.
        for plan in (LINUX, MACOS):
            self.assertEqual(list(steps(plan))[-1].name, "install_zsh_completions")

    def test_macos_order_around_homebrew(self) -> None:
        items = list(MACOS.items)
        names = [item.name if isinstance(item, Step) else None for item in items]
        homebrew = names.index("install_homebrew")
        # Nix first, while the sudo credential is fresh.
        self.assertLess(names.index("install_nix"), homebrew)
        self.assertEqual(items[homebrew + 1], Require(("brew",)))
        step = items[homebrew]
        assert isinstance(step, Step)
        self.assertTrue(step.interactive and step.fatal)

    def test_linux_prerequisites_are_fatal(self) -> None:
        first, second = list(steps(LINUX))[:2]
        self.assertEqual(first.name, "install_apt_packages_if_missing")
        self.assertEqual(second.name, "install_perf")
        self.assertTrue(first.fatal and second.fatal)

    def test_platforms(self) -> None:
        self.assertIs(plan_for("Linux", "x86_64"), LINUX)
        self.assertIs(plan_for("Linux", "aarch64"), LINUX)
        self.assertIs(plan_for("Darwin", "arm64"), MACOS)
        with self.assertRaises(UnsupportedPlatform):
            plan_for("Darwin", "x86_64")
        with self.assertRaises(UnsupportedPlatform):
            plan_for("FreeBSD", "amd64")


if __name__ == "__main__":
    unittest.main()
