#!/usr/bin/env bash
# Redraw the tmux status line as soon as a claude session changes state, so a
# window's busy/idle bar follows the session without waiting out status-interval.
#
# Run as the UserPromptSubmit and Stop hooks, with the hook's JSON on stdin, and
# by idle-notify.sh and claude-tab-title once they have written a bell or a
# title, with nothing on stdin. Claude writes "busy" to its session file before
# UserPromptSubmit fires, but writes "idle" about 30 ms after Stop fires (timed
# against a scratch session), so after Stop this waits for the file to stop
# saying busy, up to a second.
#
# Everything after reading stdin runs detached, since claude does not submit the
# prompt until UserPromptSubmit returns.
set -u

[ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null || true)"

(
    if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
        fields="$(jq -r '[(.hook_event_name // ""), (.session_id // "")] | @tsv' \
            <<<"$input" 2>/dev/null || true)"
        IFS=$'\t' read -r event session_id <<<"$fields"
        if [ "${event:-}" = Stop ] && [ -n "${session_id:-}" ]; then
            file="$(grep -l -F "\"sessionId\":\"$session_id\"" "${HOME}"/.claude*/sessions/*.json 2>/dev/null | head -n1 || true)"
            if [ -n "$file" ]; then
                for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
                    grep -q -F '"status":"busy"' "$file" 2>/dev/null || break
                    sleep 0.05
                done
            fi
        fi
    fi
    # The window chips read the cache status-left rebuilds, and tmux starts all
    # of a redraw's #() jobs at once, so a chip would race status-left's rebuild
    # and could read the old state. Rebuild it here first.
    ~/.local/bin/claude-pane-session refresh
    # -S forces every #() job to run again. A bare refresh-client redraws only
    # one client, and each attached client has a status line of its own.
    clients="$(tmux list-clients -F '#{client_name}' 2>/dev/null || true)"
    while read -r client; do
        [ -z "$client" ] || tmux refresh-client -S -t "$client" 2>/dev/null
    done <<<"$clients"
) </dev/null >/dev/null 2>&1 &

exit 0
