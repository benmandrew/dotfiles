#!/usr/bin/env bash
# Claude Code "Notification" hook (idle_prompt matcher): fires an OS notification
# and flags the WezTerm tab so it's visible even when unfocused, since Claude Code
# runs as one continuous foreground process and never triggers shell "command finished".
set -euo pipefail

input="$(cat)"
cwd="$(echo "$input" | jq -r '.cwd // empty')"
label="$(basename "${cwd:-$PWD}")"

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
