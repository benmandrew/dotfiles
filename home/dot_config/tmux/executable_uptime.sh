#!/bin/sh
# Print how long the machine has been up, for the tmux status bar:
#
#     15 days 1:58
#
# `uptime` pads its columns and follows the uptime with the user count and the
# load averages, so keep the text between "up" and the first comma, then
# squeeze the padding down to single spaces.
uptime | sed 's/.*up  *//; s/,.*//; s/  */ /g; s/^ //; s/ $//'
