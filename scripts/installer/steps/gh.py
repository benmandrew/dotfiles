"""The GitHub CLI: Homebrew on macOS, GitHub's own apt repository on Linux."""

from __future__ import annotations

from .. import apt, brew, fetch, tools
from ..runner import Step, StepContext

KEYRING_URL = "https://cli.github.com/packages/githubcli-archive-keyring.gpg"
KEYRING = "githubcli-archive-keyring.gpg"
SOURCE_LIST = "github-cli.list"


def _installed_from(context: StepContext) -> str:
    """Where apt got the installed gh: the line after the one `***` marks."""
    policy = context.capture(["apt-cache", "policy", "gh"], quiet=True) or ""
    lines = policy.splitlines()
    for number, line in enumerate(lines[:-1]):
        if line.startswith(" *** "):
            return lines[number + 1]
    return ""


def install(context: StepContext) -> None:
    present = context.which("gh") is not None
    if context.host.system == "Darwin":
        if tools.announce(context, "GitHub CLI", present):
            brew.install_or_upgrade(context, "gh", present)
            tools.require_runs(context, "gh")
        return

    # Linux: install from GitHub's official apt repo, since Ubuntu's `gh`
    # package is years out of date. Skip only when gh is present AND already
    # sourced from the official repo, so a gh first installed from Ubuntu's
    # repos gets migrated to the official one on the next run. The installed
    # version's origin is checked as well as the list file, since a failed
    # `apt-get update` after writing the list leaves Ubuntu's gh in place.
    source_list = apt.SOURCES / SOURCE_LIST
    if (
        present
        and source_list.is_file()
        and "cli.github.com" in _installed_from(context)
        and not context.upgrade
    ):
        context.log("GitHub CLI already installed; skipping")
        return
    context.log("Installing GitHub CLI from official apt repo")
    tools.sudo(context, ["mkdir", "-p", "-m", "755", apt.KEYRINGS])
    keyring = context.tmpdir() / KEYRING
    fetch.download(context, KEYRING_URL, keyring)
    tools.sudo(context, ["install", "-m", "644", keyring, apt.KEYRINGS / KEYRING])
    tools.sudo_write(
        context,
        source_list,
        f"deb [arch={apt.architecture(context)} signed-by={apt.KEYRINGS / KEYRING}]"
        " https://cli.github.com/packages stable main\n",
    )
    apt.update(context)
    apt.install(context, "gh")
    tools.require_runs(context, "gh")


STEPS = (Step("install_gh", install),)
