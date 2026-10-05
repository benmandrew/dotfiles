#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install-common.sh"

# A step's output is held in a file while it runs, so a debconf dialog would be
# both invisible and unanswerable. noninteractive is the frontend that never
# opens one, taking each package's default instead.
export DEBIAN_FRONTEND=noninteractive

install_apt_packages_if_missing() {
    if [[ -n "${UPGRADE:-}" ]]; then
        log "Upgrading base packages: $*"
        sudo apt-get update || return 1
        sudo apt-get install -y "$@"
        return
    fi
    local missing_packages=()
    local package
    for package in "$@"; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing_packages+=("${package}")
        fi
    done
    if ((${#missing_packages[@]} == 0)); then
        log "Base packages already installed; skipping"
        return
    fi
    log "Installing missing base packages: ${missing_packages[*]}"
    # A fresh machine or container may never have fetched the package lists,
    # and stale ones name versions the mirror no longer carries.
    sudo apt-get update || return 1
    sudo apt-get install -y "${missing_packages[@]}"
}

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
    download "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${GIT_CORE_PPA_FINGERPRINT}" \
        "${tmp}" || return 1
    # Check the key that came back is the pinned one before apt is told to
    # trust everything it signs.
    if ! gpg --show-keys --with-colons "${tmp}" 2>/dev/null |
        awk -F: '/^fpr:/ { print $10 }' | grep -qx "${GIT_CORE_PPA_FINGERPRINT}"; then
        rm -f "${tmp}"
        err "git-core PPA key does not carry the pinned fingerprint"
        return 1
    fi
    sudo mkdir -p -m 755 /etc/apt/keyrings || return 1
    gpg --dearmor <"${tmp}" >"${tmp}.gpg" || return 1
    sudo install -m 644 "${tmp}.gpg" "${keyring}" || return 1
    rm -f "${tmp}" "${tmp}.gpg"
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
    if command -v perf >/dev/null 2>&1; then
        log "perf already installed; skipping"
        return
    fi
    log "Installing perf (linux-tools-generic)"
    # linux-tools-generic depends on an exact-version linux-tools-$(uname -r)
    # package. Cloud/CI runners often run a custom kernel with no matching
    # package in the archive, so this install is best-effort: warn and
    # continue rather than failing the whole script.
    if ! sudo apt-get install -y linux-tools-generic; then
        log "WARNING: failed to install linux-tools-generic (perf); skipping, this is expected on some cloud kernels"
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
    printf '%s\n' "${desired}" | sudo tee "${conf}" >/dev/null
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

remove_conflicting_libnode_dev() {
    # The distro-provided libnode-dev ships headers (e.g. common.gypi) that
    # the NodeSource nodejs package also ships, so dpkg refuses to unpack
    # nodejs while libnode-dev is still installed.
    if dpkg -s libnode-dev >/dev/null 2>&1; then
        log "Removing distro libnode-dev (conflicts with NodeSource nodejs package)"
        sudo apt-get remove -y libnode-dev
    fi
}

install_node() {
    if command -v node >/dev/null 2>&1; then
        local node_major
        node_major="$(node --version | cut -d. -f1 | tr -d 'v')"
        if ((node_major >= 20)); then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Node.js ${node_major} already installed; skipping"
                return
            fi
            log "Upgrading Node.js LTS"
            sudo apt-get update || return 1
            remove_conflicting_libnode_dev
            sudo apt-get install -y nodejs || return 1
            require_runs node
            return
        fi
        log "Node.js ${node_major} < 20; upgrading to LTS"
    else
        log "Installing Node.js LTS"
    fi
    remove_conflicting_libnode_dev
    local setup_path
    setup_path="$(mktemp)"
    download https://deb.nodesource.com/setup_lts.x "${setup_path}" || return 1
    if ! sudo -E bash "${setup_path}"; then
        rm -f "${setup_path}"
        err "NodeSource setup script failed"
        return 1
    fi
    rm -f "${setup_path}"
    sudo apt-get install -y nodejs || return 1
    # Without the NodeSource repository in place, apt installs the distro's
    # nodejs, which on jammy is 12.
    hash -r
    local installed_major
    installed_major="$(node --version 2>/dev/null | cut -d. -f1 | tr -d 'v')"
    if [[ ! "${installed_major}" =~ ^[0-9]+$ ]] || ((installed_major < 20)); then
        err "Node.js is ${installed_major:-absent} after installing; need at least 20"
        return 1
    fi
}

# Neovim 0.12, for the built-in completion the config uses. The 0.12.5 release
# carries no shasum.txt, so the tarball is checked against the digest GitHub
# records for it instead.
NEOVIM_MIN_VERSION="0.12.0"

install_neovim_if_missing() {
    local os_arch nvim_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" == "aarch64" ]]; then
        nvim_arch="arm64"
    else
        nvim_arch="${os_arch}"
    fi
    local nvim_dir="nvim-linux-${nvim_arch}"
    local nvim_path="/opt/${nvim_dir}/bin/nvim"
    local tag
    # shellcheck disable=SC2154  # NEOVIM_VERSION is in install-common.sh's pin block
    tag="$(pinned_tag "${NEOVIM_VERSION}" neovim/neovim)" || return 1
    # The first line of `nvim --version` is "NVIM v0.12.5", or for a nightly
    # "NVIM v0.13.0-dev-123+gabcdef", whose suffix version_gte cannot read.
    local probe="${nvim_path}" current="" bare=""
    if [[ ! -x "${probe}" ]]; then
        probe="$(command -v nvim 2>/dev/null)" || probe=""
    fi
    if [[ -n "${probe}" ]]; then
        current="$("${probe}" --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
        bare="${current#v}"
        bare="${bare%%[-+]*}"
    fi
    if [[ -n "${bare}" ]] && version_gte "${bare}" "${NEOVIM_MIN_VERSION}"; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "Neovim ${current} already installed; skipping"
            return
        fi
        if [[ "${probe}" == "${nvim_path}" && "${current}" == "${tag}" ]]; then
            log "Neovim ${current} already at latest; skipping"
            return
        fi
        log "Upgrading Neovim ${current} to ${tag}"
    elif [[ -n "${current}" ]]; then
        log "Neovim ${current} < ${NEOVIM_MIN_VERSION}; installing ${tag}"
    else
        log "Installing Neovim ${tag}"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    download_verified_github neovim/neovim "${tag}" "${nvim_dir}.tar.gz" \
        "${tmp_dir}/${nvim_dir}.tar.gz" || return 1
    # Unpacked before the old tree goes, so a bad tarball leaves Neovim working.
    tar -C "${tmp_dir}" -xf "${tmp_dir}/${nvim_dir}.tar.gz" || return 1
    if [[ ! -x "${tmp_dir}/${nvim_dir}/bin/nvim" ]]; then
        err "No bin/nvim inside ${nvim_dir}.tar.gz; upstream layout changed"
        return 1
    fi
    sudo rm -rf "/opt/${nvim_dir}" || return 1
    sudo mv "${tmp_dir}/${nvim_dir}" "/opt/${nvim_dir}" || return 1
    sudo chown -R root:root "/opt/${nvim_dir}" || return 1
    note_shadowed nvim "${nvim_path}"
    require_runs "${nvim_path}" --version
}

main() {
    parse_args "$@"
    log "Checking prerequisites"
    require_cmd sudo
    require_cmd ssh-keygen
    require_cmd dpkg
    require_cmd apt
    start_sudo_askpass
    start_sudo_keepalive
    # Prerequisites, deliberately outside run_step: the rest of the install is
    # built on these, so a failure here aborts under errexit rather than being
    # collected and reported at the end.
    quiet install_apt_packages_if_missing git curl gpg build-essential zsh entr libevent-dev libncurses-dev pkg-config bubblewrap bison autoconf unzip
    quiet install_perf
    # Early, so every later step and the user's own work runs against the
    # newer git rather than jammy's 2.34.1.
    run_step install_git
    run_step install_inotify_limits
    run_step install_vscode_unattended_upgrades
    run_step install_tmux_from_source
    run_step install_cmake
    run_step install_nix
    run_step install_direnv
    run_step install_nix_direnv

    run_step install_zinit
    run_step install_rust
    run_step install_rust_analyzer
    run_step install_eza
    run_step install_fd
    run_step install_bat
    run_step install_btop
    run_step install_ripgrep
    run_step install_git_delta
    run_step install_jq
    run_step install_zstd
    run_step install_hyperfine
    run_step install_zoxide
    run_step install_fzf
    run_step install_fzf_tab
    run_step install_zsh_autosuggestions
    run_step install_atuin
    run_step install_gh
    run_step install_gh_stack
    run_step install_gh_stack_skill
    run_step install_tailscale
    run_step install_claude_code
    run_step install_rtk
    run_step install_node
    run_step install_uv
    run_step install_clangd
    run_step install_pyright
    run_step install_bash_ls
    run_step install_lua_ls
    run_step install_opam
    run_step install_go
    run_step install_moor
    run_step install_glow
    run_step install_treehouse
    run_step install_git_absorb
    run_step install_gitleaks
    run_step install_sccache
    run_step install_ripgrep_all
    run_step install_difftastic
    run_step install_cargo_nextest
    run_step install_ansible_lint
    run_step install_elan
    run_step install_fzf_git
    run_step install_cargo_extras
    run_step install_ccusage
    run_step install_starship
    run_step install_tmux_plugins
    run_step install_wezterm
    run_step set_default_terminal_wezterm
    run_step install_nerd_font

    run_optional_step obsidian \
        "Obsidian: notes app, plus obsync and the 15-minute vault sync cron entry it schedules. Ships the 'obsidian' CLI, but needs the GUI app running — a dev-machine tool, not a server one." \
        install_obsidian_stack

    run_optional_step zathura \
        "zathura: keyboard-driven PDF viewer, with SyncTeX inverse search into VS Code. A GUI app — noise on a server." \
        install_zathura

    run_optional_step latex \
        "LaTeX: upstream TeX Live in ~/.local/texlive with latexmk and biber, for building papers. Several gigabytes, and pointless where no one writes documents." \
        install_latex

    run_optional_step typst \
        "Typst: markup typesetting compiler, a single binary in ~/.local/bin. For writing documents, not for a server." \
        install_typst

    run_optional_step docker \
        "Docker: container engine with the buildx and compose plugins. Adds you to the docker group, which is root-equivalent." \
        install_docker

    run_step install_neovim_if_missing

    # After every other step: it runs each tool to get its completion script.
    run_step install_zsh_completions

    print_chezmoi_init_hint
    check_failed
}

main "$@"
