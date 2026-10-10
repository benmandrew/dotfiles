#!/bin/bash

# The install steps that are still bash, and the helpers they share. Nothing
# here runs a step: scripts/installer does, calling one function per process
# through legacy-step.sh. PLAN.md has the order they are being ported in.

# Set by the runner, which parses the arguments.
UPGRADE="${DOTFILES_UPGRADE:-}"

# fd 3 is the terminal, held aside so log and err still reach it from inside a
# step whose own output is being redirected to a file. The runner names the
# descriptor to copy in DOTFILES_TERM_FD. Without one, as under `make pins`, it
# is stderr.
exec 3>&"${DOTFILES_TERM_FD:-2}"

# Homebrew 6 has ask mode on by default, so `brew install` and `brew upgrade`
# stop for a [y/n] confirmation whenever the plan reaches past the packages
# named on the command line — a dependency bump, a cask's dependants. Nothing
# here answers those prompts, so an install left to run unattended stalls on the
# first one. HOMEBREW_NO_ASK is what turns the default back off; the equivalent
# per-command flags are --no-ask/--yes.
export HOMEBREW_NO_ASK=1

log() {
    if [[ "$*" == *"skipping"* ]]; then
        printf "\033[1;33m[install]\033[0m %s\n" "$*" >&3
    elif [[ "$*" == *"pgrading"* ]]; then
        printf "\033[1;36m[install]\033[0m %s\n" "$*" >&3
    else
        printf "\033[1;32m[install]\033[0m %s\n" "$*" >&3
    fi
}

err() {
    printf "\033[1;31m[install]\033[0m ERROR: %s\n" "$*" >&3
}

# An installer's exit status says nothing about the binary it leaves behind. On
# 14 September 2026 `claude update` upgraded an npm install through npm, left the
# package's placeholder where the native binary belongs, and exited 0; the step
# passed, its log was deleted, and the next `claude` failed. So every path that
# installs or upgrades an executable ends by running it. The probe must print and
# exit: no network, no GUI, nothing written. `hash -r` first, since bash keeps
# the path it last ran a command from, which an install can move.
require_runs() {
    local cmd="$1"
    shift
    if (($# == 0)); then
        set -- --version
    fi
    hash -r
    if ! "${cmd}" "$@" </dev/null >/dev/null 2>&1; then
        local resolved
        resolved="$(command -v "${cmd}" 2>/dev/null)" || resolved="not on PATH"
        err "${cmd} does not run after installing (${resolved}; probed with '$*')"
        return 1
    fi
}

# For vendor self-updaters, which fetch on their own rather than through
# download() and its curl retries. In the same 14 September run `rustup update`
# failed on one dropped download of a nightly component, rolled back cleanly,
# and succeeded when retried by hand. These updaters leave the old version in
# place on failure, so a second attempt is safe.
retry_once() {
    "$@" && return 0
    log "$1 failed; retrying once"
    "$@"
}

# A step that installs to a fixed path can still lose to another copy earlier on
# PATH, one from a different install method, which then answers for the tool on
# every call. Name that copy rather than delete it: unlike the old starship in
# /usr/local/bin, it may belong to a package manager. Nothing is said when the
# command is not on PATH at all, as on a machine that has not run chezmoi apply.
note_shadowed() {
    local cmd="$1" target="$2" found
    hash -r
    found="$(command -v "${cmd}" 2>/dev/null)" || return 0
    if [[ "${found}" != "${target}" ]]; then
        log "Note: ${cmd} on PATH is ${found}, which shadows the copy just installed at ${target}"
    fi
}

# Every fetch here goes to a third-party host that rate-limits, and one bad
# minute takes a whole step down — a GitHub codeload 429 is what prompted this.
# curl retries transient HTTP status on its own (408, 429 and the 5xx family,
# honouring Retry-After when the server sends one) with an exponential backoff
# from 1s, so five attempts span about 30s. --retry-connrefused adds the
# connection-level case, which a bare --retry ignores. Deliberately not
# --retry-all-errors: that retries a 404 too, so a release asset renamed
# upstream would burn the full backoff before reporting the obvious.
_CURL_RETRY_OPTS=(--retry 5 --retry-connrefused --retry-max-time 120)

# Fetch a URL to a path. Failure is reported and returned, never ignored:
# errexit does not apply inside a step (legacy-step.sh calls it left of `||`,
# and bash disables errexit for everything there), so a step whose download
# failed would otherwise carry on and unpack, build and install a file that is
# not there.
download() {
    local url="$1" dest="$2"
    if ! curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" "${url}" -o "${dest}"; then
        err "Download failed: ${url}"
        return 1
    fi
}

# sha256 of a file, from whichever tool the platform has: coreutils on Linux,
# shasum on macOS.
sha256_file() {
    local file="$1" out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(sha256sum "${file}")" || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out="$(shasum -a 256 "${file}")" || return 1
    else
        err "Neither sha256sum nor shasum is on PATH; cannot verify downloads"
        return 1
    fi
    # Both print `<hash>  <path>`.
    printf '%s\n' "${out%% *}"
}

# Check a downloaded file against a checksum manifest published beside it.
#
# The manifests disagree on layout. Some releases ship one line per asset
# (charmbracelet, kunchenguid and gitleaks call it checksums.txt, Kitware and
# ryanoasis SHA-256.txt), some a file per asset holding the hash and the name
# (BurntSushi, atuinsh, wez, nextest-rs), and mozilla ships the hash on its own
# with no name at all. atuinsh prefixes the name with `*`, BSD's binary marker.
# So the hash is the first field of the line naming the asset, falling back to
# the only field when the manifest names nothing.
#
# What this buys and what it does not: the manifest sits in the same release as
# the asset, so it cannot detect a release the publisher's own account was used
# to rewrite. It does catch a truncated or corrupted download, and an asset
# swapped underneath a tag pinned below — which is the failure the pins exist
# to make visible.
verify_sha256() {
    local file="$1" manifest_url="$2" asset="$3"
    local manifest expected actual
    manifest="$(mktemp)"
    if ! download "${manifest_url}" "${manifest}"; then
        rm -f "${manifest}"
        err "Could not fetch the checksum manifest for ${asset}"
        return 1
    fi
    # Matched on the whole name field rather than on a substring of the line,
    # because a manifest listing `<asset>.tar.gz` also lists
    # `<asset>.tar.gz.sbom.json` beside it and a substring match would take
    # whichever came first. The leading `*` is BSD's binary marker.
    expected="$(awk -v a="${asset}" \
        '{ n = $NF; sub(/^\*/, "", n); if (n == a) { print $1; exit } }' "${manifest}")"
    if [[ -z "${expected}" ]]; then
        expected="$(awk 'NF == 1 { print $1; exit }' "${manifest}")"
    fi
    rm -f "${manifest}"
    expected="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"
    if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
        err "No sha256 for ${asset} in ${manifest_url}"
        return 1
    fi
    actual="$(sha256_file "${file}")" || return 1
    actual="$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${actual}" != "${expected}" ]]; then
        err "Checksum mismatch for ${asset}: expected ${expected}, got ${actual}"
        return 1
    fi
}

# download, then verify. The name looked up in the manifest is the last path
# component of the download URL.
download_verified() {
    local url="$1" dest="$2" manifest_url="$3"
    download "${url}" "${dest}" || return 1
    verify_sha256 "${dest}" "${manifest_url}" "${url##*/}" || return 1
}

