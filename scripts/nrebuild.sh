#!/usr/bin/env bash
# Rebuild this host from the checkout this script lives in, saying which branch
# that is — before, so there is a moment to abort, and again after, so the
# answer survives the build's own output.
#
# ⚠ Why this exists as a script rather than the old bare alias
# (`sudo nixos-rebuild switch --flake ~/nixos-config#<host>`): the alias builds
# whatever is checked out and never says what that is. npull warned about this,
# but only on the path that goes through npull — typing `nrs` on its own, or
# after another session moved the checkout, got no warning at all.
#
# Generic across hosts and platforms, like npull.sh beside it: everything that
# differs per machine comes in as arguments from the per-host alias (one alias
# per host, never a copied script), and the repo path is derived from this
# script's own location.
#
# Usage: nrebuild.sh <rebuild-command> <subcommand> <flake-attr> [rebuild-args…]
#   rebuild-command — nixos-rebuild on the Linux hosts, darwin-rebuild on the Mac.
#   subcommand      — switch or test.
#   flake-attr      — this host's attribute in the flake, e.g. pegasus.
#   rebuild-args    — passed through, so `nrs --show-trace` still works.
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "usage: nrebuild.sh <rebuild-command> <subcommand> <flake-attr> [rebuild-args…]" >&2
  echo "This is bound per host as nrs/nrt/drs — see hosts/<host>/home.nix." >&2
  exit 2
fi
REBUILD="$1"
SUBCOMMAND="$2"
FLAKE_ATTR="$3"
shift 3

# `cd … && pwd` rather than realpath/readlink -f: serenity is darwin, where
# neither is dependable (see npull.sh).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  echo "nrebuild: $SCRIPT_DIR is not inside a git checkout." >&2
  echo "This builds the repo it lives in — run it from your nixos-config clone." >&2
  exit 2
fi

# npull-rebuild.sh has just printed this banner itself, so it suppresses the
# pre-build one to keep the two from stacking up back to back.
if [ -z "${NREBUILD_NO_PRE_BANNER:-}" ]; then
  "$SCRIPT_DIR/branch-banner.sh" "$REPO" \
    "about to build THIS branch. Ctrl-C now if that is not what you meant."
fi

# Not `exec`: the point is to get back here afterwards and restate the branch,
# whether the rebuild succeeded or not. A failed switch leaves the previous
# generation running, so the branch is still the thing worth knowing.
RC=0
sudo "$REBUILD" "$SUBCOMMAND" --flake "$REPO#$FLAKE_ATTR" "$@" || RC=$?

if [ "$RC" -eq 0 ]; then
  AFTER_NOTE="$FLAKE_ATTR was just built from THIS branch."
else
  AFTER_NOTE="the build failed; $FLAKE_ATTR is still on its previous generation."
fi
"$SCRIPT_DIR/branch-banner.sh" "$REPO" "$AFTER_NOTE"

exit "$RC"
