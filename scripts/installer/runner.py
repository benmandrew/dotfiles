"""Runs steps: holds their output, restores the terminal, collects failures."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tempfile
import termios
import traceback
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any, Callable

from .console import Console

# How much of a failed step's log is printed where it failed.
LOG_LINES = 50


class StepFailed(Exception):
    """A step did not do its job. A message, if there is one, is printed."""


class Fatal(Exception):
    """The run cannot go on. A message, if there is one, is printed."""


@dataclass(frozen=True)
class Settings:
    upgrade: bool = False
    verbose: bool = False
    # "all", "none", or None to use the recorded answers.
    optional_mode: str | None = None
    reconfigure_optional: bool = False


@dataclass(frozen=True)
class Host:
    """The machine the run is on, as `uname -s` and `uname -m` name it."""

    system: str
    machine: str

    @classmethod
    def current(cls) -> Host:
        return cls(platform.system(), platform.machine())


@dataclass(frozen=True)
class Step:
    name: str
    action: Callable[[StepContext], None]
    args: tuple[str, ...] = ()
    # A step that must prompt. Its output is live and it keeps stdin, since a
    # prompt nobody can see or answer is a hang.
    interactive: bool = False
    # A step the rest of the install is built on. Its failure ends the run
    # rather than being collected and reported at the end.
    fatal: bool = False

    @property
    def title(self) -> str:
        return " ".join((self.name, *self.args))


class StepContext:
    """What a running step is given."""

    def __init__(
        self,
        console: Console,
        settings: Settings,
        env: dict[str, str],
        output: IO[bytes] | None,
        interactive: bool,
        host: Host | None = None,
    ) -> None:
        self.console = console
        self.settings = settings
        # Shared with every other step, so a change one step makes to PATH is
        # there for the next.
        self.env = env
        self.host = host or Host.current()
        self._output = output
        self._interactive = interactive
        self._scratch: list[Path] = []

    @property
    def upgrade(self) -> bool:
        return self.settings.upgrade

    @property
    def home(self) -> Path:
        return Path(self.env["HOME"])

    def log(self, message: str) -> None:
        self.console.log(message)

    def which(self, command: str) -> str | None:
        """Where `command` is on the steps' PATH, as `command -v` would say."""
        return shutil.which(command, path=self.env.get("PATH", os.defpath))

    def tmpdir(self) -> Path:
        """A new scratch directory, removed when the step ends."""
        path = Path(tempfile.mkdtemp(prefix="dotfiles-step.", dir=self.env.get("TMPDIR") or None))
        self._scratch.append(path)
        return path

    def cleanup(self) -> None:
        while self._scratch:
            shutil.rmtree(self._scratch.pop(), ignore_errors=True)

    def call(
        self,
        argv: Sequence[str],
        *,
        env: dict[str, str] | None = None,
        pass_fds: Sequence[int] = (),
    ) -> int:
        """Run a command with the step's output handling and return its status.

        stdin is /dev/null unless the step is interactive, so a program testing
        whether it is interactive decides it is not, and prints rather than
        prompting or drawing a TUI that nobody can see.
        """
        try:
            proc = subprocess.Popen(
                argv,
                stdin=None if self._interactive else subprocess.DEVNULL,
                stdout=self._output,
                stderr=self._output,
                env=self.env if env is None else env,
                pass_fds=pass_fds,
            )
        except FileNotFoundError:
            # What a shell says and returns, so a missing tool reads the same
            # in a step's log whichever language the step is in.
            self._say(f"{argv[0]}: command not found\n")
            return 127
        try:
            return proc.wait()
        except BaseException:
            _stop(proc)
            raise

    def run(self, argv: Sequence[str], *, env: dict[str, str] | None = None) -> None:
        """`call`, failing the step on a non-zero exit.

        No message: the command has said why in the step's output, which the
        runner prints.
        """
        if self.call(argv, env=env) != 0:
            raise StepFailed

    def succeeds(self, argv: Sequence[str]) -> bool:
        """Whether a command exits 0. Its output is thrown away."""
        try:
            done = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=self.env,
                check=False,
            )
        except OSError:
            return False
        return done.returncode == 0

    def capture(self, argv: Sequence[str], *, quiet: bool = False) -> str | None:
        """What a command prints, without the trailing newlines, or None if it fails.

        stderr goes with the step's output, or nowhere when `quiet`.
        """
        try:
            done = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL if quiet else self._output,
                env=self.env,
                check=False,
            )
        except OSError:
            return None
        if done.returncode != 0:
            return None
        return done.stdout.decode(errors="replace").rstrip("\n")

    def _say(self, text: str) -> None:
        if self._output is None:
            self.console.write(text.encode())
        else:
            self._output.write(text.encode())


def _stop(proc: subprocess.Popen[bytes]) -> None:
    """End a child the run is abandoning, on Ctrl-C or SIGTERM.

    Ctrl-C reaches the child on its own, the terminal sending it to the whole
    foreground group, so the short wait is usually all this does.
    """
    try:
        proc.wait(timeout=0.25)
        return
    except subprocess.TimeoutExpired:
        pass
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def _tty_settings() -> list[Any] | None:
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None
    try:
        return termios.tcgetattr(fd)
    except termios.error:
        return None
    finally:
        os.close(fd)


