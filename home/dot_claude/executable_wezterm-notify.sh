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
sessions="${HOME}/.claude/sessions"
name=""
pid=""
if [ -n "$session_id" ] && [ -d "$sessions" ]; then
	# The pid comes back alongside the name because it keys the tab flag below.
	IFS=$'\t' read -r pid name <<<"$(jq -r --arg id "$session_id" \
		'select(.sessionId == $id) | [(.pid | tostring), (.name // "")] | @tsv' \
		"$sessions"/*.json 2>/dev/null | head -n1 || true)"
fi

label="${name:-$(basename "${cwd:-$PWD}")}"

case "$(uname -s)" in
Darwin)
	osascript -e 'on run argv' \
		-e 'display notification (item 1 of argv) with title "Claude Code"' \
		-e 'end run' \
		"$label"
	;;
Linux)
	if command -v notify-send >/dev/null 2>&1; then
		notify-send "Claude Code" "$label"
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
		[ -f "$sessions/${stale##*/}.json" ] || rm -f "$stale"
	done
	: >"$bells/$pid"
fi
