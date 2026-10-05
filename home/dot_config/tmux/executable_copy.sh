#!/bin/sh
# Clipboard integration for tmux's pipe-and-cancel.
#
# tmux set-clipboard=on handles OSC 52, which is what carries a copy back over
# SSH; this script handles the native tools for local Wayland/X11 and macOS
# sessions, so clipboard managers see the copy too. It is the pipe target
# on both platforms now, the only difference between them being which tool is
# on PATH, so dot_tmux.conf.tmpl no longer branches on the operating system.
#
# The selection goes through unbox on the way. Claude Code, gh and glow all
# render a markdown table as box drawing, so a selection copies the picture
# rather than the source, and pasting it into a .md file gives a block no
# renderer reads as a table. Text that is not a table comes back byte for
# byte, a `tree` listing and a diagram drawn in the same characters included.
unbox=$HOME/.local/bin/unbox
if [ -x "$unbox" ]; then
    buf=$("$unbox")
else
    # A machine part way through provisioning still copies.
    buf=$(cat)
fi

if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$buf" | pbcopy
elif command -v wl-copy >/dev/null 2>&1 && [ -n "$WAYLAND_DISPLAY" ]; then
    printf '%s' "$buf" | wl-copy
elif command -v xclip >/dev/null 2>&1 && [ -n "$DISPLAY" ]; then
    printf '%s' "$buf" | xclip -selection clipboard
fi

# This is the only write to tmux's buffers: dot_tmux.conf.tmpl binds
# pipe-and-cancel, which unlike copy-pipe sets no buffer of the raw selection.
# load-buffer -w sets one from the converted text and, with set-clipboard on,
# sends it to the outer terminal over OSC 52, so a session reached over SSH,
# where none of the tools above exist, still gets the copy. Writing the escape
# sequence directly is not available here: tmux runs the pipe command with no
# controlling terminal, so there is no /dev/tty to write it to.
printf '%s' "$buf" | tmux load-buffer -w - 2>/dev/null
