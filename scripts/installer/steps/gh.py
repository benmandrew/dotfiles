"""The GitHub CLI, from Homebrew on macOS and GitHub's own apt repository on
Linux, and the gh-stack extension and skill."""

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


def _authenticated(context: StepContext) -> bool:
    """Whether gh holds a credential.

    Both gh-stack steps hit the GitHub API, to resolve the extension's release
    and to read the skill's contents, so both need an authenticated gh. Nothing
    here runs `gh auth login`, and it cannot be automated, so on a freshly
    provisioned box the credential is not there yet. The steps skip with a
    warning rather than failing the run; the next install after the user has
    authenticated picks both up.
    """
    return context.which("gh") is not None and context.succeeds(["gh", "auth", "status"])


def install_gh_stack(context: StepContext) -> None:
    if not _authenticated(context):
        context.log(
            "gh is not authenticated; skipping gh-stack extension"
            " (run 'gh auth login', then re-run)"
        )
        return
    # Match on the source repo rather than the extension name, so a same-named
    # extension from another owner is replaced rather than mistaken for this one.
    extensions = context.capture(["gh", "extension", "list"], quiet=True) or ""
    if "github/gh-stack" not in extensions:
        context.log("Installing gh-stack extension")
        context.run(["gh", "extension", "install", "github/gh-stack"])
    elif context.upgrade:
        context.log("Upgrading gh-stack extension")
        tools.retry_once(context, ["gh", "extension", "upgrade", "gh-stack"])
    else:
        context.log("gh-stack extension already installed; skipping")


def install_gh_stack_skill(context: StepContext) -> None:
    if not _authenticated(context):
        context.log(
            "gh is not authenticated; skipping gh-stack skill (run 'gh auth login', then re-run)"
        )
        return
    # User scope, so the skill applies in every repo instead of only whichever
    # one the install happened to run from. It lands in ~/.claude/skills/gh-stack,
    # a directory chezmoi manages through skills/.keep alone, so it leaves the
    # skill itself untouched.
    scope = ["--agent", "claude-code", "--scope", "user"]
    listing = ["gh", "skill", "list", *scope, "--json", "skillName", "--jq", ".[].skillName"]
    skills = (context.capture(listing, quiet=True) or "").splitlines()
    if "gh-stack" not in skills:
        context.log("Installing gh-stack skill for Claude Code")
        context.run(["gh", "skill", "install", "github/gh-stack", "gh-stack", *scope, "--force"])
    elif context.upgrade:
        context.log("Upgrading gh-stack skill")
        tools.retry_once(context, ["gh", "skill", "update", "gh-stack", "--all"])
    else:
        context.log("gh-stack skill already installed; skipping")


STEPS = (
    Step("install_gh", install),
    Step("install_gh_stack", install_gh_stack),
    Step("install_gh_stack_skill", install_gh_stack_skill),
)
