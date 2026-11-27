# Two lines after a blank one: [directory][branch:upstream](hash) (STATE n/m) [status]
# then $, green or red from the last exit status. In a git work tree the prompt
# forks git once, for `git status`; elsewhere it forks nothing.
function fish_prompt --description 'Directory and git state, then $'
    set -l last_status $status

    # Walk up for .git, a directory or, in a worktree or submodule, a file
    # naming the git directory.
    set -l root
    set -l gitdir
    set -l d $PWD
    while true
        if test -d $d/.git
            set root $d
            set gitdir $d/.git
            break
        else if test -f $d/.git
            set root $d
            read -l line <$d/.git
            set gitdir (string replace -- 'gitdir: ' '' $line)
            string match -q -- '/*' $gitdir; or set gitdir $d/$gitdir
            break
        end
        test "$d" = /; and break
        set d (path dirname -- $d)
    end

    # The path from the repository's root, which keeps the root's name, or
    # else from ~, cut to the last three parts.
    set -l dir
    if test -n "$root"; and test "$root" != "$HOME"
        set dir (path basename -- $root)(string sub -s (math (string length -- $root) + 1) -- $PWD)
    else
        set dir (string replace -r -- '^'(string escape --style=regex -- $HOME)'(?=/|$)' '~' $PWD)
    end
    set -l parts (string split -n / -- $dir)
    test (count $parts) -gt 3; and set dir (string join / $parts[-3..-1])
    set -l line \e'[1;36m['$dir']'\e'[0m'

    if test -n "$root"
        # Optional locks stay on, so git writes back the refreshed index and
        # untracked cache. Without them, a 190k-file repository took 80 ms a
        # prompt against 49 ms. While it writes, git holds index.lock, and a
        # git command started then in the same repository fails.
        set -l st (command git status --porcelain=v2 --branch --show-stash 2>/dev/null)
        set -l head (string replace -f -- '# branch.head ' '' $st)
        if test -z "$head"
            # git status refuses to run inside the git directory itself.
            read -l ref <$gitdir/HEAD
            set head (string replace -f -- 'ref: refs/heads/' '' $ref; or echo HEAD)
        end
        test "$head" = '(detached)'; and set head HEAD
        # The upstream's branch, less its remote, or a local branch as it is.
        set -l up (string replace -f -- '# branch.upstream ' '' $st | string replace -r -- '^[^/]+/' '')
        if test -n "$up"; and test "$up" != "$head"
            set line $line\e'[35m['$head:$up']'\e'[0m'
        else
            set line $line\e'[35m['$head']'\e'[0m'
        end

        if test "$head" = HEAD
            set -l oid (string replace -f -- '# branch.oid ' '' $st)
            test -n "$oid"; and set line $line\e'[1;32m('(string sub -l 7 -- $oid)')'\e'[0m '
        end

        set -l state
        if test -d $gitdir/rebase-merge
            read -l n <$gitdir/rebase-merge/msgnum
            read -l m <$gitdir/rebase-merge/end
            set state "REBASING $n/$m"
        else if test -d $gitdir/rebase-apply
            read -l n <$gitdir/rebase-apply/next
            read -l m <$gitdir/rebase-apply/last
            if test -f $gitdir/rebase-apply/rebasing
                set state "REBASING $n/$m"
            else if test -f $gitdir/rebase-apply/applying
                set state "AM $n/$m"
            else
                set state "AM/REBASE $n/$m"
            end
        else if test -f $gitdir/MERGE_HEAD
            set state MERGING
        else if test -f $gitdir/CHERRY_PICK_HEAD
            set state CHERRY-PICKING
        else if test -f $gitdir/REVERT_HEAD
            set state REVERTING
        else if test -f $gitdir/BISECT_LOG
            set state BISECTING
        end
        test -n "$state"; and set line $line'('\e'[1;33m'$state\e'[0m) '

        # One mark for each kind of change present, never a count.
        set -l marks
        string match -q -- '# stash *' $st; and set -a marks '$'
        string match -qr -- '^[12] (D.|.D)' $st; and set -a marks ✘
        string match -qr -- '^2 ' $st; and set -a marks »
        string match -qr -- '^[12] .M' $st; and set -a marks !
        string match -qr -- '^[12] [ACMT]' $st; and set -a marks +
        string match -q -- '? *' $st; and set -a marks '?'
        set -q marks[1]; and set line $line\e'[31m['(string join '' $marks)']'\e'[0m'
    end

    set -l colour 32
    test $last_status -ne 0; and set colour 31
    # \e[J clears the blank line from column 0, which drops the OSC 133;A mark
    # fish sent there, so tmux's previous-prompt finds one mark per prompt: the
    # one on the first line with text.
    printf '\e[J\n\e]133;A\a%s\n\e[1;%sm$\e[0m ' $line $colour
end
