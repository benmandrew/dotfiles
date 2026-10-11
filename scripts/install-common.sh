#!/bin/bash

# The install steps that are still bash, and the helpers they share. Nothing
# here runs a step: scripts/installer does, calling one function per process
# through legacy-step.sh. PLAN.md has the order they are being ported in.

# Set by the runner, which parses the arguments. No step left here reads it,
# and test_legacy.py checks that it still arrives.
# shellcheck disable=SC2034
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