# Shadowing sudo for the bash steps. The runner (installer/sudo.py) reads the
# password once and exports SUDO_ASKPASS, and -A is what makes sudo use it. A
# function is not inherited by the subprocesses brew and the vendor installers
# run — brew adds -A itself, and the vendor scripts are handled by not needing
# sudo at all — so this only has to cover the call sites in this file, and
# covers them without each one having to know whether a helper is in play.
# `command sudo` where the flag would be wrong.
sudo() {
    if [[ -n "${SUDO_ASKPASS:-}" ]]; then
        command sudo -A "$@"
    else
        command sudo "$@"
    fi
}

# The token for GitHub API calls: GITHUB_TOKEN when set, else the one an
# authenticated gh holds, else none. Anonymous calls share a limit of 60 an hour
# per address, which `make pins` alone spends in two runs; gh's token lifts that
# to 5000 on any machine where `gh auth login` has been run. `gh auth token`
# exits non-zero when gh is not logged in, which leaves the call anonymous.
github_api_token() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        printf '%s' "${GITHUB_TOKEN}"
    elif command -v gh >/dev/null 2>&1; then
        gh auth token 2>/dev/null || true
    fi
}

# Wrapper around curl for GitHub API calls; adds an auth header when a token is
# available (see github_api_token) to avoid the unauthenticated rate limit on
# shared CI runner IPs.
# Same TLS floor as download(): these calls decide which version gets installed,
# so a downgrade to plaintext or to an obsolete TLS version matters here at
# least as much as on the fetch that follows.
github_api_curl() {
    local token
    token="$(github_api_token)"
    if [[ -n "${token}" ]]; then
        curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" \
            -H "Authorization: Bearer ${token}" "$@"
    else
        curl -fsSL --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" "$@"
    fi
}

# Why a GitHub API call failed, from the response headers curl dumped: the
# rate limit and when it resets, or the HTTP status. GitHub answers an
# exhausted limit with 403 (or 429) and x-ratelimit-remaining: 0, and curl's -f
# reduces that to "returned error: 403", which reads like a permissions fault.
_github_api_failure() {
    local headers="$1" status remaining reset when
    status="$(awk 'toupper($1) ~ /^HTTP\// { s = $2 } END { print s }' "${headers}" 2>/dev/null | tr -d '\r' || true)"
    remaining="$(awk -F': *' 'tolower($1) == "x-ratelimit-remaining" { r = $2 } END { print r }' "${headers}" 2>/dev/null | tr -d '\r' || true)"
    reset="$(awk -F': *' 'tolower($1) == "x-ratelimit-reset" { r = $2 } END { print r }' "${headers}" 2>/dev/null | tr -d '\r' || true)"
    if [[ "${remaining}" == "0" && "${reset}" =~ ^[0-9]+$ ]]; then
        # GNU date takes -d @epoch, BSD date -r epoch.
        when="$(date -d "@${reset}" '+%H:%M %Z' 2>/dev/null || date -r "${reset}" '+%H:%M %Z' 2>/dev/null || printf 'epoch %s' "${reset}")"
        printf 'rate limit exhausted until %s; set GITHUB_TOKEN or run gh auth login' "${when}"
    elif [[ -n "${status}" ]]; then
        printf 'HTTP %s' "${status}"
    else
        printf 'no response'
    fi
}

# The repo's latest release is not necessarily a desktop one. Obsidian ships
# Android from the same repo on its own cadence, and v1.13.8 (21 August 2026)
# carried a single Obsidian-1.13.8.apk with no .deb or tarball beside it — so
# github_latest_tag resolved a version whose desktop assets do not exist and the
# download 404ed. desktop-releases.json on the repo's master branch is what the
# app's own updater reads, so its latestVersion names the newest version that
# actually has desktop builds; here that is 1.13.7. The beta block repeats the
# same key further down, which -m1 skips.
obsidian_desktop_version() {
    local tmp
    tmp="$(mktemp)"
    # RETURN traps persist for the caller too until unset; see github_latest_tag.
    trap 'rm -f "${tmp}"; trap - RETURN' RETURN
    if ! download \
        https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/desktop-releases.json \
        "${tmp}"; then
        return 1
    fi
    local line version
    line="$(grep -m1 '"latestVersion"' "${tmp}" || true)"
    version="${line#*\"latestVersion\": \"}"
    version="${version%%\"*}"
    if [[ -z "${version}" ]]; then
        err "Obsidian: no latestVersion in desktop-releases.json; upstream format changed"
        return 1
    fi
    echo "${version}"
}

# safe_git/ensure_user_owns exist because upgrade paths for git-cloned tools
# have hit repos owned by root — e.g. from an earlier sudo or CI run — which
# makes plain git refuse ("dubious ownership") or fail to write. The Python
# steps have their own in installer/tools.py.
safe_git() {
    local dir="$1"
    shift
    git -c "safe.directory=${dir}" -C "${dir}" "$@"
}

ensure_user_owns() {
    local dir="$1"
    if [[ -d "${dir}" ]] && [[ ! -O "${dir}" ]]; then
        local user group
        user="$(id -un)"
        group="$(id -gn)"
        sudo chown -R "${user}:${group}" "${dir}"
    fi
}

# True when some package already put a completion function for $1 somewhere
# zsh looks by default. Homebrew links one for most of its formulae; the same
# tool installed from a release tarball on Linux comes with nothing.
_zsh_completion_installed() {
    local dir
    for dir in /opt/homebrew/share/zsh/site-functions \
        /usr/local/share/zsh/site-functions \
        /usr/share/zsh/site-functions \
        /usr/share/zsh/vendor-completions; do
        [[ -e "${dir}/_$1" ]] && return 0
    done
    return 1
}

# Generate zsh completions for the tools that can print their own but ship it
# nowhere useful. Runs after every other install step, since it invokes each
# binary. The output goes to the user site-functions directory that
# home/dot_zshrc.tmpl prepends to fpath.
#
# A tool whose completion is already installed system-wide is skipped rather
# than shadowed, so a later `brew upgrade` keeps ownership of it. delta is the
# exception that motivated this: nothing ships a _delta, and zsh's bundled
# _sccs registers the name `delta` for SCCS, so without a generated one
# git-delta completes SCCS flags.
install_zsh_completions() {
    local comp_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/zsh/site-functions"
    local spec cmd args out generated=0

    mkdir -p "${comp_dir}"

    # "<command>|<arguments that print a zsh completion script>"
    for spec in \
        "uv|generate-shell-completion zsh" \
        "uvx|--generate-shell-completion zsh" \
        "fd|--gen-completions zsh" \
        "delta|--generate-completion zsh" \
        "rustup|completions zsh" \
        "atuin|gen-completions --shell zsh" \
        "typst|completions zsh" \
        "chezmoi|completion zsh"; do
        cmd="${spec%%|*}"
        args="${spec#*|}"

        command -v "${cmd}" >/dev/null 2>&1 || continue
        _zsh_completion_installed "${cmd}" && continue

        # Via a temporary file: a generator that fails half way would otherwise
        # leave a truncated function that breaks completion for that command
        # until the next run.
        out="${comp_dir}/_${cmd}"
        # shellcheck disable=SC2086  # args is a deliberate word-split argv
        if "${cmd}" ${args} >"${out}.tmp" 2>/dev/null && [[ -s "${out}.tmp" ]]; then
            mv -f "${out}.tmp" "${out}"
            generated=$((generated + 1))
        else
            rm -f "${out}.tmp"
            log "Could not generate zsh completion for ${cmd}; skipping"
        fi
    done

    log "Generated ${generated} zsh completion function(s) in ${comp_dir}"

    # compinit caches the command-to-function map in the dump and rereads fpath
    # only when the dump is stale. Drop it so the next shell picks the new
    # functions up instead of waiting out the 24-hour timer in .zshrc.
    rm -f "${ZDOTDIR:-${HOME}}/.zcompdump" "${ZDOTDIR:-${HOME}}/.zcompdump.zwc"
}

