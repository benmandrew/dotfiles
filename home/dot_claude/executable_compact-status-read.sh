#!/usr/bin/env bash
# Claude Code "SessionStart" hook (clear matcher): feeds the last compaction
# summary back in after a /clear. That is what makes /clear the economical move
# once the prompt cache has gone cold — a cold /compact re-reads the whole
# transcript at full price to produce a summary, where this one was written for
# free by the compaction that already ran while the cache was warm.
#
# Bound to the clear matcher alone. On startup the working directory says nothing
# about whether the last session's work is being continued, and on resume the
# real transcript is already there.
set -euo pipefail

input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$input")"

# The same per-profile directory the write hook uses.
dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/compact-status"
slug="$(printf '%s' "${cwd:-$PWD}" | tr '/.' '-')"
file="$dir/${slug}.md"

[ -s "$file" ] || exit 0

# A summary older than this describes work that has almost certainly moved on,
# and injecting it would spend context on stale state. -mmin is in both GNU and
# BSD find, and -maxdepth 0 names the file itself, so the slug is never read as a
# glob.
max_age_minutes=720
fresh="$(find "$file" -maxdepth 0 -mmin "-${max_age_minutes}" 2>/dev/null)"
[ -n "$fresh" ] || exit 0

# A summary is injected once. Left in place, it came back on every /clear for
# the next 12 hours, including the /clear meant to start clean, and in every
# other session in the same directory. Moving it aside claims it: when two
# sessions clear at once, only the one whose mv succeeds injects it. The .used
# copy stays for reading by hand, and the next compaction writes a fresh .md.
used="${file}.used"
mv -f "$file" "$used" 2>/dev/null || exit 0

# additionalContext is the documented channel for a SessionStart hook to put text
# in front of the model; anything this script prints on stdout outside this JSON
# would be shown to the user instead.
jq -nc --rawfile summary "$used" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ("Summary of the work in this directory, carried over from the last compaction before the session was cleared:\n\n" + $summary)
    }
}'
