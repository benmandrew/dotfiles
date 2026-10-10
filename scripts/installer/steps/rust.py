"""Rust, through rustup, and rust-analyzer as a rustup component."""

from __future__ import annotations

from .. import tools
from ..runner import Step, StepContext

RUSTUP_URL = "https://sh.rustup.rs"


def install_rust(context: StepContext) -> None:
    tools.load_cargo_env(context)
    # Run cargo rather than find it: rustup-init lays down the proxies in
    # ~/.cargo/bin before it fetches a toolchain, so an interrupted first
    # install leaves a cargo on PATH that fails with "no default toolchain".
    # Rerunning rustup-init over that finishes the job.
    if context.which("rustup") is not None and context.succeeds(["cargo", "--version"]):
        if not context.upgrade:
            context.log("Rust already installed; skipping")
            return
        context.log("Upgrading Rust")
        tools.retry_once(context, ["rustup", "update"])
        tools.require_runs(context, "cargo")
        return
    context.log("Installing Rust")
    tools.run_downloaded(context, RUSTUP_URL, ["sh"], "-y")
    tools.load_cargo_env(context)
    tools.require_runs(context, "cargo")


def install_rust_analyzer(context: StepContext) -> None:
    tools.load_cargo_env(context)
    # rustup puts a rust-analyzer proxy in ~/.cargo/bin whether or not the
    # component is installed, so finding it on PATH always passes. The proxy
    # only runs once the component is there.
    if context.succeeds(["rust-analyzer", "--version"]):
        if not context.upgrade:
            context.log("rust-analyzer already installed; skipping")
            return
        context.log("Upgrading rust-analyzer")
    else:
        context.log("Installing rust-analyzer")
    tools.require_command(context, "rustup")
    tools.retry_once(context, ["rustup", "component", "add", "rust-analyzer"])
    tools.require_runs(context, "rust-analyzer")


STEPS = (
    Step("install_rust", install_rust),
    Step("install_rust_analyzer", install_rust_analyzer),
)
