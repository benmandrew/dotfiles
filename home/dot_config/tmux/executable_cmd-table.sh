#!/bin/sh
# Builds tmux's cmd key table from its prefix table. See "Command mode" in
# ~/.tmux.conf.
#
# Every prefix binding is copied into cmd, so tmux's defaults and the plugins'
# keys work in command mode without a second definition. A key named as an
# argument, or a repeat (-r) binding, first switches back into cmd and restarts
# the mode's timer (@cmd-arm in ~/.tmux.conf), so the mode stays even when the
# command fails, which ends the rest of its list. Any other
# key runs once and leaves the client in root, where tmux puts it before running
# a binding. The -r flag itself is dropped: a repeat binding returns the client
# to root when repeat-time runs out.
#
# A one-shot key ends with refresh-client, since tmux repaints only the status
# line on a table change, and the pane borders show the mode.
#
# The commands are joined with \; as list-keys joins them. Inside braces \; is a
# literal argument, which breaks a binding such as N's swap-window and
# select-window, and one parse error rejects the whole table.
set -eu

tmux list-keys -T prefix | awk -v sticky=" $* " '
$1 == "bind-key" {
    repeat = ($2 == "-r")
    t = repeat ? 3 : 2
    if ($t != "-T" || $(t + 1) != "prefix") next
    key = $(t + 2)
    # The command is the rest of the line, with its own spacing kept.
    command = $0
    for (n = 0; n < t + 2; n++) sub(/^ *[^ ]+ +/, "", command)
    if (repeat || index(sticky, " " key " "))
        printf "bind-key -T cmd %s switch-client -T cmd \\; run -C \"#{@cmd-arm}\" \\; %s\n", key, command
    else
        printf "bind-key -T cmd %s %s \\; refresh-client\n", key, command
}' | tmux source-file -
