#!/bin/sh
# The whole of the tmux status-right metrics block — CPU percentage, RAM
# used/total and uptime — as one preformatted string.
#
# One script rather than three because tmux forks a shell per #() job and cannot
# split one job's output across fields, so the Nerd Font glyphs and the
# two-space gaps that used to sit in status-right live here instead. The layout
# is byte-for-byte what the three scripts and that format string produced.
#
# The platform branch is a `[ -r /proc/stat ]` test rather than a `uname` fork or
# a chezmoi template: the test is a shell builtin so the branch costs nothing at
# runtime, and the file stays a plain .sh that shellcheck and the Makefile's
# lint-sh glob read directly, which a .tmpl would not be.
set -u

# Written by codepoint so an editor or a terminal without the font cannot mangle
# them: nf-md-memory (U+F035B), nf-md-expansion-card-variant (U+F0FB2) and
# nf-md-clock (U+F0954), the three already used in dot_tmux.conf.
ICON_CPU=$(printf '\363\260\215\233')
ICON_RAM=$(printf '\363\260\276\262')
ICON_UPTIME=$(printf '\363\260\245\224')

# Where the CPU baseline lives between ticks. XDG_RUNTIME_DIR is /run/user/<uid>
# and macOS TMPDIR is a private per-user directory, so both are per-user already;
# bare /tmp is shared, so the uid goes in the name there and only there, since
# `id -u` is a fork this script pays once a tick.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    state="${XDG_RUNTIME_DIR%/}/tmux-status-cpu"
elif [ -n "${TMPDIR:-}" ]; then
    state="${TMPDIR%/}/tmux-status-cpu"
else
    state="/tmp/tmux-status-cpu.$(id -u)"
fi

is_number() {
    case ${1:-} in
        '' | *[!0-9]*) return 1 ;;
    esac
}

# Diff two /proc/stat snapshots taken across ticks, as cpu_linux() in
# wezterm.lua does. The old cpu.sh took both snapshots itself either side of a
# blocking `sleep 0.2`, which was 218 ms of the 238 ms the three scripts cost
# between them; the gap between two status ticks serves as the interval instead,
# so the first tick after a restart has no baseline and prints "--".
cpu_linux() {
    read -r _ u n s id iw ir sr st _ </proc/stat || return 1
    total=$((u + n + s + id + iw + ir + sr + st))
    prev_total=''
    prev_idle=''
    if [ -r "$state" ]; then
        read -r prev_total prev_idle <"$state" || :
    fi
    printf '%s %s\n' "$total" "$id" >"$state" 2>/dev/null || :
    is_number "$prev_total" && is_number "$prev_idle" || return 1
    [ "$total" -gt "$prev_total" ] || return 1
    printf '%d\n' $(((total - prev_total - (id - prev_idle)) * 100 / (total - prev_total)))
}

# Sum of per-process %cpu over the core count, as cpu_macos() in wezterm.lua
# does. macOS reports each process's average over its own lifetime, so this is a
# smoothed approximation rather than an instantaneous reading; the alternative,
# `top -l 2`, stalls about a second.
cpu_macos() {
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null) || return 1
    is_number "$ncpu" || return 1
    ps -A -o %cpu= 2>/dev/null | awk -v ncpu="$ncpu" '
        { sum += $1 }
        END { p = int(sum / ncpu + 0.5); print (p > 100 ? 100 : p) }'
}

# used = MemTotal - MemAvailable, in GiB.
ram_linux() {
    awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{
        if (t > 0) printf "%5.1fG/%5.1fG\n", (t-a)/1048576, t/1048576
    }' /proc/meminfo 2>/dev/null
}

# used = (active + wired + compressed) pages * page size, as ram_macos() in
# wezterm.lua does; total from hw.memsize. vm_stat writes the page size into its
# header line and suffixes every count with a full stop, which awk's numeric
# coercion drops.
ram_macos() {
    total=$(sysctl -n hw.memsize 2>/dev/null) || return 1
    is_number "$total" || return 1
    vm_stat 2>/dev/null | awk -v total="$total" '
        BEGIN { ps = 4096 }
        /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { ps = $i; break } }
        /^Pages active:/ { active = $NF }
        /^Pages wired down:/ { wired = $NF }
        /^Pages occupied by compressor:/ { comp = $NF }
        END { printf "%5.1fG/%5.1fG\n", (active + wired + comp) * ps / 1073741824, total / 1073741824 }'
}

# `uptime` pads its columns and follows the uptime with the user count and the
# load averages, so keep the text between "up" and the first comma, then squeeze
# the padding down to single spaces. Portable across both platforms, unlike
# /proc/uptime and kern.boottime, and the two forks it costs are inside a script
# that now runs once a tick rather than three times.
uptime_field() {
    uptime | sed 's/.*up  *//; s/,.*//; s/  */ /g; s/^ //; s/ $//'
}

if [ -r /proc/stat ]; then
    cpu=$(cpu_linux) || cpu=''
    ram=$(ram_linux) || ram=''
else
    cpu=$(cpu_macos) || cpu=''
    ram=$(ram_macos) || ram=''
fi
up=$(uptime_field) || up=''

# Fixed-width fields, so a changing value does not shift the row: status-right is
# right-aligned, and everything left of a widening field moves. CPU pads to three
# digits for the 100% case and RAM to %5.1f per number, which is what cpu.sh and
# ram.sh did.
printf '%s %3s%%  %s %s  %s %s\n' \
    "$ICON_CPU" "${cpu:- --}" \
    "$ICON_RAM" "${ram:-           --}" \
    "$ICON_UPTIME" "${up:---}"