# Both gh-stack steps hit the GitHub API — to resolve the extension's release
# and to read the skill's contents — so both need an authenticated gh. Nothing
# in these scripts runs `gh auth login`, and it cannot be automated, so on a
# freshly provisioned box the credential simply is not there yet. Skip with a
# warning rather than failing the run; the next install after the user has
# authenticated picks both up.
gh_authenticated() {
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

install_gh_stack() {
    if ! gh_authenticated; then
        log "gh is not authenticated; skipping gh-stack extension (run 'gh auth login', then re-run)"
        return
    fi
    # Match on the source repo rather than the extension name, so a same-named
    # extension from another owner is replaced rather than mistaken for this one.
    local extensions
    extensions="$(gh extension list 2>/dev/null)"
    if grep -q "github/gh-stack" <<<"${extensions}"; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "gh-stack extension already installed; skipping"
            return
        fi
        log "Upgrading gh-stack extension"
        retry_once gh extension upgrade gh-stack
        return
    fi
    log "Installing gh-stack extension"
    gh extension install github/gh-stack
}

install_gh_stack_skill() {
    if ! gh_authenticated; then
        log "gh is not authenticated; skipping gh-stack skill (run 'gh auth login', then re-run)"
        return
    fi
    # User scope, so the skill applies in every repo instead of only whichever
    # one the install happened to run from. It lands in ~/.claude/skills/gh-stack,
    # a directory chezmoi manages through skills/.keep alone, so it leaves the
    # skill itself untouched.
    local skills
    skills="$(gh skill list --agent claude-code --scope user --json skillName --jq '.[].skillName' 2>/dev/null)"
    if grep -qx "gh-stack" <<<"${skills}"; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "gh-stack skill already installed; skipping"
            return
        fi
        log "Upgrading gh-stack skill"
        retry_once gh skill update gh-stack --all
        return
    fi
    log "Installing gh-stack skill for Claude Code"
    gh skill install github/gh-stack gh-stack --agent claude-code --scope user --force
}

install_wezterm() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Linux" ]] && [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "WezTerm: no display session detected; skipping on headless Linux"
        return
    fi

    if command -v wezterm >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "WezTerm already installed; skipping"
            return
        fi
        log "Upgrading WezTerm"
        if [[ "${os_name}" == "Darwin" ]]; then
            # wezterm@nightly's cask upstream occasionally ships a broken source
            # glob; a failed upgrade reverts to the existing working install, so
            # treat it as best-effort rather than failing the whole run.
            if ! brew upgrade --cask wezterm@nightly; then
                log "WezTerm nightly upgrade failed (likely upstream cask bug); keeping existing install; skipping"
            fi
            # Either way: the reverted install has to run too.
            require_runs wezterm
            return
        fi
        # Linux: fall through to re-download latest
    else
        log "Installing WezTerm"
        if [[ "${os_name}" == "Darwin" ]]; then
            brew install --cask wezterm@nightly || return 1
            require_runs wezterm
            return
        fi
    fi

    # Linux binary download, tracking the rolling `nightly` tag rather than the
    # newest tagged release. WezTerm has cut no release since 20240203 (February
    # 2024), so `releases/latest` pinned Linux to a build two and a half years
    # behind the wezterm@nightly cask that macOS installs. The nightly tag name
    # never changes; its assets are rebuilt from the tip of main.
    local os_arch
    os_arch="$(uname -m)"
    if [[ "${os_arch}" != "x86_64" ]]; then
        # arm64 nightly debs are published but lag the x86_64 ones by months,
        # so there is nothing worth tracking on that architecture yet.
        log "WezTerm: no official binary for ${os_arch}; skipping"
        return
    fi
    local ubuntu_version version_id_line
    version_id_line="$(grep -m1 '^VERSION_ID=' /etc/os-release || true)"
    ubuntu_version="${version_id_line#VERSION_ID=}"
    ubuntu_version="${ubuntu_version//\"/}"
    # Nightly publishes 20.04, 22.04, 24.04 and 26.04 packages. Anything else
    # falls back to 22.04, which runs on newer Ubuntu.
    case "${ubuntu_version}" in
        20.04 | 22.04 | 24.04 | 26.04) ;;
        *) ubuntu_version="22.04" ;;
    esac
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
    # No "already at latest" check: the tag is fixed, so the installed version
    # string can never match it, and a nightly moves most days in any case. This
    # only runs when UPGRADE is set, since an existing install returns above.
    local deb="wezterm-nightly.Ubuntu${ubuntu_version}.deb"
    local wezterm_base="https://github.com/wezterm/wezterm/releases/download/nightly"
    download_verified "${wezterm_base}/${deb}" "${tmp_dir}/${deb}" \
        "${wezterm_base}/${deb}.sha256" || return 1
    sudo apt-get install -y "${tmp_dir}/${deb}" || return 1
    require_runs wezterm
}

