#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# A library of steps: scripts/installer runs each function here in a process of
# its own, through legacy-step.sh. Run directly, this hands over to the entry
# point, so an old habit or an old document still installs.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exec "${SCRIPT_DIR}/install.sh" "$@"
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

# A step's output is held in a file while it runs, so a debconf dialog would be
# both invisible and unanswerable. noninteractive is the frontend that never
# opens one, taking each package's default instead.
export DEBIAN_FRONTEND=noninteractive

# Ubuntu freezes git's upstream version at release and backports fixes only, so
# jammy is on 2.34.1 and stays there for the life of the release. That is old
# enough to matter for the config this repo deploys: zdiff3 for
# merge.conflictStyle arrived in 2.35, rebase.updateRefs in 2.38 and
# push.autoSetupRemote in 2.37, and dot_gitconfig.tmpl sets all three. The
# git-core PPA is maintained by the Debian git packagers, tracks upstream
# releases, and publishes amd64 and arm64 for every supported series.
GIT_MIN_VERSION="2.35.0"
# Launchpad reports this for ~git-core/+archive/ubuntu/ppa. Pinned because the
# keyserver below is authenticated by TLS alone.
GIT_CORE_PPA_FINGERPRINT="F911AB184317630C59970973E363C90F8F1B6217"

install_git() {
    local version oldest=""
    version="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    # sort -V, since a string compare puts 2.5.0 above 2.34.1. The minimum
    # sorting first means the installed git is at least that.
    if [[ -n "${version}" ]]; then
        oldest="$(printf '%s\n%s\n' "${GIT_MIN_VERSION}" "${version}" | sort -V | head -n 1)"
    fi
    if [[ "${oldest}" == "${GIT_MIN_VERSION}" && -z "${UPGRADE:-}" ]]; then
        log "git ${version} is at least ${GIT_MIN_VERSION}; skipping"
        return
    fi
    # A PPA is an Ubuntu construct, and the archive only builds for supported
    # series. Anything else keeps whatever git the distro ships.
    local id codename
    id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
    if [[ "${id}" != "ubuntu" || -z "${codename}" ]]; then
        log "not Ubuntu; keeping git ${version:-(absent)} as the distro ships it"
        return
    fi

    log "Installing git from the git-core PPA (distro git is ${version:-absent})"
    local tmp keyring="/etc/apt/keyrings/git-core-ppa.gpg"
    tmp="$(mktemp)"
    trap 'rm -f "${tmp}" "${tmp}.gpg"; trap - RETURN' RETURN
    download "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${GIT_CORE_PPA_FINGERPRINT}" \
        "${tmp}" || return 1
    # Check the key that came back is the pinned one before apt is told to
    # trust everything it signs.
    if ! gpg --show-keys --with-colons "${tmp}" 2>/dev/null |
        awk -F: '/^fpr:/ { print $10 }' | grep -qx "${GIT_CORE_PPA_FINGERPRINT}"; then
        err "git-core PPA key does not carry the pinned fingerprint"
        return 1
    fi
    sudo mkdir -p -m 755 /etc/apt/keyrings || return 1
    gpg --dearmor <"${tmp}" >"${tmp}.gpg" || return 1
    sudo install -m 644 "${tmp}.gpg" "${keyring}" || return 1
    local arch
    arch="$(dpkg --print-architecture)" || return 1
    printf 'deb [arch=%s signed-by=%s] https://ppa.launchpadcontent.net/git-core/ppa/ubuntu %s main\n' \
        "${arch}" "${keyring}" "${codename}" |
        sudo tee /etc/apt/sources.list.d/git-core-ppa.list >/dev/null || return 1
    sudo apt-get update || return 1
    sudo apt-get install -y git || return 1
    # apt can succeed and still leave the old git, when the PPA has no build
    # for this series or a pin holds the distro's one.
    hash -r
    version="$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    if [[ -z "${version}" ]] || ! version_gte "${version}" "${GIT_MIN_VERSION}"; then
        err "git is ${version:-absent} after installing from the PPA; need at least ${GIT_MIN_VERSION}"
        return 1
    fi
    log "git is now ${version}"
}

install_perf() {
    # Run it rather than find it: /usr/bin/perf is linux-tools-common's wrapper,
    # which stays after a kernel update and then fails with "perf not found for
    # kernel", since linux-tools-generic tracks the GA kernel, not an HWE one.
    local kernel_tools
    kernel_tools="linux-tools-$(uname -r)"
    if perf --version >/dev/null 2>&1; then
        log "perf already installed; skipping"
        return
    fi
    log "Installing perf (linux-tools-generic and ${kernel_tools})"
    # Cloud/CI runners often run a custom kernel with no matching package in
    # the archive, so this install is best-effort: warn and continue rather
    # than failing the whole script.
    if ! sudo apt-get install -y linux-tools-generic "${kernel_tools}"; then
        log "WARNING: failed to install ${kernel_tools} (perf); skipping, this is expected on some cloud kernels"
    fi
}

install_inotify_limits() {
    # VS Code and other file watchers exhaust the default inotify limits on
    # large workspaces, producing "Unable to watch for file changes". Raise the
    # persistent limits via a sysctl drop-in.
    local conf="/etc/sysctl.d/60-inotify-watches.conf"
    local desired="fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512"
    local current=""
    [[ -f "${conf}" ]] && current="$(<"${conf}")"
    if [[ "${current}" == "${desired}" ]]; then
        log "inotify limits already configured; skipping"
        return
    fi
    log "Configuring inotify watch/instance limits"
    printf '%s\n' "${desired}" | sudo tee "${conf}" >/dev/null || return 1
    sudo sysctl -p "${conf}" >/dev/null
}

install_vscode_unattended_upgrades() {
    # The code .deb adds Microsoft's apt repository, but unattended-upgrades
    # only takes Ubuntu origins, so VS Code fell behind and prompted for a
    # manual .deb download. Allow the repository's origin; the managed
    # "update.mode": "none" stops VS Code's own prompt.
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        log "unattended-upgrades not installed; skipping VS Code origin"
        return
    fi
    local conf="/etc/apt/apt.conf.d/51unattended-upgrades-vscode"
    local desired='Unattended-Upgrade::Origins-Pattern { "origin=code stable,archive=stable"; };'
    local current=""
    [[ -f "${conf}" ]] && current="$(<"${conf}")"
    if [[ "${current}" == "${desired}" ]]; then
        log "unattended-upgrades already allows VS Code; skipping"
        return
    fi
    log "Allowing unattended-upgrades to update VS Code"
    printf '%s\n' "${desired}" | sudo tee "${conf}" >/dev/null
}

set_default_terminal_wezterm() {
    # GNOME's Ctrl+Alt+T and "Open in Terminal" run x-terminal-emulator, which
    # otherwise points at whichever terminal registered the highest priority.
    # The wezterm-nightly deb registers open-wezterm-here; without it (headless,
    # or arm64, where install_wezterm skips) there is nothing to point at.
    local target="/usr/bin/open-wezterm-here"
    local query
    query="$(update-alternatives --query x-terminal-emulator 2>/dev/null)"
    if ! grep -qxF "Alternative: ${target}" <<<"${query}"; then
        log "x-terminal-emulator: ${target} not registered; skipping"
        return
    fi
    if grep -qxF "Value: ${target}" <<<"${query}"; then
        log "x-terminal-emulator already WezTerm; skipping"
        return
    fi
    log "Setting x-terminal-emulator to WezTerm"
    sudo update-alternatives --set x-terminal-emulator "${target}"
}
