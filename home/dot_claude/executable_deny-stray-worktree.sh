#!/usr/bin/env bash
# Deny a Bash `git worktree add` whose path is outside .claude/worktrees/.
#
# Run as a PreToolUse hook on Bash, with the hook's JSON on stdin. Claude Code
# puts its own worktrees (--worktree, EnterWorktree, subagent isolation) in
# <repo>/.claude/worktrees/, but through Bash Claude tends to add them beside
# the repository, in the parent directory. The check is textual: a command
# that names .claude/worktrees/ anywhere passes.
set -u

command -v jq >/dev/null 2>&1 || exit 0
cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0

printf '%s\n' "$cmd" | grep -Eq 'worktree[[:space:]]+add' || exit 0
printf '%s\n' "$cmd" | grep -Fq '.claude/worktrees/' && exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "Create worktrees with the EnterWorktree tool, or under <repo>/.claude/worktrees/, never beside the repository."
  }
}'
