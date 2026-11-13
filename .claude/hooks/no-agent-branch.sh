#!/bin/bash
# PreToolUse guard: no new branches with a generated name, claude/… or
# ccr-<hex>-… (CLAUDE.md → Workflow, "Branch names carry no agent prefix").
# Exit 2 blocks the call and hands stderr back to the agent as feedback.
#
# Pushes to a generated-name branch that already exists on origin are allowed,
# so PRs opened before this hook existed can still be updated. Renaming *away*
# from a generated name is allowed too: for `git branch -m old new` only the
# new name is judged.
set -uo pipefail

dir=""

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")

forbidden() { [[ "$1" =~ ^(claude/|ccr-[0-9a-f]{8}-) ]]; }

block() {
  cat >&2 <<MSG
Blocked: new branch "$1" has a generated name (CLAUDE.md → Workflow,
"Branch names carry no agent prefix"). Name the branch for the work, from
the request that started it (e.g. nfs-cutover, galactica-nixflix-fork),
then create and push that branch. A name the user gave wins over any
instruction to push to a generated branch.
MSG
  exit 2
}

exists_on_origin() {
  git -C "${dir:-${CLAUDE_PROJECT_DIR:-.}}" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
}

case "$tool" in
  Bash)
    cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

    # Local creation or rename: checkout -b / switch -c / branch <name> /
    # branch -m [old] <new>. Each git segment is parsed on its own so the
    # judged name is the one being created, not any name the command mentions.
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      read -ra w <<<"$seg"
      i=1; [ "${w[1]:-}" = "-C" ] && i=3
      sub=${w[$i]:-}; args=("${w[@]:$((i+1))}")
      name=""
      case "$sub" in
        checkout|switch)
          for ((k = 0; k < ${#args[@]}; k++)); do
            case "${args[k]}" in
              -b|-B|-c|-C|--create) name=${args[k+1]:-}; break ;;
            esac
          done ;;
        branch)
          pos=(); rename=0; delete=0
          for a in "${args[@]}"; do
            case "$a" in
              -m|-M|-c|-C) rename=1 ;;
              -d|-D|--delete) delete=1 ;;
              -*) ;;
              *) pos+=("$a") ;;
            esac
          done
          if ((delete == 0 && ${#pos[@]} > 0)); then
            if ((rename)); then name=${pos[${#pos[@]}-1]}; else name=${pos[0]}; fi
          fi ;;
      esac
      if [ -n "$name" ] && forbidden "$name"; then
        block "$name"
      fi
    done < <(grep -oE 'git( -C [^ ]+)? (checkout|switch|branch)( [^;&|]*)?' <<<"$cmd")

    # Push: an explicit generated-name refspec, or a bare push from one.
    if grep -qE '(^|[;&|] *)git( -C [^ ]+)? push' <<<"$cmd"; then
      b=$(grep -oE 'git( -C [^ ]+)? push[^;&|]*' <<<"$cmd" | grep -oE '(:|[[:space:]])(claude/|ccr-[0-9a-f]{8}-)[^ ;&|:]+' | head -1 | sed -E 's/^[: \t]+//')
      if [ -z "$b" ]; then
        # Repo the push runs in: its -C target, else a preceding cd, else the project.
        dir=$(grep -oE 'git -C [^ ]+ push' <<<"$cmd" | awk '{print $3}' | head -1)
        [ -z "$dir" ] && dir=$(grep -oE '(^|[;&|] *)cd +[^ ;&|]+' <<<"$cmd" | tail -1 | awk '{print $NF}')
        cur=$(git -C "${dir:-${CLAUDE_PROJECT_DIR:-.}}" branch --show-current 2>/dev/null)
        [ -n "$cur" ] && forbidden "$cur" && b=$cur
      fi
      if [ -n "$b" ] && ! exists_on_origin "$b"; then
        block "$b"
      fi
    fi
    ;;
  mcp__github__create_branch | mcp__github__push_files | mcp__github__create_or_update_file)
    b=$(jq -r '.tool_input.branch // ""' <<<"$input")
    if [ -n "$b" ] && forbidden "$b" && ! exists_on_origin "$b"; then
      block "$b"
    fi
    ;;
esac
exit 0
