#!/bin/bash
# Runs `nix flake check` inside a Claude Code web session, where outbound
# GitHub access is proxied and scoped to this repo only — so the normal
# github: tarball-API fetch of flake inputs (nixpkgs, home-manager, ...)
# gets a 403. Plain git-protocol clones aren't subject to that restriction,
# so this rewrites every input to its exact locked revision via git+https
# (or passes through non-github locked URLs as-is) and runs the check
# against those overrides instead.
#
# "every input" means transitively, not just the top level: an input's own
# inputs are fetched too (claude-desktop-debian pulls flake-parts, which
# pulls nixpkgs-lib, …), and each one 403s the same way. --override-input
# addresses those by their path from the root — `a/b/c` — so this walks the
# whole lock graph and emits one override per reachable node.
#
# This validates evaluation against the same commits flake.lock already
# pins — it does not change what gets built, only how inputs are fetched
# for this one invocation. CI (.github/workflows/nix-check.yml) runs the
# unmodified `nix flake check` with full GitHub access.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Flatten the lock graph to "<input-path>\t<node-id>" lines, breadth-first
# from the root. `follows` entries are arrays rather than node-id strings —
# skipped, since they resolve to a node already reached by its own path.
# $seen carries the node ids along the current chain only, so a cycle
# terminates without also suppressing legitimately shared nodes elsewhere
# in the tree (nixpkgs is reachable by many distinct paths, and each path
# needs its own override to be fetched over git).
# ($root is bound up front because `.` is rebound to each input entry as the
# pipeline descends — a bare `.nodes[…]` inside walk() would look it up on
# the entry object and silently yield nothing but the top level.)
paths=$(jq -r '
  . as $root
  | def walk($node; $path; $seen):
      ( $root.nodes[$node].inputs // {} | to_entries[] )
      | select(.value | type == "string")
      | .value as $child
      | ($path + [.key]) as $p
      | select($seen | index($child) | not)
      | (($p | join("/")) + "\t" + $child), walk($child; $p; $seen + [$child]);
    walk("root"; []; ["root"])
' flake.lock)

overrides=()
while IFS=$'\t' read -r path node; do
  [ -n "$path" ] || continue
  type=$(jq -r --arg n "$node" '.nodes[$n].locked.type // ""' flake.lock)
  case "$type" in
    github)
      owner=$(jq -r --arg n "$node" '.nodes[$n].locked.owner' flake.lock)
      repo=$(jq -r --arg n "$node" '.nodes[$n].locked.repo' flake.lock)
      rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev' flake.lock)
      overrides+=(--override-input "$path" "git+https://github.com/${owner}/${repo}.git?rev=${rev}&shallow=1")
      ;;
    git)
      # locked.url for a git input is the bare transport URL ("https://…"),
      # with the `git+` prefix stripped. Passing it through as-is makes nix
      # re-parse it as a *tarball* URL and hit the same 403 this script
      # exists to avoid — so put the prefix back and pin the rev explicitly.
      url=$(jq -r --arg n "$node" '.nodes[$n].locked.url' flake.lock)
      rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev' flake.lock)
      overrides+=(--override-input "$path" "git+${url}?rev=${rev}&shallow=1")
      ;;
    tarball|file)
      url=$(jq -r --arg n "$node" '.nodes[$n].locked.url' flake.lock)
      overrides+=(--override-input "$path" "$url")
      ;;
    *)
      echo "warning: unhandled input type '$type' for '$path', leaving unoverridden" >&2
      ;;
  esac
done <<< "$paths"

nix flake check --no-build "${overrides[@]}" "$@"
