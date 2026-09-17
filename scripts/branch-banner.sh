#!/usr/bin/env bash
# Print, unmissably, which branch a checkout is on.
#
# Factored out of npull.sh so `nrs`/`nrt`/`drs` can print the same banner —
# every one of those builds whatever happens to be checked out, and a checkout
# left on a feature branch by an earlier session (or a concurrent one) rebuilds
# cleanly while saying nothing. Git's own output does not close that gap:
# "Already up to date." reads identically on every branch.
#
# One script rather than a copy per caller, for the same reason npull.sh takes
# its per-host differences as arguments: the wording of this warning is the
# thing that must not drift between the commands it warns about.
#
# Usage: branch-banner.sh <repo-path> <off-trunk-note>
#   repo-path      — any path inside the checkout.
#   off-trunk-note — one line, printed only when the branch is not TRUNK, that
#                    says what the *calling* command will do with it. Callers
#                    differ here and nothing else does.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: branch-banner.sh <repo-path> <off-trunk-note>" >&2
  exit 2
fi
REPO="$1"
OFF_TRUNK_NOTE="$2"

# The branch this fleet deploys from; anything else is worth flagging. Kept in
# step with npull.sh, which hardcodes it for the same reason: origin/HEAD is
# unset in a fresh clone.
TRUNK="main"

# Empty means detached HEAD rather than an error.
BRANCH="$(git -C "$REPO" branch --show-current)"

# Colour only when stdout is a terminal — this output gets piped and
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
  printf '  %s⚠ not on a branch — this detached commit is what npull and the%s\n' "$YELLOW" "$RESET"
  printf '  %s  rebuild aliases act on. Run "git switch %s" to get back.%s\n' "$YELLOW" "$TRUNK" "$RESET"
elif [ "$BRANCH" = "$TRUNK" ]; then
  printf '  branch   %s%s%s\n' "$BOLD" "$BRANCH" "$RESET"
else
  printf '  branch   %s%s%s%s\n' "$BOLD" "$YELLOW" "$BRANCH" "$RESET"
  printf '  %s⚠ not %s — %s%s\n' "$YELLOW" "$TRUNK" "$OFF_TRUNK_NOTE" "$RESET"
fi
printf '%s%s%s\n' "$DIM" "$RULE" "$RESET"