# The thing advertised at obsidian.md/cli is not a separately installable
# binary: it ships inside the desktop app. On macOS the cask now links it onto
# PATH itself — a `binary` stanza pointing /opt/homebrew/bin/obsidian at
# Contents/MacOS/obsidian-cli, added upstream in March 2026 — so a cask install
# needs no further step. Everywhere else it is registered by a GUI toggle
# (Settings -> General -> Command line interface), which copies the binary to
# ~/.local/bin/obsidian on Linux or symlinks /usr/local/bin/obsidian on macOS.
# It also needs the app to be running — the first command launches it. So the
# most a script can do on those paths is install the app and point at the
# remaining manual step, which is also why this is optional rather than
# installed everywhere.
install_obsidian() {
    local os_name os_arch
    os_name="$(uname -s)"
    os_arch="$(uname -m)"

    if [[ "${os_name}" == "Darwin" ]]; then
        if brew list --cask obsidian >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Obsidian already installed; skipping"
                print_obsidian_macos_cli_note
                return
            fi
            # The cask sets `auto_updates true`, so this is a no-op unless
            # --greedy is passed. That is deliberate: Obsidian replaces its own
            # bundle, and a greedy upgrade only races the app's own updater.
            log "Upgrading Obsidian"
            brew upgrade --cask obsidian || true
            print_obsidian_macos_cli_note
            return
        fi

        # `brew list --cask` only sees what brew put there, so an Obsidian
        # installed by hand before these scripts existed reads as absent. Left
        # to fall through, the install below aborts on the existing bundle and
        # every later run repeats it, which is invisible from the outside
        # because a step runs left of `||`, disabling errexit, so the failure
        # never reaches the step report.
        if [[ -d "/Applications/Obsidian.app" ]]; then
            local installed cask_version
            installed="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
                /Applications/Obsidian.app/Contents/Info.plist 2>/dev/null || true)"
            cask_version="$(brew info --cask --json=v2 obsidian 2>/dev/null |
                jq -r '.casks[0].version' 2>/dev/null || true)"
            # --adopt takes over an existing artifact only when it is identical
            # to the cask's, so it is worth trying at a matching version and a
            # wasted download at any other. Compare first rather than let brew
            # pull ~150MB to discover the same thing.
            if [[ -n "${installed}" ]] && [[ "${installed}" == "${cask_version}" ]]; then
                log "Adopting the existing Obsidian ${installed} into brew"
                if brew install --cask --adopt obsidian; then
                    print_obsidian_macos_cli_note
                    return
                fi
            fi
            log "Obsidian ${installed:-(version unknown)} at /Applications was not installed by brew; leaving it alone"
            log "  to hand it over: rm -rf /Applications/Obsidian.app && brew install --cask obsidian"
            print_obsidian_cli_hint
            return
        fi

        log "Installing Obsidian"
        brew install --cask obsidian || return 1
        print_obsidian_macos_cli_note
        return
    fi

    # The CLI drives a running GUI app, so an Obsidian install on a machine with
    # no display buys nothing.
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "Obsidian: no display session detected; skipping on headless Linux"
        return
    fi

    local tag version
    version="$(obsidian_desktop_version)" || return 1
    tag="v${version}"

    case "${os_arch}" in
        x86_64 | amd64)
            if dpkg -s obsidian >/dev/null 2>&1; then
                local current
                current="$(dpkg-query -W -f='${Version}' obsidian 2>/dev/null || true)"
                if [[ -z "${UPGRADE:-}" ]]; then
                    log "Obsidian ${current} already installed; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                if [[ "${current}" == "${version}" ]]; then
                    log "Obsidian ${current} already at latest; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                log "Upgrading Obsidian to ${version}"
            else
                log "Installing Obsidian ${version}"
            fi
            local deb="obsidian_${version}_amd64.deb"
            local tmp_dir
            tmp_dir="$(mktemp -d)"
            trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
            download "https://github.com/obsidianmd/obsidian-releases/releases/download/${tag}/${deb}" \
                "${tmp_dir}/${deb}" || return 1
            sudo apt-get install -y "${tmp_dir}/${deb}" || return 1
            ;;
        aarch64 | arm64)
            # Upstream publishes no arm64 .deb, only a tarball, so unpack it
            # under ~/.local/share and link the launcher onto PATH by hand.
            local dest="${HOME}/.local/share/obsidian"
            local version_file="${dest}/.version"
            if [[ -f "${version_file}" ]]; then
                local current
                current="$(cat "${version_file}")"
                if [[ -z "${UPGRADE:-}" ]]; then
                    log "Obsidian ${current} already installed; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                if [[ "${current}" == "${version}" ]]; then
                    log "Obsidian ${current} already at latest; skipping"
                    print_obsidian_cli_hint
                    return
                fi
                log "Upgrading Obsidian to ${version}"
            else
                log "Installing Obsidian ${version}"
            fi
            local tarball="obsidian-${version}-arm64.tar.gz"
            local tmp_dir
            tmp_dir="$(mktemp -d)"
            trap 'rm -rf "${tmp_dir}"; trap - RETURN' RETURN
            download "https://github.com/obsidianmd/obsidian-releases/releases/download/${tag}/${tarball}" \
                "${tmp_dir}/${tarball}" || return 1
            tar -C "${tmp_dir}" -xf "${tmp_dir}/${tarball}" || return 1
            local unpacked="${tmp_dir}/obsidian-${version}-arm64"
            if [[ ! -x "${unpacked}/obsidian" ]]; then
                err "Obsidian: no 'obsidian' binary at ${unpacked}; upstream layout changed"
                return 1
            fi
            rm -rf "${dest}"
            mkdir -p "$(dirname "${dest}")"
            mv "${unpacked}" "${dest}" || return 1
            printf '%s\n' "${version}" >"${version_file}"
            # Electron refuses to start if its setuid sandbox helper is not
            # root-owned and mode 4755. The .deb arranges that; an unpacked
            # tarball cannot, so do it here. Best-effort: failing only costs the
            # sandbox, and saying so beats a bare "app won't launch".
            if [[ -e "${dest}/chrome-sandbox" ]]; then
                if ! sudo chown root:root "${dest}/chrome-sandbox" ||
                    ! sudo chmod 4755 "${dest}/chrome-sandbox"; then
                    log "Obsidian: could not setuid chrome-sandbox; skipping (launch with --no-sandbox if the app refuses to start)"
                fi
            fi
            mkdir -p "${HOME}/.local/bin"
            ln -sf "${dest}/obsidian" "${HOME}/.local/bin/obsidian-app" || return 1
            ;;
        *)
            log "Unsupported arch ${os_arch} for Obsidian install; skipping"
            return
            ;;
    esac

    print_obsidian_cli_hint
}

# The cask has already linked /opt/homebrew/bin/obsidian, so the GUI toggle the
# hint below describes is not needed here. The command still cannot do anything
# with the app closed — it exits with "unable to find Obsidian" — so say that
# much rather than nothing.
print_obsidian_macos_cli_note() {
    log "Obsidian CLI linked as 'obsidian'; it needs the app running to do anything"
}

print_obsidian_cli_hint() {
    log "Obsidian CLI needs a one-time manual step: open Obsidian, then"
    log "  Settings -> General -> enable 'Command line interface'"
    log "  and follow the prompt to register it (installs the 'obsidian' command)"
}

# Sharing Obsidian config across machines is really this clone plus its
# schedule: the vault is a git repository and `.obsidian/` lives inside it, so
# settings, hotkeys, appearance, snippets and community-plugin code all ride
# along with the notes. Only `.obsidian/workspace.json` is gitignored. Nothing
# here belongs in chezmoi — obsync commits whatever Obsidian writes every 15
# minutes, so a chezmoi-managed copy would fight it for the same files.
#
# Three pieces have to line up and none is discoverable from the app: the
# obsync checkout, a vault clone whose remote is named `personal`, and the
# periodic invocation. This step owns the first and the third. The vault clone
# stays manual, because its URL is a private self-hosted forge and this
# repository is public — see scripts/CLAUDE.md for the reasoning.
OBSYNC_DIR="${HOME}/projects/obsync"
OBSYNC_REPO="https://github.com/benmandrew/obsync.git"
OBSYNC_VAULT_DIR="${HOME}/projects/obsidian-vault"
OBSYNC_VAULT_REMOTE="personal"
OBSYNC_LOG="${HOME}/.local/share/obsync/cron.log"
OBSYNC_INTERVAL_MIN=15
OBSYNC_CRON_MARKER="# obsync: managed by dotfiles install"
OBSYNC_LAUNCHD_LABEL="com.benmandrew.obsync"

