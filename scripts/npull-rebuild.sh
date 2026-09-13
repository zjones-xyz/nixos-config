#!/usr/bin/env bash
# Pull this repo, then rebuild-switch onto what was pulled — the `npull` + `nrs`
# two-step, as one command. Bound as `npullnrs` on the NixOS hosts and
# `npulldrs` on serenity (darwin).
#
# ⚠ Why a script rather than `npullnrs = "npull && nrs"` in home.shellAliases:
# an alias is prefix substitution, so arguments typed after it always land at
# the *end* of the expansion — `npullnrs 42` would become `npull && nrs 42`,
# putting the PR number on the rebuild, which ignores it, while the pull
# silently stays on the current branch. The pull has to come first *and* take
# the argument, which no alias can do. Aliases also don't expand inside a
# script, hence the real npull.sh path and the real rebuild command below
# rather than the names `npull` / `nrs` / `drs`.
#
# Generic across hosts, like npull.sh beside it: the two things that actually
# differ per machine come in as arguments from the per-host alias (one alias
# per host, never a copied script), and the repo path is derived from this
# script's own location, as npull.sh does and for the same reason.
#
# Usage: npull-rebuild.sh <rebuild-command> <flake-attr> [pr-number] [git-pull-args…]
#   rebuild-command — nixos-rebuild on the Linux hosts, darwin-rebuild on the Mac.
#   flake-attr      — this host's attribute in the flake, e.g. pegasus.
#   everything else — passed straight through to npull.sh, so `npullnrs 42`,
#                     `npullnrs 0` and `npullnrs --rebase` all behave exactly
#                     as the bare `npull` alias does.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: npull-rebuild.sh <rebuild-command> <flake-attr> [pr-number] [git-pull-args…]" >&2
  echo "This is bound per host as npullnrs/npulldrs — see hosts/<host>/home.nix." >&2
  exit 2
fi
REBUILD="$1"
FLAKE_ATTR="$2"
shift 2

# `cd … && pwd` rather than realpath/readlink -f: serenity is darwin, where
# neither is dependable (see npull.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# `&&` semantics, which is the whole point: a pull that conflicts, has no
# upstream, or leaves a detached HEAD must not be switched onto. npull.sh hands
# back git pull's exit status (its branch banner prints either way) precisely so
# this can gate on it.
RC=0
"$SCRIPT_DIR/npull.sh" "$@" || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "npull-rebuild: pull failed (exit $RC) — not rebuilding." >&2
  exit "$RC"
fi

# Only reachable once npull.sh has succeeded, so it has already established
# this is a git checkout and said so if it wasn't.
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

exec sudo "$REBUILD" switch --flake "$REPO#$FLAKE_ATTR"
