"""The steps that are Python. The rest are still bash: see legacy.py."""

from __future__ import annotations

from ..runner import Step
from . import cmake, lua_ls, release_tools

PORTED: dict[str, Step] = {
    step.name: step for step in (*cmake.STEPS, *lua_ls.STEPS, *release_tools.STEPS)
}
