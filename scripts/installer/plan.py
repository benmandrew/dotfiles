"""What each platform installs, in order."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Union

from .legacy import legacy
from .runner import Step
from .steps import PORTED


@dataclass(frozen=True)
class Require:
    """Commands that must be on PATH by this point, or the run ends."""

    commands: tuple[str, ...]


@dataclass(frozen=True)
class OptionalStep:
    """A step for a tool only some machines want. See optional.py."""

    key: str
    # One line, shown above the prompt.
    description: str
    step: Step


Item = Union[Step, Require, OptionalStep]


@dataclass(frozen=True)
class Plan:
    # Checked before anything runs, sudo included.
    requires: tuple[str, ...]
    items: tuple[Item, ...]


class UnsupportedPlatform(Exception):
    pass


def _step(name: str) -> Step:
    """The step of that name: the Python one where it is ported, else the bash one."""
    return PORTED.get(name) or legacy(name)


def _steps(*names: str) -> tuple[Step, ...]:
    return tuple(_step(name) for name in names)


LINUX = Plan(
    requires=("sudo", "ssh-keygen", "dpkg", "apt"),
    items=(
        # Prerequisites, deliberately fatal: the rest of the install is built
        # on these, so a failure here ends the run rather than being collected
        # and reported at the end.
        legacy(
            "install_apt_packages_if_missing",
            "git",
            "curl",
            "gpg",
            "build-essential",
            "zsh",
            "entr",
            "libevent-dev",
            "libncurses-dev",
            "pkg-config",
            "bubblewrap",
            "bison",
            "autoconf",
            "unzip",
            fatal=True,
        ),
        legacy("install_perf", fatal=True),
        # Early, so every later step and the user's own work runs against the
        # newer git rather than jammy's 2.34.1.
        *_steps(
            "install_git",
            "install_login_shell",
            "install_inotify_limits",
            "install_vscode_unattended_upgrades",
            "install_tmux_from_source",
            "install_cmake",
            "install_nix",
            "install_direnv",
            "install_nix_direnv",
            "install_zinit",
            "install_rust",
            "install_rust_analyzer",
            "install_eza",
            "install_fd",
            "install_bat",
            "install_btop",
            "install_ripgrep",
            "install_git_delta",
            "install_jq",
            "install_zstd",
            "install_hyperfine",
            "install_zoxide",
            "install_fzf",
            "install_fzf_tab",
            "install_zsh_autosuggestions",
            "install_atuin",
            "install_gh",
            "install_gh_stack",
            "install_gh_stack_skill",
            "install_tailscale",
            "install_claude_code",
            "install_rtk",
            "install_node",
            "install_uv",
            "install_clangd",
            "install_pyright",
            "install_bash_ls",
            "install_lua_ls",
            "install_opam",
            "install_go",
            "install_moor",
            "install_glow",
            "install_treehouse",
            "install_git_absorb",
            "install_gitleaks",
            "install_sccache",
            "install_ripgrep_all",
            "install_difftastic",
            "install_cargo_nextest",
            "install_ansible_lint",
            "install_elan",
            "install_fzf_git",
            "install_cargo_extras",
            "install_ccusage",
            "install_starship",
            "install_tmux_plugins",
            "install_wezterm",
            "set_default_terminal_wezterm",
            "install_nerd_font",
        ),
        OptionalStep(
            "obsidian",
            "Obsidian: notes app, plus obsync and the 15-minute vault sync cron entry it"
            " schedules. Ships the 'obsidian' CLI, but needs the GUI app running — a"
            " dev-machine tool, not a server one.",
            legacy("install_obsidian_stack"),
        ),
        OptionalStep(
            "zathura",
            "zathura: keyboard-driven PDF viewer, with SyncTeX inverse search into VS Code."
            " A GUI app — noise on a server.",
            legacy("install_zathura"),
        ),
        OptionalStep(
            "latex",
            "LaTeX: upstream TeX Live in ~/.local/texlive with latexmk and biber, for"
            " building papers. Several gigabytes, and pointless where no one writes"
            " documents.",
            legacy("install_latex"),
        ),
        OptionalStep(
            "typst",
            "Typst: markup typesetting compiler, a single binary in ~/.local/bin. For"
            " writing documents, not for a server.",
            _step("install_typst"),
        ),
        OptionalStep(
            "docker",
            "Docker: container engine with the buildx and compose plugins. Adds you to the"
            " docker group, which is root-equivalent.",
            legacy("install_docker"),
        ),
        legacy("install_neovim_if_missing"),
        # After every other step: it runs each tool to get its completion
        # script.
        legacy("install_zsh_completions"),
    ),
)

MACOS = Plan(
    # The sudo helpers start once these are found, which puts them ahead of
    # install_homebrew: its installer runs `sudo -k` on exit unless sudo is
    # already active. The Command Line Tools are in place before any of this,
    # scripts/install.sh needing them for python3.
    requires=("sudo", "curl", "ssh-keygen"),
    items=(
        # Ahead of install_homebrew deliberately. Nix needs only curl and sh,
        # and the first brew command of the run wipes the sudo timestamp, so
        # running it here lets `sudo -i nix upgrade-nix` use the credential
        # taken moments ago. This saves a prompt on its own, without the
        # askpass helper.
        legacy("install_nix"),
        # Homebrew's installer prompts, so its output cannot be held.
        legacy("install_homebrew", interactive=True, fatal=True),
        Require(("brew",)),
        legacy("install_brew_formulae_if_missing", "git", "zsh", "tmux", "node", "entr"),
        *_steps(
            "install_login_shell",
            "install_cmake",
            "install_direnv",
            "install_nix_direnv",
            "install_zinit",
            "install_rust",
            "install_rust_analyzer",
            "install_eza",
            "install_fd",
            "install_bat",
            "install_btop",
            "install_ripgrep",
            "install_git_delta",
            "install_jq",
            "install_zstd",
            "install_hyperfine",
            "install_zoxide",
            "install_fzf",
            "install_fzf_tab",
            "install_zsh_autosuggestions",
            "install_atuin",
            "install_gh",
            "install_gh_stack",
            "install_gh_stack_skill",
            "install_tailscale",
            "install_claude_code",
            "install_rtk",
            "install_uv",
            "install_clangd",
            "install_pyright",
            "install_bash_ls",
            "install_lua_ls",
            "install_opam",
            "install_moor",
            "install_glow",
            "install_treehouse",
            "install_git_absorb",
            "install_gitleaks",
            "install_sccache",
            "install_ripgrep_all",
            "install_difftastic",
            "install_cargo_nextest",
            "install_ansible_lint",
            "install_elan",
            "install_fzf_git",
            "install_cargo_extras",
            "install_ccusage",
            "install_starship",
            "install_tmux_plugins",
            "install_wezterm",
            "install_nerd_font",
        ),
        OptionalStep(
            "obsidian",
            "Obsidian: notes app, plus obsync and the 15-minute vault sync LaunchAgent it"
            " schedules. Ships the 'obsidian' CLI, but needs the GUI app running — a"
            " dev-machine tool, not a server one.",
            legacy("install_obsidian_stack"),
        ),
        OptionalStep(
            "zathura",
            "zathura: keyboard-driven PDF viewer, with SyncTeX inverse search into VS Code."
            " A GUI app — noise on a server.",
            legacy("install_zathura"),
        ),
        OptionalStep(
            "latex",
            "LaTeX: TeX Live with latexmk and biber, for building papers. Several"
            " gigabytes, and pointless where no one writes documents.",
            legacy("install_latex"),
        ),
        OptionalStep(
            "typst",
            "Typst: markup typesetting compiler, a single binary in ~/.local/bin. For"
            " writing documents, not for a server.",
            _step("install_typst"),
        ),
        OptionalStep(
            "docker",
            "Docker: container engine with the buildx and compose plugins. Docker Desktop"
            " on macOS, a GUI app that runs a Linux VM.",
            legacy("install_docker"),
        ),
        legacy("install_neovim_if_missing"),
        # After every other step: it runs each tool to get its completion
        # script.
        legacy("install_zsh_completions"),
    ),
)


def plan_for(system: str, machine: str) -> Plan:
    """The plan for `uname -s` and `uname -m`."""
    if system == "Linux":
        return LINUX
    if system == "Darwin":
        if machine != "arm64":
            raise UnsupportedPlatform("macOS is only supported on arm64")
        return MACOS
    raise UnsupportedPlatform(f"unsupported OS '{system}'")
