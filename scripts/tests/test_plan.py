from __future__ import annotations

import unittest
from collections.abc import Iterator

from installer.plan import LINUX, MACOS, OptionalStep, Plan, Require, UnsupportedPlatform, plan_for
from installer.runner import Step
from installer.steps import STEPS


def steps(plan: Plan) -> Iterator[Step]:
    for item in plan.items:
        if isinstance(item, OptionalStep):
            yield item.step
        elif isinstance(item, Step):
            yield item


class PlanTest(unittest.TestCase):
    def test_every_planned_step_is_the_registered_one(self) -> None:
        for plan in (LINUX, MACOS):
            for step in steps(plan):
                self.assertIs(step.action, STEPS[step.name].action)

    def test_every_step_is_in_a_plan(self) -> None:
        planned = {step.name for plan in (LINUX, MACOS) for step in steps(plan)}
        self.assertEqual(set(STEPS) - planned, set())

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

    def test_a_step_keeps_what_the_plan_gave_it(self) -> None:
        first = next(steps(LINUX))
        self.assertIn("build-essential", first.args)
        self.assertEqual(first.title.split()[:2], ["install_apt_packages_if_missing", "git"])
        formulae = next(s for s in steps(MACOS) if s.name == "install_brew_formulae_if_missing")
        self.assertEqual(formulae.args, ("git", "zsh", "tmux", "node", "entr"))

    def test_linux_keeps_apt_from_asking(self) -> None:
        self.assertIn(("DEBIAN_FRONTEND", "noninteractive"), LINUX.env)
        self.assertEqual(MACOS.env, ())

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
