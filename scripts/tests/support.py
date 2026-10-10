"""Shared by the tests: a console whose output can be read back."""

from __future__ import annotations

import hashlib
import io
import os
import re
import tarfile
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable

from installer.console import Console
from installer.runner import Host, Runner, Settings, Step, StepContext

_COLOUR = re.compile(r"\033\[[0-9;]*m")


class ConsoleCase(unittest.TestCase):
    """A test with a console writing to a file, and a scratch directory."""

    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        # Resolved, since macOS reaches its temporary directory by a symlink.
        self.scratch = os.path.realpath(scratch.name)
        self._console_path = os.path.join(self.scratch, "console")
        fd = os.open(self._console_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.addCleanup(os.close, fd)
        self.console = Console(fd)

    def said(self) -> str:
        """Everything written to the console so far, without the colours."""
        with open(self._console_path, encoding="utf-8", errors="replace") as handle:
            return _COLOUR.sub("", handle.read())


_FAKE_CURL = """#!/bin/sh
# Serves files from $FAKE_WEB in place of the network.
url="" out="" headers=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        -H) echo "$2" >>"$FAKE_WEB/sent-headers"; shift 2 ;;
        --proto | --retry | --retry-max-time) shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
echo "$url" >>"$FAKE_WEB/requests"
file="$FAKE_WEB/${url#https://}"
if [ ! -f "$file" ]; then
    if [ -n "$headers" ] && [ -f "$file.headers" ]; then cp "$file.headers" "$headers"; fi
    echo "curl: (22) The requested URL returned error" >&2
    exit 22
fi
if [ -n "$headers" ]; then printf 'HTTP/2 200\\r\\n\\r\\n' >"$headers"; fi
if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
"""


class StepCase(ConsoleCase):
    """A test that runs steps against stand-ins for the network and the tools.

    PATH is a directory of fakes ahead of /usr/bin and /bin, HOME is empty, and
    `curl` serves what `serve` was given.
    """

    def setUp(self) -> None:
        super().setUp()
        root = Path(self.scratch)
        self.home = root / "home"
        self.bin = root / "bin"
        self.web = root / "web"
        self.calls = root / "calls"
        for directory in (self.home, self.bin, self.web, root / "tmp"):
            directory.mkdir()
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(root / "tmp"),
            "FAKE_WEB": str(self.web),
            "FAKE_CALLS": str(self.calls),
        }
        self.fake("curl", _FAKE_CURL)
        # Not logged in, whatever the machine running the tests has.
        self.fake("gh", "#!/bin/sh\nexit 1\n")
        self.fake("sudo", '#!/bin/sh\n[ "$1" = -A ] && shift\nexec "$@"\n')

    def fake(self, name: str, script: str, directory: Path | None = None) -> Path:
        """An executable called `name`, in the fakes directory unless told otherwise."""
        path = (directory or self.bin) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(script)
        path.chmod(0o755)
        return path

    def recording(self, name: str, failing: str = "") -> None:
        """A fake that writes its arguments to the calls file.

        It exits 1 when its first argument is `failing`, and 0 otherwise.
        """
        self.fake(
            name,
            f'#!/bin/sh\necho "{name} $*" >>"$FAKE_CALLS"\n[ "$1" != "{failing}" ]\n',
        )

    def called(self) -> list[str]:
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def serve(self, url: str, content: bytes | str) -> None:
        path = self.web / url.removeprefix("https://")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode() if isinstance(content, str) else content)

    def requests(self) -> list[str]:
        log = self.web / "requests"
        return log.read_text().splitlines() if log.exists() else []

    def tarball(self, files: dict[str, str]) -> bytes:
        """A .tar.gz of executable files, by path inside the archive."""
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for name, text in files.items():
                data = text.encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o755
                archive.addfile(info, io.BytesIO(data))
        return buffer.getvalue()

    def run_step(
        self, step: Step, *, upgrade: bool = False, system: str = "Linux", machine: str = "x86_64"
    ) -> bool:
        runner = Runner(self.console, Settings(upgrade=upgrade), self.env, Host(system, machine))
        try:
            return runner.run(step)
        finally:
            runner.close()

    def run_action(self, action: Callable[[StepContext], None], **kwargs: Any) -> bool:
        return self.run_step(Step("step", action), **kwargs)


def prints(text: str) -> str:
    """A shell script that prints `text`."""
    return f"#!/bin/sh\necho '{text}'\n"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