install_obsync() {
    # obsync itself is public, so it clones over https and needs no key.
    if [[ -d "${OBSYNC_DIR}/.git" ]]; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "obsync already cloned; skipping"
        else
            log "Upgrading obsync"
            ensure_user_owns "${OBSYNC_DIR}"
            safe_git "${OBSYNC_DIR}" fetch origin || return 1
            safe_git "${OBSYNC_DIR}" reset --hard origin/main || return 1
        fi
    else
        log "Cloning obsync"
        mkdir -p "$(dirname "${OBSYNC_DIR}")" || return 1
        git clone "${OBSYNC_REPO}" "${OBSYNC_DIR}" || return 1
    fi

    # No vault means nothing to schedule against, and obsync.sh exits 1 on a
    # missing directory — which the cron job would then alert about every 15
    # minutes.
    if ! ensure_obsidian_vault; then
        return 0
    fi

    mkdir -p "$(dirname "${OBSYNC_LOG}")"
    schedule_obsync
}

# Both conditions gate the schedule, since obsync fails on either and a cron
# job would report that failure every 15 minutes. Neither is repairable from
# here: cloning the vault and naming its remote both need the forge URL, which
# is deliberately not in this repository. So this detects and explains.
#
# The remote name is the one worth explaining. obsync.sh hardcodes
# PRIMARY_REMOTE=personal, so a vault cloned the usual way — which gets
# `origin` — fails at `rev-parse personal/main` on every run, and the EXIT trap
# reports it as a bare exit status with no indication of the cause.
ensure_obsidian_vault() {
    if [[ ! -d "${OBSYNC_VAULT_DIR}/.git" ]]; then
        log "obsync: no vault at ${OBSYNC_VAULT_DIR}; skipping schedule"
        log "  clone it there first, naming the remote '${OBSYNC_VAULT_REMOTE}':"
        log "    git clone -o ${OBSYNC_VAULT_REMOTE} <vault-url> ${OBSYNC_VAULT_DIR}"
        return 1
    fi

    local url
    url="$(safe_git "${OBSYNC_VAULT_DIR}" remote get-url "${OBSYNC_VAULT_REMOTE}" 2>/dev/null || true)"
    if [[ -z "${url}" ]]; then
        log "obsync: vault has no '${OBSYNC_VAULT_REMOTE}' remote; skipping schedule"
        log "  git -C ${OBSYNC_VAULT_DIR} remote add ${OBSYNC_VAULT_REMOTE} <vault-url>"
        return 1
    fi

    return 0
}

schedule_obsync() {
    local os_name
    os_name="$(uname -s)"
    case "${os_name}" in
        Darwin) schedule_obsync_launchd ;;
        *) schedule_obsync_cron ;;
    esac
}

# The crontab in $1 with every obsync line taken out. Matching on obsync.sh as
# well as the marker catches hand-written entries that predate it. Everything
# else is passed through.
obsync_cron_stripped() {
    printf '%s\n' "$1" | grep -vF "${OBSYNC_CRON_MARKER}" | grep -vF 'obsync.sh' || true
}

# Called from the launchd path as well as here, so a Mac that predates the
# LaunchAgent does not keep running the crontab entry beside it. obsync.sh has
# no lock file, and launchd's phase resets on every reboot, so the two
# schedules can land together mid-rebase.
remove_obsync_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    local existing kept
    existing="$(crontab -l 2>/dev/null || true)"
    kept="$(obsync_cron_stripped "${existing}")"
    if [[ "${kept}" == "${existing}" ]]; then
        return 0
    fi

    log "Removing obsync crontab entry"
    printf '%s\n' "${kept}" | crontab -
}

schedule_obsync_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        log "obsync: no crontab command; skipping schedule"
        return
    fi

    # The redirect merges stderr into the log. Without it obsync's failure
    # output goes to cron's local mail, which nothing on these machines reads.
    local line
    line="*/${OBSYNC_INTERVAL_MIN} * * * * cd ${OBSYNC_DIR} && /bin/bash obsync.sh ${OBSYNC_VAULT_DIR} >> ${OBSYNC_LOG} 2>&1"

    local existing
    existing="$(crontab -l 2>/dev/null || true)"
    if [[ "${existing}" == *"${line}"* ]]; then
        log "obsync cron entry already installed; skipping"
        return
    fi

    # Drop any earlier entry before appending, so re-running does not stack up
    # duplicate schedules.
    local kept
    kept="$(obsync_cron_stripped "${existing}")"

    # Assemble first, pipe second. Anything but printf on the left of
    # `crontab -` has its exit status masked by the pipeline, so a failure
    # there would install a truncated crontab instead of stopping.
    local payload="${OBSYNC_CRON_MARKER}"$'\n'"${line}"
    if [[ -n "${kept//[[:space:]]/}" ]]; then
        payload="${kept}"$'\n'"${payload}"
    fi

    log "Installing obsync cron entry (every ${OBSYNC_INTERVAL_MIN} minutes)"
    printf '%s\n' "${payload}" | crontab -
}

