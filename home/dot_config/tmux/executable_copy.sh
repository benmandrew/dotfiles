#!/bin/sh
# Clipboard copy helper for tmux copy-pipe.
# Uses wl-copy/xclip when a local display is available (direct session),
# otherwise uses OSC 52 which travels through SSH to the local terminal emulator.
buf=$(cat)
if command -v wl-copy >/dev/null 2>&1 && [ -n "$WAYLAND_DISPLAY" ]; then
    printf '%s' "$buf" | wl-copy
elif command -v xclip >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
    printf '%s' "$buf" | xclip -selection clipboard
else
    printf '\033]52;c;%s\a' "$(printf '%s' "$buf" | base64 | tr -d '\n')" > /dev/tty
fi
