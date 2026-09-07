#!/usr/bin/env bash
# Pull this repo, then state — unmissably — which branch the checkout is on.
#
# `npull` is step one of the two-step that ends in `nrs`, and `nrs` builds
# whatever happens to be checked out. A checkout left on a feature branch by an
# earlier session pulls cleanly, rebuilds cleanly, says nothing, and leaves the
# machine running a config that is not main. Git's own output does not close
# that gap: "Already up to date." reads identically on every branch, and the one
# line that does name a branch appears only on some outcomes. So the branch gets
# a banner of its own, printed *after* the pull — before, and git's output
# pushes it off the top; after, it is the last thing on screen at the moment
# `nrs` is typed on the next line.
#
# Generic across hosts — bound as the per-host `npull` alias in each home.nix
# rather than duplicated per machine. It deliberately takes no repo argument:
# the checkout paths differ (~/nixos-config on the Linux hosts,
# ~/Code/nixos-config on serenity), and a script that lives *in* the repo can
# derive the repo from its own location, so each alias is just a path to here.
#
# Usage: npull.sh [pr-number] [git-pull-args…]
#   pr-number    — optional, must be the first argument. A positive integer
#                  switches the checkout to that PR's head branch (via
#                  `gh pr checkout`) before pulling; 0 switches back to $TRUNK.
#                  Anything else (missing, or not a bare integer) leaves the
#                  current branch alone, matching the old behaviour.
#   git-pull-args — everything else passes through to `git pull`, so
#                  `npull --rebase` and `npull 42 --rebase` both still work.
set -euo pipefail

# The branch this fleet deploys from; anything else is worth flagging. Hardcoded
# rather than resolved from origin/HEAD, which is unset in a fresh clone —
# CLAUDE.md's workflow (feature branch + PR into main) is what pins this.
TRUNK="main"

# `cd … && pwd` rather than `realpath`/`readlink -f`: serenity is darwin, where
# readlink has no -f and realpath is not guaranteed to be on PATH.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "npull: $SCRIPT_DIR is not inside a git checkout." >&2
  echo "This pulls the repo it lives in — run it from your nixos-config clone." >&2
  exit 2
fi

# A bare leading integer picks the branch to pull *into*, before any pull
# happens. `10#$1` forces base-10 so a PR number typed with a leading zero
# (e.g. "007") isn't misread as octal by the -eq test below. Anything that
# isn't a plain integer (flags like --rebase, or nothing at all) is left for
# `git pull` untouched, so the old passthrough behaviour still works.
if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
  PR_NUM=$((10#$1))
  shift

  if [ "$PR_NUM" -eq 0 ]; then
    if ! git -C "$REPO" switch "$TRUNK"; then
      echo "npull: failed to switch to $TRUNK — see git's error above." >&2
      exit 2
    fi
  else
    if ! command -v gh >/dev/null 2>&1; then
      echo "npull: PR #$PR_NUM requested, but gh (GitHub CLI) isn't installed." >&2
      exit 2
    fi
    if ! (cd "$REPO" && gh pr checkout "$PR_NUM"); then
      echo "npull: gh pr checkout $PR_NUM failed — check the PR number and \`gh auth status\`." >&2
      exit 2
    fi
  fi
fi

# Deliberately not letting `set -e` abort on a failed pull: a conflict, a missing
# upstream or a detached HEAD is exactly when knowing the branch matters most, so
# the banner still prints and git's exit status is handed back at the end.
RC=0
git -C "$REPO" pull "$@" || RC=$?

# Empty means detached HEAD rather than an error.
BRANCH="$(git -C "$REPO" branch --show-current)"

# Colour only when stdout is a terminal — npull output gets piped and
# scrollback-grepped, and escape codes in that are noise.
if [ -t 1 ]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  BOLD='' DIM='' YELLOW='' RESET=''
fi
RULE='────────────────────────────────────────────────────────────────────'

echo
printf '%s%s%s\n' "$DIM" "$RULE" "$RESET"
if [ -z "$BRANCH" ]; then
  printf '  branch   %s%s⚠ DETACHED HEAD%s at %s\n' \
    "$BOLD" "$YELLOW" "$RESET" "$(git -C "$REPO" rev-parse --short HEAD)"
  printf '  %s⚠ not on a branch: nothing to pull into, and nrs would build%s\n' "$YELLOW" "$RESET"
  printf '  %s  this detached commit. Run "git switch %s" to get back.%s\n' "$YELLOW" "$TRUNK" "$RESET"
elif [ "$BRANCH" = "$TRUNK" ]; then
  printf '  branch   %s%s%s\n' "$BOLD" "$BRANCH" "$RESET"
else
  printf '  branch   %s%s%s%s\n' "$BOLD" "$YELLOW" "$BRANCH" "$RESET"
  printf '  %s⚠ not %s — nrs on this host builds THIS branch.%s\n' "$YELLOW" "$TRUNK" "$RESET"
fi
printf '%s%s%s\n' "$DIM" "$RULE" "$RESET"

exit "$RC"