# macOS still has cron, but it runs under a sandbox that needs Full Disk Access
# granted to /usr/sbin/cron by hand, and inherits a PATH with no Homebrew on it,
# so git is absent. A LaunchAgent avoids both.
schedule_obsync_launchd() {
    local plist="${HOME}/Library/LaunchAgents/${OBSYNC_LAUNCHD_LABEL}.plist"
    local interval=$((OBSYNC_INTERVAL_MIN * 60))

    local domain desired
    domain="gui/$(id -u)"
    mkdir -p "$(dirname "${plist}")" || return 1
    desired="$(
        cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${OBSYNC_LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${OBSYNC_DIR}/obsync.sh</string>
        <string>${OBSYNC_VAULT_DIR}</string>
    </array>
    <key>WorkingDirectory</key><string>${OBSYNC_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key><integer>${interval}</integer>
    <key>StandardOutPath</key><string>${OBSYNC_LOG}</string>
    <key>StandardErrorPath</key><string>${OBSYNC_LOG}</string>
</dict>
</plist>
EOF
    )"
    if [[ -f "${plist}" && "$(<"${plist}")" == "${desired}" ]] &&
        launchctl print "${domain}/${OBSYNC_LAUNCHD_LABEL}" >/dev/null 2>&1; then
        log "obsync LaunchAgent already loaded and unchanged; skipping"
        remove_obsync_cron
        return
    fi
    log "Installing obsync LaunchAgent (every ${OBSYNC_INTERVAL_MIN} minutes)"
    printf '%s\n' "${desired}" >"${plist}" || return 1

    # bootout first so a changed plist is picked up; it fails when nothing is
    # loaded, which is the normal first-install case. launchd unloads
    # asynchronously, and a bootstrap straight after fails with I/O error 5
    # until it has, so bootstrap is retried for a few seconds.
    launchctl bootout "${domain}/${OBSYNC_LAUNCHD_LABEL}" >/dev/null 2>&1 || true
    local attempt
    for attempt in 1 2 3 4 5; do
        launchctl bootstrap "${domain}" "${plist}" 2>/dev/null && break
        if ((attempt == 5)); then
            err "launchctl bootstrap of ${plist} still failing after ${attempt} attempts"
            return 1
        fi
        sleep 1
    done

    # After the agent is loaded, not before: a machine whose bootstrap failed
    # keeps the crontab entry and stays scheduled by it.
    remove_obsync_cron
}

# Both halves run under the one `obsidian` opt-in. install_obsidian returns
# early on several paths — already installed, headless, unsupported arch — so
# the two are sequenced here rather than chained inside it, and a failure in
# one still lets the other run.
install_obsidian_stack() {
    local rc=0
    install_obsidian || rc=1
    install_obsync || rc=1
    return "${rc}"
}

# zathura is a keyboard-driven PDF viewer. The managed zathurarc wires up SyncTeX
# inverse search into VS Code, so the build has to have SyncTeX support: Debian's
# package does, but the macOS formula makes it an :optional dependency, hence
# --with-synctex.
#
# macOS has no zathura in homebrew-core, so this uses the community tap. That tap
# builds from source and ships each document backend as its own formula, so a
# bare `brew install zathura` renders nothing at all — the backend plugin is not
# a nicety. The plugin also has to be linked into place by hand: its formula
# installs the .dylib into its own keg, while zathura only scans
# $(brew --prefix zathura)/lib/zathura.
#
# poppler is the backend on both platforms. The tap recommends mupdf and mupdf is
# the faster renderer, but only in ratio: measured on a 6-page typst paper, a
# single-page re-render — which is all watch mode does — is 24.3ms under mupdf
# against 30.2ms under poppler, and typst's own compile of the same document is
# 92ms. A ~6ms edge is invisible next to that, and it costs 71MB of mupdf plus a
# second renderer's quirks to learn. poppler is already present on most machines
# and is what Debian ships, so one backend covers both platforms.
install_zathura() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        local taps
        taps="$(brew tap)"
        if ! grep -q "^homebrew-zathura/zathura$" <<<"${taps}"; then
            log "Tapping homebrew-zathura/zathura"
            brew tap homebrew-zathura/zathura
        fi
        # Homebrew 6 refuses to load formulae from an unofficial tap until it is
        # trusted. The refusal is a per-formula error rather than a failed tap,
        # so without this the step walks straight past it and "succeeds" having
        # built nothing. Answering yes to the optional-tool prompt is the opt-in;
        # re-asking per tap would make the install interactive again.
        local trusted_taps
        trusted_taps="$(brew trust --json v1)"
        if ! jq -e '.taps | index("homebrew-zathura/zathura")' <<<"${trusted_taps}" >/dev/null; then
            log "Trusting tap homebrew-zathura/zathura"
            brew trust --tap homebrew-zathura/zathura || return 1
        fi
        if brew list --formula zathura >/dev/null 2>&1; then
            if [[ -n "${UPGRADE:-}" ]]; then
                log "Upgrading zathura"
                # `brew upgrade` reuses the options a formula was installed with
                # and appends any given here, so --with-synctex also repairs a
                # build that predates it.
                brew upgrade zathura --with-synctex || return 1
            else
                log "zathura already installed; skipping"
            fi
        else
            log "Installing zathura"
            brew install zathura --with-synctex || return 1
        fi
        # Guarded separately from zathura itself: the two are distinct formulae,
        # and an interrupted first run can leave the viewer without a backend.
        if brew list --formula zathura-pdf-poppler >/dev/null 2>&1; then
            if [[ -n "${UPGRADE:-}" ]]; then
                log "Upgrading zathura-pdf-poppler"
                brew upgrade zathura-pdf-poppler || return 1
            fi
        else
            log "Installing zathura-pdf-poppler"
            brew install zathura-pdf-poppler || return 1
        fi
        # Deliberately not the last command in the function: the hint below
        # returns 0, so letting it run last would mask a link failure and report
        # a clean install that renders nothing.
        link_zathura_pdf_plugin || return 1
        require_runs zathura --version || return 1
        print_zathura_app_hint
        return 0
    fi

    # A GUI document viewer buys nothing on a machine with no display.
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log "zathura: no display session detected; skipping on headless Linux"
        return
    fi

    if command -v zathura >/dev/null 2>&1 && dpkg -s zathura-pdf-poppler >/dev/null 2>&1; then
        if [[ -z "${UPGRADE:-}" ]]; then
            log "zathura already installed; skipping"
            return
        fi
        log "Upgrading zathura"
    else
        log "Installing zathura"
    fi
    sudo apt-get install -y zathura zathura-pdf-poppler || return 1
    require_runs zathura --version
}

link_zathura_pdf_plugin() {
    local zathura_prefix plugin_prefix
    # `brew --prefix <formula>` answers with the opt path whether or not the
    # formula is installed, so check installation separately or a failed install
    # gets misreported as an upstream layout change.
    if ! brew list --formula zathura-pdf-poppler >/dev/null 2>&1; then
        err "zathura: zathura-pdf-poppler is not installed; cannot link the PDF backend"
        return 1
    fi
    zathura_prefix="$(brew --prefix zathura)"
    plugin_prefix="$(brew --prefix zathura-pdf-poppler)"
    if [[ ! -f "${plugin_prefix}/libpdf-poppler.dylib" ]]; then
        err "zathura: no libpdf-poppler.dylib under ${plugin_prefix}; upstream layout changed"
        return 1
    fi
    mkdir -p "${zathura_prefix}/lib/zathura"
    ln -sf "${plugin_prefix}/libpdf-poppler.dylib" \
        "${zathura_prefix}/lib/zathura/libpdf-poppler.dylib"
}

print_zathura_app_hint() {
    log "zathura on macOS is a command-line tool. To also get a /Applications bundle"
    log "  that opens PDFs on double-click, run the tap's convert-into-app.sh:"
    log "  https://github.com/homebrew-zathura/homebrew-zathura"
}

# TeX Live. Linux takes upstream TeX Live through install-tl, since apt pins
# it to the distro's release year: Ubuntu 22.04 ships TeX Live 2021 and biber
# 2.17, and a biber that lags biblatex refuses the .bcf files it writes. The
# collections match the apt packages this replaced (texlive-latex-extra,
# -fonts-extra, -fonts-recommended, -extra-utils, -bibtex-extra, -science)
# short of texlive-full's language packs; docs and sources are skipped.
# macOS takes MacTeX without its GUI apps: the full TeX Live scheme, which
# already carries latexmk and biber. BasicTeX is a tenth of the size but lacks
# most of what the Linux set pulls in, and tlmgr-installing the gap by hand
# would make the two platforms drift.
TEXLIVE_REPOSITORY="https://mirror.ctan.org/systems/texlive/tlnet"
TEXLIVE_ROOT="${HOME}/.local/texlive"
TEXLIVE_COLLECTIONS=(collection-basic collection-latex collection-latexrecommended
    collection-latexextra collection-fontsrecommended collection-fontsextra
    collection-binextra collection-bibtexextra collection-mathscience
    collection-pictures collection-plaingeneric collection-luatex)

# Written into a TEXDIR once install-tl has finished there. install-tl lays
# tlmgr down first, so a tlmgr alone does not mean the collections followed.
TEXLIVE_COMPLETE_MARKER=".dotfiles-complete"

# Whether install-tl finished in a TEXDIR. A tree from before the marker counts
# when its package database lists every collection, and gets the marker then.
texlive_complete() {
    local texdir="$1" collection
    [[ -f "${texdir}/${TEXLIVE_COMPLETE_MARKER}" ]] && return 0
    [[ -f "${texdir}/tlpkg/texlive.tlpdb" ]] || return 1
    for collection in "${TEXLIVE_COLLECTIONS[@]}"; do
        grep -qx "name ${collection}" "${texdir}/tlpkg/texlive.tlpdb" || return 1
    done
    : >"${texdir}/${TEXLIVE_COMPLETE_MARKER}"
}

