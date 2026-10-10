"""The steps that are Python. The rest are still bash: see legacy.py."""

from __future__ import annotations

from ..runner import Step
from . import atuin, cargo_tools, cmake, elan, go, lua_ls, neovim, nerd_font, release_tools

PORTED: dict[str, Step] = {
    step.name: step
    for module in (atuin, cargo_tools, cmake, elan, go, lua_ls, neovim, nerd_font, release_tools)
    for step in module.STEPS
}
