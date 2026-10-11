"""Steps that only ask a package manager: the base lists, jq, zstd, clangd."""

from __future__ import annotations

from .. import apt, brew, tools
from ..runner import Step, StepContext, StepFailed


def install_apt_packages(context: StepContext) -> None:
    packages = context.args
    if context.upgrade:
        context.log(f"Upgrading base packages: {' '.join(packages)}")
        apt.update(context)
        apt.install(context, *packages)
        return
    missing = [package for package in packages if not apt.installed(context, package)]
    if not missing:
        context.log("Base packages already installed; skipping")
        return
    context.log(f"Installing missing base packages: {' '.join(missing)}")
    # A fresh machine or container may never have fetched the package lists,
    # and stale ones name versions the mirror no longer carries.
    apt.update(context)
    apt.install(context, *missing)


def install_brew_formulae(context: StepContext) -> None:
    formulae = context.args
    if context.upgrade:
        context.log(f"Upgrading Homebrew formulae: {' '.join(formulae)}")
        context.call(["brew", "update"])
        # A batch `brew upgrade` stops at the formula that failed and takes the
        # rest of the list with it. The failure used to be discarded and only
        # entirely-missing formulae reinstalled, so a half-finished upgrade
        # reported success. Retry each formula on its own instead, and fail the
        # step for whatever is still broken at the end.
        failed = []
        if context.call(["brew", "upgrade", *formulae]) != 0:
            context.log("Batch upgrade failed; retrying each formula on its own")
            for formula in formulae:
                verb = "upgrade" if brew.formula_installed(context, formula) else "install"
                if context.call(["brew", verb, formula]) != 0:
                    failed.append(formula)
        if failed:
            raise StepFailed(f"Homebrew formulae failed: {' '.join(failed)}")
        return
    missing = [formula for formula in formulae if not brew.formula_installed(context, formula)]
    if not missing:
        context.log("Homebrew formulae already installed; skipping")
        return
    context.log(f"Installing missing Homebrew formulae: {' '.join(missing)}")
    context.call(["brew", "update"])
    context.run(["brew", "install", *missing])


def _manage(context: StepContext, label: str, present: bool, formula: str, *packages: str) -> bool:
    """Install or upgrade through the platform's package manager.

    False when the tool is there and the run is not an upgrade.
    """
    if not tools.announce(context, label, present):
        return False
    if context.host.system == "Darwin":
        brew.install_or_upgrade(context, formula, present)
    else:
        apt.install(context, *packages)
    return True


def install_jq(context: StepContext) -> None:
    if _manage(context, "jq", context.which("jq") is not None, "jq", "jq"):
        tools.require_runs(context, "jq")


def install_zstd(context: StepContext) -> None:
    # apt splits zstd across two packages: `zstd` is the CLI (which GNU tar
    # shells out to for .tar.zst) and `libzstd-dev` the headers, so cargo/cc
    # builds link the system copy instead of vendoring their own. Ubuntu images
    # often ship the CLI already, so the guard checks for the dev package too
    # or the headers never land. brew's single formula covers both.
    present = context.which("zstd") is not None and (
        context.host.system == "Darwin" or apt.installed(context, "libzstd-dev")
    )
    if _manage(context, "zstd", present, "zstd", "zstd", "libzstd-dev"):
        tools.require_runs(context, "zstd")


def _clangd_path(context: StepContext) -> str:
    """The clangd this step installs.

    brew's llvm is keg-only, so the clangd it installs is off PATH, and by name
    the probe would find Xcode's /usr/bin/clangd instead.
    """
    if context.host.system != "Darwin":
        return "clangd"
    prefix = context.capture(["brew", "--prefix", "llvm"])
    if prefix is None:
        raise StepFailed
    return f"{prefix}/bin/clangd"


def install_clangd(context: StepContext) -> None:
    if _manage(context, "clangd", context.which("clangd") is not None, "llvm", "clangd"):
        tools.require_runs(context, _clangd_path(context))


STEPS = (
    Step("install_apt_packages_if_missing", install_apt_packages),
    Step("install_brew_formulae_if_missing", install_brew_formulae),
    Step("install_jq", install_jq),
    Step("install_zstd", install_zstd),
    Step("install_clangd", install_clangd),
)
