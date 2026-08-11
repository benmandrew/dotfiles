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
if [ -n "$session_id" ] && [ -d "$sessions" ]; then
	name="$(jq -r --arg id "$session_id" 'select(.sessionId == $id) | .name // empty' \
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

if [ -n "${WEZTERM_PANE:-}" ] && command -v wezterm >/dev/null 2>&1; then
	wezterm cli set-tab-title --pane-id "$WEZTERM_PANE" "🔔 $label"
fi
