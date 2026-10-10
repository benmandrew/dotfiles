"""The command line, and one run from first check to exit status."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import signal
import sys
from collections.abc import Sequence
from types import FrameType

from .console import Console
from .optional import OptionalTools
from .plan import OptionalStep, Plan, Require, UnsupportedPlatform, plan_for
from .runner import Fatal, Runner, Settings
from .sudo import SudoSession

CHEZMOI_HINT = (
    "You can initialize chezmoi with: chezmoi init --apply git@github.com:benmandrew/dotfiles.git"
)


class Terminated(BaseException):
    """SIGTERM, raised in the main thread so the same cleanup runs as on Ctrl-C."""


def parse_args(argv: Sequence[str]) -> Settings:
    parser = argparse.ArgumentParser(
        prog="install.sh",
        description="Install the tools these dotfiles expect. Steps skip what is already there.",
    )
    parser.add_argument(
        "--upgrade", action="store_true", help="upgrade tools that are already installed"
    )
    parser.add_argument("--verbose", action="store_true", help="show each step's output as it runs")
    optional = parser.add_mutually_exclusive_group()
    optional.add_argument(
        "--all-optional",
        dest="optional_mode",
        action="store_const",
        const="all",
        help="install every optional tool, without asking or recording",
    )
    optional.add_argument(
        "--no-optional",
        dest="optional_mode",
        action="store_const",
        const="none",
        help="install no optional tool, without asking or recording",
    )
    parser.add_argument(
        "--reconfigure-optional",
        action="store_true",
        help="ask about each optional tool again",
    )
    args = parser.parse_args(argv)
    return Settings(
        upgrade=args.upgrade,
        verbose=args.verbose,
        optional_mode=args.optional_mode,
        reconfigure_optional=args.reconfigure_optional,
    )


def _require(env: dict[str, str], commands: Sequence[str]) -> None:
    for command in commands:
        if shutil.which(command, path=env.get("PATH")) is None:
            raise Fatal(f"Missing required command: {command}")


def run(console: Console, settings: Settings, env: dict[str, str], plan: Plan) -> int:
    """Run a plan and return the exit status."""
    # Homebrew 6 has ask mode on by default, so `brew install` and `brew
    # upgrade` stop for a [y/n] confirmation whenever the plan reaches past the
    # packages named on the command line: a dependency bump, a cask's
    # dependants. Nothing here answers those prompts, so an install left to run
    # unattended stalls on the first one. install-common.sh exports the same
    # for the bash steps.
    env["HOMEBREW_NO_ASK"] = "1"
    runner = Runner(console, settings, env)
    sudo = SudoSession(console, env)
    optional = OptionalTools(console, env, settings.optional_mode, settings.reconfigure_optional)
    try:
        console.log("Checking prerequisites")
        _require(env, plan.requires)
        sudo.start_askpass()
        sudo.start_keepalive()
        for item in plan.items:
            if isinstance(item, Require):
                _require(env, item.commands)
            elif isinstance(item, OptionalStep):
                if optional.enabled(item.key, item.description):
                    runner.run(item.step)
            else:
                runner.run(item)
        console.log(CHEZMOI_HINT)
        return runner.finish()
    except Fatal as fatal:
        if str(fatal):
            console.err(str(fatal))
        return 1
    finally:
        # One place for everything a run has to undo, reached on every way
        # out: the end, a fatal step, Ctrl-C and SIGTERM.
        sudo.stop()
        runner.close()


def _on_sigterm(_signum: int, _frame: FrameType | None) -> None:
    raise Terminated


def _die_of(signum: int) -> None:
    """Re-raise a signal with its default action.

    An interrupted run then dies of the signal it was sent, so a caller sees
    the interruption rather than an exit status to carry on from.
    """
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)


def main(argv: Sequence[str] | None = None) -> int:
    settings = parse_args(sys.argv[1:] if argv is None else argv)
    # A copy of stderr for the installer's own lines, taken before any step
    # runs and handed to each bash step. See console.py.
    console = Console(os.dup(sys.stderr.fileno()))
    try:
        plan = plan_for(platform.system(), platform.machine())
    except UnsupportedPlatform as unsupported:
        console.err(str(unsupported))
        return 1

    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        return run(console, settings, dict(os.environ), plan)
    except KeyboardInterrupt:
        _die_of(signal.SIGINT)
    except Terminated:
        _die_of(signal.SIGTERM)
    return 1
