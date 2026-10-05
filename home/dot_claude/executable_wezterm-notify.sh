#!/usr/bin/env bash
# Claude Code "Notification" hook (idle_prompt matcher): fires an OS notification
# and flags the WezTerm tab so it's visible even when unfocused, since Claude Code
# runs as one continuous foreground process and never triggers shell "command finished".
set -euo pipefail

input="$(cat)"
cwd="$(echo "$input" | jq -r '.cwd // empty')"
session_id="$(echo "$input" | jq -r '.session_id // empty')"

# Prefer the agent identifier claude registers for this session ("counter-fe"),
# matching what `gwt` lists and what the WezTerm tab already shows, so the
# notification names the agent rather than a directory several agents share.
# The session files are keyed by pid, so find ours by its recorded sessionId.
# A session registers under CLAUDE_CONFIG_DIR, so the work account — the
# `cc-work` alias points that at ~/.claude-work — has a session directory of its
# own, and this hook fires from both. Search every profile's; a pattern matching
# nothing is passed through literally and jq's complaint about it is discarded.
name=""
pid=""
if [ -n "$session_id" ]; then
    # The pid comes back alongside the name because it keys the tab flag below.
    IFS=$'\t' read -r pid name <<<"$(jq -r --arg id "$session_id" \
        'select(.sessionId == $id) | [(.pid | tostring), (.name // "")] | @tsv' \
        "${HOME}"/.claude*/sessions/*.json 2>/dev/null | head -n1 || true)"
fi

label="${name:-$(basename "${cwd:-$PWD}")}"

# The notification is the optional half of this hook. Over SSH there is no
# session bus and no GUI to post to, and under errexit a failure here would end
# the script before the tab flag below is written, which is the half that still
# works there. So each notifier's failure is swallowed.
case "$(uname -s)" in
    Darwin)
        osascript -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title "Claude Code"' \
            -e 'end run' \
            "$label" >/dev/null 2>&1 || true
        ;;
    Linux)
        # Every idle prompt of every agent fires this, and the kept copies piled
        # up in GNOME's notification list until it lagged when opened. The tab
        # flag below already records which session is waiting.
        #
        # Transient, so GNOME keeps no copy once the banner hides. That alone
        # leaks: GNOME 42 queues at most three banners, and a notification
        # arriving past that goes straight to the list with no banner to hide,
        # so it stays. Each one therefore replaces the last by its id, keeping
        # one entry at most. notify-send 0.7.9 has no --replace-id, hence gdbus.
        #
        # No DBUS_SESSION_BUS_ADDRESS means an SSH login or similar, where gdbus
        # could only fail. The id is captured before the file is written, so a
        # failed call leaves the last good id in place rather than truncating it.
        # Bare /tmp is shared between users, so the uid goes in the name there, as
        # claude-pane-session does.
        if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gdbus >/dev/null 2>&1; then
            if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
                id_file="${XDG_RUNTIME_DIR%/}/claude-notify-id"
            else
                id_file="/tmp/claude-notify-id.$(id -u)"
            fi
            (
                flock 9 || exit 0
                last="$(cat "$id_file" 2>/dev/null || true)"
                reply="$(gdbus call --session \
                    --dest org.freedesktop.Notifications \
                    --object-path /org/freedesktop/Notifications \
                    --method org.freedesktop.Notifications.Notify \
                    "Claude Code" "uint32 ${last:-0}" "" "Claude Code" "$label" \
                    "[]" "{'transient': <true>}" "int32 -1" 2>/dev/null)" || exit 0
                id="$(printf '%s\n' "$reply" | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')"
                if [ -n "$id" ]; then printf '%s\n' "$id" >"$id_file"; fi
            ) 9>"${id_file}.lock" || true
        fi
        ;;
esac

# Flag the tab so the notification is visible on an unfocused one. WezTerm
# colours the tab's status bar from this and drops the flag when the tab is next
# viewed. A flag file rather than `wezterm cli set-tab-title`, which wrote the
# state into the title string and so overwrote whatever the tab was called --
# the task word, the agent identifier or a manual rename.
bells="${HOME}/.claude/tab-bells"
if [ -n "$pid" ]; then
    mkdir -p "$bells"
    # Drop flags whose session has exited, as claude-tab-title does for titles.
    for stale in "$bells"/*; do
        [ -f "$stale" ] || continue
        live=""
        for session in "${HOME}"/.claude*/sessions/"${stale##*/}".json; do
            if [ -f "$session" ]; then live=1; fi
        done
        [ -n "$live" ] || rm -f "$stale"
    done
    # Inside tmux, a window already on screen in a focused client gets no flag.
    # tmux clears flags from its focus and window-change hooks, and neither fires
    # for the window being looked at, so the flag would stay until the user left
    # it and came back. focus-events keeps tmux's "focused" client flag current.
    in_view=""
    if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        where="$(tmux display -p -t "$TMUX_PANE" '#{window_active} #{session_name}' 2>/dev/null || true)"
        if [ "${where%% *}" = 1 ]; then
            flags="$(tmux list-clients -t "${where#* }" -F '#{client_flags}' 2>/dev/null || true)"
            case "$flags" in *focused*) in_view=1 ;; esac
        fi
    fi
    [ -n "$in_view" ] || : >"$bells/$pid"
fi