# The newest complete year directory under TEXLIVE_ROOT; empty when none.
texlive_installed_year() {
    local dir bin_dir year=""
    for dir in "${TEXLIVE_ROOT}"/20[0-9][0-9]; do
        bin_dir="$(texlive_bin_dir "${dir}")" || continue
        if [[ -x "${bin_dir}/tlmgr" ]] && texlive_complete "${dir}"; then
            year="${dir##*/}"
        fi
    done
    printf '%s\n' "${year}"
}

# bin/<platform> of a TEXDIR. install-tl names the platform itself
# (x86_64-linux, aarch64-linux), so it is globbed rather than derived.
texlive_bin_dir() {
    local candidate
    for candidate in "$1"/bin/*; do
        if [[ -d "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return
        fi
    done
    return 1
}

# mirror.ctan.org redirects each request to a mirror of its choosing, so the
# tarball and its checksum fetched separately can come from two mirrors at
# different points in a sync; on 1 October 2026 they did, and disagreed. The
# redirect is resolved once here and every later request, install-tl's own
# included, goes to that mirror. Only headers are fetched, so this is the one
# request that bypasses download().
resolve_texlive_mirror() {
    local url
    url="$(curl -fsSLI --proto '=https' --tlsv1.2 "${_CURL_RETRY_OPTS[@]}" \
        -o /dev/null -w '%{url_effective}' "${TEXLIVE_REPOSITORY}/")" || {
        err "Could not resolve a CTAN mirror from ${TEXLIVE_REPOSITORY}"
        return 1
    }
    TEXLIVE_MIRROR="${url%/}"
}

# Fetch and unpack install-tl into $1, leaving its directory in
# TEXLIVE_INSTALLER and its release year in TEXLIVE_INSTALLER_YEAR. Upstream
# publishes a SHA-512 rather than a SHA-256, so the check is done here instead
# of through download_verified.
fetch_texlive_installer() {
    local work="$1" tarball="$1/install-tl-unx.tar.gz" expected actual
    resolve_texlive_mirror || return 1
    download "${TEXLIVE_MIRROR}/install-tl-unx.tar.gz" "${tarball}" || return 1
    download "${TEXLIVE_MIRROR}/install-tl-unx.tar.gz.sha512" "${tarball}.sha512" || return 1
    expected="$(awk '{ print $1; exit }' "${tarball}.sha512")"
    actual="$(sha512sum "${tarball}")" || return 1
    if [[ "${actual%% *}" != "${expected}" ]]; then
        err "Checksum mismatch for install-tl-unx.tar.gz from ${TEXLIVE_MIRROR}"
        return 1
    fi
    tar -xf "${tarball}" -C "${work}" || return 1
    # The tarball unpacks to install-tl-<date>.
    local dir release=""
    for dir in "${work}"/install-tl-*/; do
        TEXLIVE_INSTALLER="${dir%/}"
    done
    # release-texlive.txt opens with "TeX Live (https://tug.org/texlive) version 2026".
    read -r release <"${TEXLIVE_INSTALLER}/release-texlive.txt" || return 1
    TEXLIVE_INSTALLER_YEAR="${release##* }"
    if [[ ! "${TEXLIVE_INSTALLER_YEAR}" =~ ^20[0-9][0-9]$ ]]; then
        err "Could not read the TeX Live year from ${TEXLIVE_INSTALLER}/release-texlive.txt"
        return 1
    fi
}

# A per-user install, so tlmgr runs without sudo. instopt_adjustpath links
# every binary into ~/.local/bin, which .zshrc puts ahead of /usr/bin, so the
# year directory never appears on PATH and a new year only relinks: install-tl
# replaces an existing symlink and warns past a regular file. install-tl leaves
# tlmgr on the mirror it installed from (instopt_adjustrepo covers only a DVD
# install), so tlmgr is pointed back at mirror.ctan.org afterwards.
run_texlive_installer() {
    local installer="$1" texdir="$2" profile="$1/dotfiles.profile" collection
    {
        printf 'selected_scheme scheme-custom\n'
        printf 'TEXDIR %s\n' "${texdir}"
        printf 'TEXMFLOCAL %s\n' "${TEXLIVE_ROOT}/texmf-local"
        printf 'TEXMFSYSVAR %s\n' "${texdir}/texmf-var"
        printf 'TEXMFSYSCONFIG %s\n' "${texdir}/texmf-config"
        printf 'TEXMFHOME ~/texmf\n'
        for collection in "${TEXLIVE_COLLECTIONS[@]}"; do
            printf '%s 1\n' "${collection}"
        done
        printf 'instopt_adjustpath 1\n'
        printf 'instopt_letter 0\n'
        printf 'tlpdbopt_sys_bin %s\n' "${HOME}/.local/bin"
        printf 'tlpdbopt_sys_man %s\n' "${HOME}/.local/share/man"
        printf 'tlpdbopt_sys_info %s\n' "${HOME}/.local/share/info"
        printf 'tlpdbopt_install_docfiles 0\n'
        printf 'tlpdbopt_install_srcfiles 0\n'
        printf 'tlpdbopt_autobackup 0\n'
    } >"${profile}"
    mkdir -p "${HOME}/.local/bin" || return 1
    perl "${installer}/install-tl" --profile="${profile}" \
        --repository="${TEXLIVE_MIRROR}" || return 1
    local bin_dir
    bin_dir="$(texlive_bin_dir "${texdir}")" || return 1
    "${bin_dir}/tlmgr" option repository "${TEXLIVE_REPOSITORY}" || return 1
    : >"${texdir}/${TEXLIVE_COMPLETE_MARKER}"
}

