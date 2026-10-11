"""ansible-lint.

It is a Python package, so brew on macOS and a uv-managed tool environment on
Linux, version-independent of whatever python3 the distro ships.
"""

from __future__ import annotations

from pathlib import Path

from .. import brew, tools
from ..runner import Step, StepContext, StepFailed

# --offline: otherwise --version asks GitHub for the newest release.
PROBE = ("--offline", "--version")


def install(context: StepContext) -> None:
    if context.host.system == "Darwin":
        brew.formula(context, "ansible-lint", "ansible-lint", *PROBE)
        return

    tools.require_command(context, "uv")
    present = context.which("ansible-lint") is not None
    if not tools.announce(context, "ansible-lint", present):
        return
    context.run(["uv", "tool", "upgrade" if present else "install", "ansible-lint"])
    tool_bin = context.capture(["uv", "tool", "dir", "--bin"])
    if tool_bin is None:
        raise StepFailed
    target = Path(tool_bin) / "ansible-lint"
    tools.note_shadowed(context, "ansible-lint", target)
    tools.require_runs(context, target, *PROBE)


STEPS = (Step("install_ansible_lint", install),)
