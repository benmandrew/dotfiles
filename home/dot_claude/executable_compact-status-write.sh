#!/usr/bin/env bash
# Claude Code "PostCompact" hook: keeps the summary that compaction just wrote,
# so a later /clear can be resumed from it instead of starting blind. The summary
# is generated and billed as part of the compaction either way, which is what
# makes this the cheap way to carry state across a session boundary — the
# alternative, having the model maintain a status file by hand, spends output
# tokens on every update.
set -euo pipefail

input="$(cat)"
summary="$(jq -r '.compact_summary // empty' <<<"$input")"
cwd="$(jq -r '.cwd // empty' <<<"$input")"

# A compaction that produced no summary, or a payload shape this script does not
# recognise. Exit clean rather than non-zero: a hook failure here would be
# reported against a compaction that otherwise worked.
[ -n "$summary" ] || exit 0

# Kept under ~/.claude and keyed on the working directory, rather than written
# into the project. A file in the repository would show up untracked in every
# `git status`, and `make lint-secrets` would then scan a summary that can quote
# a secret straight out of the transcript.
dir="${HOME}/.claude/compact-status"
mkdir -p "$dir"
slug="$(printf '%s' "${cwd:-$PWD}" | tr '/.' '-')"

# Written through a temporary file in the same directory and moved into place, so
# a session reading it while another compacts sees the old summary or the new
# one, never half of either.
tmp="$(mktemp "$dir/.${slug}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
    printf '<!-- %s, cwd %s -->\n\n' "$now" "${cwd:-$PWD}"
    printf '%s\n' "$summary"
} >"$tmp"
mv -f "$tmp" "$dir/${slug}.md"
