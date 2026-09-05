#!/bin/bash

set -euo pipefail

# Warn when a login shell cannot find a bash new enough for nix-direnv.
#
# The check exists because the thing it guards lives outside this repo. The
# macOS nix installer appends its PATH block to /etc/zshrc, which is root-owned
# and replaced wholesale by a macOS update: this machine's came back
# byte-identical to the /etc/zshrc.backup-before-nix left beside it, so nothing
# put ~/.nix-profile/bin on PATH any more. That directory holds the bash 5.x
# `install_modern_bash` puts there, macOS shipping 3.2.57 as /bin/bash, and
# nix-direnv's `use flake` refuses to run under anything older than 4.4 — so
# every .envrc in a flake repository stopped loading, with nothing in the repo
# changed to explain it.
#
# home/dot_zprofile.tmpl now asserts that PATH entry from a file chezmoi owns,
# which is the actual fix. This is the tripwire for the next thing to break the
# same way, and it runs after every apply rather than on a content hash, since
# the change it watches for happens in /etc where no hash of this tree can see
# it.
#
# scripts/verify-install.sh carries the same probe. Deliberately duplicated:
# that script lives in the chezmoi source directory, which a target machine is
# not required to have, and this one has to work from ~ alone.
#
# Warns rather than fails. A non-zero exit here would make `chezmoi apply`
# report an error for something no apply can fix.

# No nix, no nix-direnv, nothing to check. Read the profile scripts off disk
# rather than asking for `nix` on PATH, since PATH is the thing under suspicion.
if [[ ! -r /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]] &&
    [[ ! -r "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]]; then
    exit 0
fi

if ! command -v zsh >/dev/null 2>&1; then
    exit 0
fi

# The environment is cleared because nix-daemon.sh exports
# __ETC_PROFILE_NIX_SOURCED and returns early when it is already set:
# inheriting it would leave the profile directory wherever the caller happened
# to have it, and the answer would describe chezmoi's parent shell instead of
# the machine. `zsh -lc` reads .zshenv, .zprofile and .zlogin and skips .zshrc,
# so nothing interactive writes to the stdout being read here. That understates
# the real PATH by whatever .zshrc prepends, which can only move bash earlier,
# so a pass here is a pass in the interactive shell direnv runs from.
login_path=""
# shellcheck disable=SC2016 # $PATH is the inner shell's to expand
login_path="$(env -i "HOME=${HOME}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    zsh -lc 'printf "%s" "$PATH"' 2>/dev/null)" || true

bash_path=""
bash_path="$(PATH="${login_path:-${PATH}}" command -v bash 2>/dev/null)" || true

version=""
# shellcheck disable=SC2016 # BASH_VERSINFO belongs to the bash being probed
version="$("${bash_path:-/nonexistent}" \
    -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null)" || true

major="${version%%.*}"
minor="${version##*.}"
if [[ -n "${version}" ]] && ((major > 4 || (major == 4 && minor >= 4))); then
    exit 0
fi

printf "\033[1;33m[warn]\033[0m login shell resolves bash to %s (%s)\n" \
    "${bash_path:-none}" "${version:-unknown version}" >&2
printf "       nix-direnv needs 4.4 or newer, so every flake .envrc will fail to load.\n" >&2
printf "       ~/.nix-profile/bin is missing from the login PATH. Check that ~/.zprofile\n" >&2
printf "       still carries its Nix block, then run: chezmoi apply ~/.zprofile\n" >&2
exit 0
