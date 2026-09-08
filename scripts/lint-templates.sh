#!/usr/bin/env bash
set -euo pipefail

# Render every chezmoi template, then lint each rendering with the real linter
# for the language it produces.
#
# This runs beside the strip pass in `make lint-zsh` rather than replacing it,
# because the two read different things. The strip pass deletes `{{ ... }}`
# with sed, which leaves both arms of an `{{ if eq .chezmoi.os "darwin" }}`
# concatenated into a file no shell would accept, so shellcheck can only run
# there at --severity=error without drowning in damage the strip itself did.
# A rendering is real shell and takes --enable all, shfmt, and for the zsh
# files a `zsh -n` parse that shellcheck cannot do at all. What a rendering
# cannot see is the arm not taken: eight of these templates branch on
# .chezmoi.os or .chezmoi.arch, and CI is Linux only, so the darwin side of
# each would go unread if the strip pass were dropped.
#
# --source is not optional. Without it chezmoi resolves the source directory
# from the destination, which on a CI runner is not this checkout, and
# home/.chezmoidata.yaml is then never read: dot_zshrc.tmpl renders with its
# whole ATUIN_HOST_NAME block missing, exits 0, and the check passes having
# read a file that is not the one being shipped.

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

out_dir="$(mktemp -d)"
# shellcheck disable=SC2064  # expand out_dir now, not when the trap fires
trap "rm -rf '${out_dir}'" EXIT INT TERM

status=0

# What each template renders to. Anything unnamed is still rendered, and the
# render exiting non-zero is the whole check for it — which is all a zathurarc
# or a tmux.conf can be given. `tmux -f` is not a validator: it exits 0 on an
# option it does not recognise and on an unterminated string alike, reporting
# neither to its exit status.
classify() {
    case "$1" in
        home/dot_zshrc.tmpl | home/dot_zprofile.tmpl | home/dot_zshenv.tmpl | home/dot_fzf.zsh.tmpl)
            printf 'zsh'
            ;;
        home/run_*.sh.tmpl) printf 'bash' ;;
        # The modify_ one-liners render to the same script as the fragment they
        # include, so linting both is redundant today. They are linted anyway,
        # since the redundancy holds only while the one-liner stays a bare
        # includeTemplate and nothing enforces that.
        *-modify.sh.tmpl | */modify_*.json.tmpl) printf 'sh' ;;
        *.json.tmpl) printf 'json' ;;
        home/dot_gitconfig.tmpl) printf 'gitconfig' ;;
        home/private_dot_ssh/private_config.tmpl) printf 'ssh' ;;
        *) printf 'none' ;;
    esac
}

seen=0
zsh_files=()
bash_files=()
sh_files=()
json_files=()
gitconfig_files=()
ssh_files=()

# NUL-separated: "home/Library/Application Support/..." carries a space, and a
# word-split loop silently renders two paths that do not exist and reports
# both as failures.
#
# shellcheck disable=SC2312  # the pipeline into the process substitution masks
# find's status, and a find that failed would run this loop zero times and
# report clean. The seen count below is what actually covers that, since it
# fails on an empty list however the list came to be empty.
while IFS= read -r -d '' template; do
    rendered="${out_dir}/$(printf '%s' "${template}" | tr '/ ' '__')"
    if ! chezmoi --source . execute-template <"${template}" >"${rendered}" 2>"${rendered}.err"; then
        printf 'render failed: %s\n' "${template}" >&2
        sed 's/^/    /' "${rendered}.err" >&2
        status=1
        continue
    fi
    rm -f "${rendered}.err"

    seen=$((seen + 1))
    dialect="$(classify "${template}")"
    case "${dialect}" in
        zsh) zsh_files+=("${rendered}") ;;
        bash) bash_files+=("${rendered}") ;;
        sh) sh_files+=("${rendered}") ;;
        json) json_files+=("${rendered}") ;;
        gitconfig) gitconfig_files+=("${rendered}") ;;
        ssh) ssh_files+=("${rendered}") ;;
        *) ;;
    esac
done < <(find home -name '*.tmpl' -print0 | sort -z)

if ((seen == 0)); then
    printf 'no templates found under home/ — expected at least one\n' >&2
    exit 1
fi

# Every rendering below assumes its input rendered. Bail rather than lint a
# partial set and report the survivors as a pass.
if ((status != 0)); then
    exit "${status}"
fi

# The three style-only exclusions the Makefile applies to the deployed
# scripts. A run_*.sh.tmpl renders to a chezmoi run_ script, which is the same
# class of file as the run_*.sh the Makefile already excludes them for, so
# holding the templated half to a stricter standard than its siblings would be
# arbitrary. Everything that finds a bug still applies in full, which is how
# SC2310 and SC2312 came to be answered in the templates rather than here.
#
# shfmt reads a rendering the same way it reads a script, but a diff it finds
# cannot be written back: the fix belongs in the template, by hand. So -d
# only, never -w, and no counterpart in `make fmt`.
# Repeated flags rather than one comma-separated argument: shellcheck reads
# both, and the comma form is an unquoted comma inside an array literal,
# which is what SC2054 exists to catch.
deployed_exclude=(--exclude SC2250 --exclude SC2249 --exclude SC2292)

if ((${#bash_files[@]} > 0)); then
    shellcheck --external-sources --shell bash --enable all \
        "${deployed_exclude[@]}" "${bash_files[@]}" || status=1
    shfmt -ln bash -i 4 -ci -d "${bash_files[@]}" || status=1
fi

if ((${#sh_files[@]} > 0)); then
    shellcheck --external-sources --shell sh --enable all \
        "${deployed_exclude[@]}" "${sh_files[@]}" || status=1
    shfmt -ln posix -i 4 -ci -d "${sh_files[@]}" || status=1
fi

# zsh's own parser, which is the only thing that reads zsh. shellcheck has no
# zsh mode and the strip pass has to lie to it with --shell=bash; -n parses
# without running a line of it.
for rendered in "${zsh_files[@]}"; do
    zsh -n "${rendered}" || status=1
done

for rendered in "${json_files[@]}"; do
    jq -e . "${rendered}" >/dev/null || status=1
done

# git parses the rendered gitconfig. It is the only reader that agrees with
# git about what a section header is, which is the mistake this repository has
# already made once: core.pager sat under [diff "prose"] and was read as
# diff.prose.pager, silently, for as long as it took to notice delta was never
# running.
for rendered in "${gitconfig_files[@]}"; do
    git config --file "${rendered}" --list >/dev/null || status=1
done

for rendered in "${ssh_files[@]}"; do
    sshconfig-lint --config "${rendered}" || status=1
done

exit "${status}"
