"""Every install step, by name. plan.py puts them in order."""

from __future__ import annotations

from ..runner import Step
from . import (
    ansible_lint,
    atuin,
    builds,
    cargo_tools,
    clones,
    cmake,
    completions,
    docker,
    elan,
    gh,
    git,
    go,
    latex,
    lua_ls,
    neovim,
    nerd_font,
    nix,
    node,
    obsidian,
    opam,
    packages,
    release_tools,
    rust,
    site_fonts,
    system,
    vendor,
    wezterm,
    zathura,
)

STEPS: dict[str, Step] = {
    step.name: step
    for module in (
        ansible_lint,
        atuin,
        builds,
        cargo_tools,
        clones,
        cmake,
        completions,
        docker,
        elan,
        gh,
        git,
        go,
        latex,
        lua_ls,
        neovim,
        nerd_font,
        nix,
        node,
        obsidian,
        opam,
        packages,
        release_tools,
        rust,
        site_fonts,
        system,
        vendor,
        wezterm,
        zathura,
    )
    for step in module.STEPS
}