# Links in ~/.local/bin left dangling by a removed TeX Live year.
remove_stale_texlive_links() {
    local link
    for link in "${HOME}/.local/bin"/*; do
        if [[ -L "${link}" && ! -e "${link}" ]]; then
            case "$(readlink "${link}")" in
                "${TEXLIVE_ROOT}"/*) rm -f "${link}" ;;
                *) ;;
            esac
        fi
    done
}

install_latex() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        # The pkg installer puts binaries in /Library/TeX/texbin and adds that
        # to PATH through /etc/paths.d/TeX, which a running shell has not read.
        local texbin="/Library/TeX/texbin"
        if brew list --cask mactex-no-gui >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "MacTeX already installed; skipping"
                return
            fi
            log "Upgrading MacTeX"
            brew upgrade --cask mactex-no-gui || return 1
        else
            log "Installing MacTeX (no GUI); this is a download of several gigabytes"
            brew install --cask mactex-no-gui || return 1
        fi
        require_runs "${texbin}/latexmk" -v || return 1
        require_runs "${texbin}/biber" --version
        return
    fi

    local installed bin_dir
    installed="$(texlive_installed_year)"
    if [[ -n "${installed}" && -z "${UPGRADE:-}" ]]; then
        log "TeX Live ${installed} already installed; skipping"
        return
    fi

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/install-tl.XXXXXX")" || return 1
    if ! fetch_texlive_installer "${work}"; then
        rm -rf "${work}"
        return 1
    fi

    if [[ -n "${installed}" ]] && ((TEXLIVE_INSTALLER_YEAR < installed)); then
        # A mirror lagging a release year behind would otherwise count as a
        # new year, install the older TeX Live and delete the newer one.
        rm -rf "${work}"
        log "TeX Live ${installed} is newer than the ${TEXLIVE_INSTALLER_YEAR} installer on ${TEXLIVE_MIRROR}; skipping"
        return
    fi
    if [[ "${installed}" == "${TEXLIVE_INSTALLER_YEAR}" ]]; then
        rm -rf "${work}"
        bin_dir="$(texlive_bin_dir "${TEXLIVE_ROOT}/${installed}")" || return 1
        log "Upgrading TeX Live ${installed} packages"
        retry_once "${bin_dir}/tlmgr" update --self --all || return 1
    else
        # tlmgr cannot cross a release year, so a new year is a fresh install
        # beside the old one, which goes only once the new one runs.
        # Whatever is there already is an interrupted install, since a
        # complete one would have counted as installed above.
        if [[ -d "${TEXLIVE_ROOT}/${TEXLIVE_INSTALLER_YEAR}" ]]; then
            log "Removing the incomplete TeX Live ${TEXLIVE_INSTALLER_YEAR} left by an earlier run"
            rm -rf "${TEXLIVE_ROOT:?}/${TEXLIVE_INSTALLER_YEAR}" || {
                rm -rf "${work}"
                return 1
            }
        fi
        log "Installing TeX Live ${TEXLIVE_INSTALLER_YEAR} into ${TEXLIVE_ROOT}; this is a download of several gigabytes"
        if ! run_texlive_installer "${TEXLIVE_INSTALLER}" "${TEXLIVE_ROOT}/${TEXLIVE_INSTALLER_YEAR}"; then
            rm -rf "${work}"
            return 1
        fi
        rm -rf "${work}"
        bin_dir="$(texlive_bin_dir "${TEXLIVE_ROOT}/${TEXLIVE_INSTALLER_YEAR}")" || return 1
    fi

    require_runs "${bin_dir}/latexmk" -v || return 1
    require_runs "${bin_dir}/biber" --version || return 1
    if [[ -n "${installed}" && "${installed}" != "${TEXLIVE_INSTALLER_YEAR}" ]]; then
        log "Removing TeX Live ${installed}"
        rm -rf "${TEXLIVE_ROOT:?}/${installed}" || return 1
        remove_stale_texlive_links
    fi
    note_shadowed latexmk "${HOME}/.local/bin/latexmk"
    if dpkg -s texlive-base >/dev/null 2>&1; then
        log "Note: the apt TeX Live is still installed, behind this one on PATH. To reclaim its space:"
        log "  sudo apt-get purge 'texlive*' latexmk biber && sudo apt-get autoremove"
    fi
}

# Docker's own repository rather than Ubuntu's docker.io, which lags upstream
# and ships no buildx or compose plugins. The layout matches Docker's install
# guide: an ASCII-armoured key in /etc/apt/keyrings/docker.asc and a deb822
# docker.sources, so a machine set up by hand from that guide is a no-op here.
DOCKER_APT_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# Docker's release signing key, as download.docker.com/linux/ubuntu/gpg serves
# it. Pinned because the key is fetched over TLS with nothing else to check it.
DOCKER_KEY_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# One field of /etc/os-release, unquoted; empty when absent.
_os_release_field() {
    awk -F= -v k="$1" '$1 == k { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null
}

install_docker() {
    local os_name
    os_name="$(uname -s)"

    if [[ "${os_name}" == "Darwin" ]]; then
        # Docker Desktop: macOS has no native container runtime, and the cask
        # links the docker CLI and compose plugin into /usr/local. The daemon
        # runs only once the app has been opened and its licence accepted,
        # which cannot be scripted, so only the client is probed.
        if brew list --cask docker-desktop >/dev/null 2>&1; then
            if [[ -z "${UPGRADE:-}" ]]; then
                log "Docker Desktop already installed; skipping"
                return
            fi
            log "Upgrading Docker Desktop"
            brew upgrade --cask docker-desktop || return 1
        else
            log "Installing Docker Desktop"
            brew install --cask docker-desktop || return 1
            log "Open Docker.app once to start the engine and accept its licence"
        fi
        require_runs /usr/local/bin/docker --version
        return
    fi

    local id ubuntu_codename codename
    id="$(_os_release_field ID)"
    ubuntu_codename="$(_os_release_field UBUNTU_CODENAME)"
    codename="$(_os_release_field VERSION_CODENAME)"
    # UBUNTU_CODENAME wins, so a derivative such as Mint resolves to the Ubuntu
    # suite Docker actually publishes.
    if [[ -n "${ubuntu_codename}" ]]; then
        id="ubuntu"
        codename="${ubuntu_codename}"
    elif [[ "${id}" != "debian" ]]; then
        log "Docker: no apt repository for ${id:-this distro}; skipping"
        return
    fi
    if [[ -z "${codename}" ]]; then
        log "Docker: no release codename in /etc/os-release; skipping"
        return
    fi

    local keyring="/etc/apt/keyrings/docker.asc"
    local sources="/etc/apt/sources.list.d/docker.sources"
    if [[ ! -f "${keyring}" ]]; then
        log "Adding Docker's apt signing key"
        local tmp key_info
        tmp="$(mktemp)"
        download "https://download.docker.com/linux/${id}/gpg" "${tmp}" || return 1
        key_info="$(gpg --show-keys --with-colons "${tmp}" 2>/dev/null)" || key_info=""
        if ! grep -qx "fpr:*${DOCKER_KEY_FINGERPRINT}:" <<<"${key_info}"; then
            rm -f "${tmp}"
            err "Docker's apt key does not carry the pinned fingerprint"
            return 1
        fi
        sudo mkdir -p -m 755 /etc/apt/keyrings || return 1
        sudo install -m 644 "${tmp}" "${keyring}" || return 1
        rm -f "${tmp}"
    fi
    if [[ ! -f "${sources}" ]]; then
        log "Adding Docker's apt repository"
        printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nSigned-By: %s\n' \
            "${id}" "${codename}" "${keyring}" |
            sudo tee "${sources}" >/dev/null || return 1
    fi

    local missing=() package
    for package in "${DOCKER_APT_PACKAGES[@]}"; do
        if ! dpkg -s "${package}" >/dev/null 2>&1; then
            missing+=("${package}")
        fi
    done
    if [[ -n "${UPGRADE:-}" ]]; then
        log "Upgrading Docker"
        sudo apt-get update || return 1
        sudo apt-get install -y "${DOCKER_APT_PACKAGES[@]}" || return 1
        require_runs docker --version || return 1
    elif ((${#missing[@]} > 0)); then
        log "Installing Docker packages: ${missing[*]}"
        sudo apt-get update || return 1
        sudo apt-get install -y "${missing[@]}" || return 1
        require_runs docker --version || return 1
    else
        log "Docker packages already installed; skipping"
    fi

    # The docker group grants root-equivalent access to the daemon's socket.
    # Opting into this step is the consent for that on this machine.
    local user groups
    user="$(id -un)" || return 1
    groups="$(id -nG "${user}")" || return 1
    if [[ " ${groups} " != *" docker "* ]]; then
        log "Adding ${user} to the docker group; log out and back in for it to apply"
        sudo usermod -aG docker "${user}" || return 1
    fi

    # Containers and WSL often run without systemd, where the unit cannot be
    # enabled and the daemon is started some other way.
    if [[ ! -d /run/systemd/system ]]; then
        log "Docker: systemd is not running; not enabling docker.service"
        return 0
    fi
    if ! systemctl is-enabled --quiet docker.service 2>/dev/null; then
        log "Enabling docker.service"
        sudo systemctl enable --now docker.service || return 1
    fi
}
