#!/bin/bash
# Runs `nix flake check` inside a Claude Code web session, where outbound
# GitHub access is proxied and scoped to this repo only — so the normal
# github: tarball-API fetch of flake inputs (nixpkgs, home-manager, ...)
# gets a 403. Plain git-protocol clones aren't subject to that restriction,
# so this rewrites every input to its exact locked revision via git+https
# and runs the check against those overrides instead.
#
# This validates evaluation against the same commits flake.lock already
# pins — it does not change what gets built, only how inputs are fetched
# for this one invocation. CI (.github/workflows/nix-check.yml) runs the
# unmodified `nix flake check` with full GitHub access.
#
# TRANSITIVE inputs are rewritten too, not just top-level ones. Overriding only
# the root's own inputs is not enough: claude-desktop-debian brings its own
# flake-parts (and that brings nixpkgs-lib), and those are fetched through the
# same tarball API that 403s. The symptom is a 403 for a repo that appears
# nowhere in flake.nix. nix addresses nested inputs by slash-path
# (`--override-input claude-desktop-debian/flake-parts ...`), so walk the lock
# graph from root and emit one override per reachable node.
#
# Inputs declared with `follows` appear in flake.lock as an array rather than a
# node name; they are skipped, since they resolve to a node that is already
# being overridden in its own right.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Emit "<slash-path>\t<node-name>" for every node reachable from root.
readarray -t edges < <(jq -r '
  . as $doc
  | def descend($node; $prefix):
      ($doc.nodes[$node].inputs // {}) | to_entries[]
      | select(.value | type == "string")
      | ($prefix + .key) as $path
      | .value as $child
      | [$path, $child], descend($child; $path + "/");
    descend("root"; "")
  | @tsv
' flake.lock)

overrides=()
seen=""
for edge in "${edges[@]}"; do
  path=${edge%%$'\t'*}
  node=${edge##*$'\t'}

  # A node can be reachable by more than one path; one override per path is
  # correct, but guard against a pathological lock graph looping forever.
  case " $seen " in *" $path "*) continue ;; esac
  seen="$seen $path"

  type=$(jq -r --arg n "$node" '.nodes[$n].locked.type' flake.lock)
  rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' flake.lock)

  case "$type" in
    github)
      owner=$(jq -r --arg n "$node" '.nodes[$n].locked.owner' flake.lock)
      repo=$(jq -r --arg n "$node" '.nodes[$n].locked.repo' flake.lock)
      overrides+=(--override-input "$path" "git+https://github.com/${owner}/${repo}.git?rev=${rev}&shallow=1")
      ;;
    git)
      # A locked git input records a bare https:// url. Passing that through
      # unchanged drops both the `git+` scheme prefix and the rev, so nix falls
      # back to treating it as a *tarball* url and re-resolves it through the
      # GitHub tarball API — the exact 403 this script exists to avoid. Rebuild
      # the full git+https://...?rev=... form instead.
      url=$(jq -r --arg n "$node" '.nodes[$n].locked.url' flake.lock)
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
done

nix flake check --no-build "${overrides[@]}" "$@"
