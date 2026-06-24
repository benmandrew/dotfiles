#!/bin/sh
# Local clipboard integration for tmux copy-pipe.
# tmux set-clipboard=on handles OSC 52 (works over SSH); this script handles
# native tools for local Wayland/X11 sessions so clipboard managers also see the copy.
buf=$(cat)
if command -v wl-copy >/dev/null 2>&1 && [ -n "$WAYLAND_DISPLAY" ]; then
    printf '%s' "$buf" | wl-copy
elif command -v xclip >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
    printf '%s' "$buf" | xclip -selection clipboard
fi
