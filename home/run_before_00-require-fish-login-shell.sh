#!/bin/bash

set -euo pipefail

# Stop `chezmoi apply` before it changes any file when the login shell is not
# fish.
#
# The tree carries no zsh config, so a machine still logging in to zsh would
# open every new terminal in a bare zsh with no Nix or Homebrew on PATH. Only
# scripts/install.sh installs fish and runs chsh; an apply does neither. chezmoi
# runs run_before_ scripts ahead of every file change, .chezmoiremove included,
# and stops when one fails, so a stale machine keeps its old files until the
# installer has run.
#
# Reads the shell from the account database, as install_login_shell does, since
# $SHELL stays stale after chsh until the next login.

user="$(id -un)"
os="$(uname)"
if [[ "${os}" == "Darwin" ]]; then
    shell="$(dscl . -read "/Users/${user}" UserShell 2>/dev/null)" || true
    shell="${shell#UserShell: }"
else
    shell="$(getent passwd "${user}" 2>/dev/null)" || true
    shell="${shell##*:}"
fi

if [[ "${shell##*/}" == "fish" ]]; then
    exit 0
fi

# install_login_shell skips an account held outside /etc/passwd, such as one in
# LDAP or SSSD, since chsh cannot change it. Blocking here would block every
# apply on that machine for good.
if [[ "${os}" != "Darwin" ]] && ! grep -q "^${user}:" /etc/passwd 2>/dev/null; then
    exit 0
fi

# An account database that will not answer says nothing either way.
if [[ -z "${shell}" ]]; then
    printf "\033[1;33m[warn]\033[0m could not read the login shell for %s; applying anyway\n" "${user}" >&2
    exit 0
fi

installer="${CHEZMOI_WORKING_TREE:-${HOME}/.local/share/chezmoi}/scripts/install.sh"
printf "\033[1;31m[error]\033[0m the login shell is %s, and this config supports only fish.\n" "${shell}" >&2
printf "        Nothing has been changed. Run %s,\n" "${installer}" >&2
printf "        log out and in again, restart tmux (tmux kill-server), then run: chezmoi apply\n" >&2
exit 1