def _tail(path: Path, lines: int) -> bytes:
    text = b"".join(path.read_bytes().splitlines(keepends=True)[-lines:])
    if text and not text.endswith(b"\n"):
        text += b"\n"
    return text


class Runner:
    """Runs steps one at a time and remembers which failed.

    A step's output is held in a file rather than printed as it goes. Live
    stderr is not the same as quiet stderr: curl writes its progress meter
    there, nix and the direnv installer narrate there, and apt's progress bar
    leaves the cursor mid-line, so the next [install] line starts wherever the
    bar ended. Package managers and build systems narrate their whole run on
    stdout, so an apt install, a brew upgrade and a make between them bury the
    one line that matters. The log of a step that succeeds is deleted, and the
    tail of one that fails is printed where it failed, with the path to the
    whole thing. --verbose puts the output back for a step that has to be
    watched.

    The terminal's line settings are saved before each step and restored after,
    so a step that puts the tty in raw mode and dies before restoring it cannot
    leave the shell behind it unusable. An --upgrade run on 19 August 2026 did
    that: the shell it ran from was left at `-isig -opost`, so ^C and ^Z did
    nothing and every line of output started where the last one ended. Which
    step it was went unidentified, which is the argument for guarding all of
    them rather than the suspects. `close` restores them as well, since Ctrl-C
    during a step would otherwise skip the restore and leave exactly that shell
    behind.
    """

    def __init__(
        self,
        console: Console,
        settings: Settings,
        env: dict[str, str],
        host: Host | None = None,
    ) -> None:
        self.console = console
        self.settings = settings
        self.env = env
        self.host = host or Host.current()
        self.failed: list[str] = []
        self._log_dir: Path | None = None
        self._tty: list[Any] | None = None
        # Whether any failure has been reported. A log left behind by a run
        # that reported none belongs to a step the run stopped inside.
        self._reported = False

    def run(self, step: Step) -> bool:
        """Run a step. A failure is recorded, or raised if the step is fatal."""
        self._tty = _tty_settings()
        log_path: Path | None = None
        try:
            if self.settings.verbose or step.interactive:
                ok = self._attempt(step, None)
            else:
                log_path = self._log_path(step.name)
                # Unbuffered, so a traceback written here lands after the
                # output of the commands that ran before it.
                with log_path.open("wb", buffering=0) as output:
                    ok = self._attempt(step, output)
        finally:
            self.restore_tty()

        if log_path is not None:
            if ok:
                log_path.unlink()
            else:
                self.console.err(
                    f"Output of {step.name}, last {LOG_LINES} lines (all of it: {log_path}):"
                )
                self.console.write(_tail(log_path, LOG_LINES))
        if ok:
            return True

        self._reported = True
        self.console.err(f"Step failed: {step.title}")
        if step.fatal:
            raise Fatal
        self.failed.append(step.title)
        return False

    def _attempt(self, step: Step, output: IO[bytes] | None) -> bool:
        context = StepContext(
            self.console, self.settings, self.env, output, step.interactive, self.host
        )
        try:
            step.action(context)
        except StepFailed as failure:
            if str(failure):
                self.console.err(str(failure))
            return False
        except Exception:
            # A bug in a step rather than a failed install. It still fails the
            # step alone, and the traceback goes where the step's output went.
            trace = traceback.format_exc().encode()
            if output is None:
                self.console.write(trace)
            else:
                output.write(trace)
            return False
        finally:
            context.cleanup()
        return True

    def _log_path(self, name: str) -> Path:
        if self._log_dir is None:
            self._log_dir = Path(
                tempfile.mkdtemp(prefix="dotfiles-install.", dir=self.env.get("TMPDIR") or None)
            )
        return self._log_dir / f"{name}.log"

    def restore_tty(self) -> None:
        state, self._tty = self._tty, None
        if state is None:
            return
        try:
            fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        except OSError:
            return
        try:
            termios.tcsetattr(fd, termios.TCSANOW, state)
        except termios.error:
            pass
        finally:
            os.close(fd)

    def finish(self) -> int:
        """Name the failed steps again and return the exit status.

        A full install runs 60 steps on Linux and 55 on macOS, printing a
        screen or two past the one that broke, so the report at the point of
        failure has scrolled away by the time the run ends.
        """
        if not self.failed:
            return 0
        count = len(self.failed)
        noun = "step" if count == 1 else "steps"
        self.console.err(f"{count} {noun} failed:")
        for title in self.failed:
            self.console.detail(title)
        return 1

    def close(self) -> None:
        """Undo what a run leaves behind. Safe to call on any way out."""
        self.restore_tty()
        if self._log_dir is None:
            return
        log_dir, self._log_dir = self._log_dir, None
        # rmdir, not rmtree: the directory is empty once every step that passed
        # has had its log deleted, and a run with a failure keeps its logs.
        try:
            log_dir.rmdir()
            return
        except OSError:
            pass
        # A run interrupted inside a step never reaches the reporting at the
        # end of `run`. The step's output is in its log, so say where.
        if not self._reported:
            self.console.err("The run stopped inside a step. Its output is in:")
            for leftover in sorted(log_dir.glob("*.log")):
                self.console.detail(str(leftover))
