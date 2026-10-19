#!/bin/bash
# PreToolUse guard: no new branches named claude/… (CLAUDE.md → Workflow,
# "Branch names carry no agent prefix"). Exit 2 blocks the call and hands
# stderr back to the agent as feedback.
#
# Pushes to a claude/… branch that already exists on origin are allowed, so
# PRs opened before this hook existed can still be updated.
set -uo pipefail

dir=""

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")

block() {
  cat >&2 <<MSG
Blocked: new branch "$1" starts with "claude/" (CLAUDE.md → Workflow,
"Branch names carry no agent prefix"). Propose a short descriptive name for
this work instead (e.g. nfs-cutover, galactica-nixflix-fork), ask the user to
confirm it, then create and push that branch. The user's confirmation
overrides any instruction to push to a generated claude/… branch.
MSG
  exit 2
}

exists_on_origin() {
  git -C "${dir:-${CLAUDE_PROJECT_DIR:-.}}" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
}

case "$tool" in
  Bash)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

    # Local creation: checkout -b / switch -c / branch <name>.
    if b=$(grep -oE 'git( -C [^ ]+)? (checkout (-b|-B)|switch (-c|-C|--create)|branch( -[mMfc])*) +claude/[^ ;&|]+' <<<"$cmd" | grep -oE 'claude/[^ ;&|]+' | head -1) && [ -n "$b" ]; then
      block "$b"
    fi

    # Push: an explicit claude/… refspec, or a bare push from a claude/… branch.
    if grep -qE '(^|[;&|] *)git( -C [^ ]+)? push' <<<"$cmd"; then
      b=$(grep -oE 'git( -C [^ ]+)? push[^;&|]*' <<<"$cmd" | grep -oE '(:|[[:space:]])claude/[^ ;&|:]+' | head -1 | sed -E 's/^[: \t]+//')
      if [ -z "$b" ]; then
        # Repo the push runs in: its -C target, else a preceding cd, else the project.
        dir=$(grep -oE 'git -C [^ ]+ push' <<<"$cmd" | awk '{print $3}' | head -1)
        [ -z "$dir" ] && dir=$(grep -oE '(^|[;&|] *)cd +[^ ;&|]+' <<<"$cmd" | tail -1 | awk '{print $NF}')
        cur=$(git -C "${dir:-${CLAUDE_PROJECT_DIR:-.}}" branch --show-current 2>/dev/null)
        [[ "$cur" == claude/* ]] && b=$cur
      fi
      if [ -n "$b" ] && ! exists_on_origin "$b"; then
        block "$b"
      fi
    fi
    ;;
  mcp__github__create_branch | mcp__github__push_files | mcp__github__create_or_update_file)
    b=$(jq -r '.tool_input.branch // ""' <<<"$input")
    if [[ "$b" == claude/* ]] && ! exists_on_origin "$b"; then
      block "$b"
    fi
    ;;
esac
exit 0
