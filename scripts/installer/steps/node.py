"""Node.js on Linux, and the tools that come as npm packages.

macOS takes node from the Homebrew formulae in the plan.
"""

from __future__ import annotations

from .. import apt, fetch, tools
from ..runner import Step, StepContext, StepFailed

MIN_MAJOR = 20
SETUP_URL = "https://deb.nodesource.com/setup_lts.x"


def _major(context: StepContext) -> str:
    """The major version of the node on PATH: `v22.11.0` gives `22`."""
    version = context.capture(["node", "--version"], quiet=True) or ""
    return version.partition(".")[0].replace("v", "")


def _new_enough(major: str) -> bool:
    return major.isdigit() and int(major) >= MIN_MAJOR


def install_node(context: StepContext) -> None:
    if context.which("node") is not None:
        major = _major(context)
        if _new_enough(major):
            if not context.upgrade:
                context.log(f"Node.js {major} already installed; skipping")
                return
            # Through NodeSource's setup script again, since its apt source
            # names one major version and an apt upgrade stays on it past end
            # of life.
            context.log("Upgrading Node.js to the current LTS")
        else:
            context.log(f"Node.js {major} < {MIN_MAJOR}; upgrading to LTS")
    else:
        context.log("Installing Node.js LTS")

    # The distro-provided libnode-dev ships headers (e.g. common.gypi) that the
    # NodeSource nodejs package also ships, so dpkg refuses to unpack nodejs
    # while libnode-dev is still installed.
    if apt.installed(context, "libnode-dev"):
        context.log("Removing distro libnode-dev (conflicts with NodeSource nodejs package)")
        tools.sudo(context, ["apt-get", "remove", "-y", "libnode-dev"], check=False)

    setup = context.tmpdir() / "setup_lts.x"
    fetch.download(context, SETUP_URL, setup)
    if tools.sudo(context, ["-E", "bash", setup], check=False) != 0:
        raise StepFailed("NodeSource setup script failed")
    apt.install(context, "nodejs")
    # Without the NodeSource repository in place, apt installs the distro's
    # nodejs, which on jammy is 12.
    major = _major(context) if context.which("node") is not None else ""
    if not _new_enough(major):
        raise StepFailed(
            f"Node.js is {major or 'absent'} after installing; need at least {MIN_MAJOR}"
        )


def _npm_global(context: StepContext, package: str) -> None:
    tools.npm_install_g(context, package)
    target = tools.local_bin(context) / package
    tools.note_shadowed(context, package, target)
    tools.require_runs(context, target)


def install_pyright(context: StepContext) -> None:
    if not tools.announce(context, "pyright", context.which("pyright") is not None):
        return
    tools.require_command(context, "npm")
    _npm_global(context, "pyright")


def install_bash_ls(context: StepContext) -> None:
    # For the bashls server the Neovim config enables. npm's package is the
    # only distribution upstream publishes.
    name = "bash-language-server"
    if not tools.announce(context, name, context.which(name) is not None):
        return
    tools.require_command(context, "npm")
    _npm_global(context, name)


def install_ccusage(context: StepContext) -> None:
    tools.require_command(context, "npm")
    if not tools.announce(context, "ccusage", context.which("ccusage") is not None):
        return
    _npm_global(context, "ccusage")


STEPS = (
    Step("install_node", install_node),
    Step("install_pyright", install_pyright),
    Step("install_bash_ls", install_bash_ls),
    Step("install_ccusage", install_ccusage),
)
