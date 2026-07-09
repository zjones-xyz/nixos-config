#!/bin/bash
# Runs `nix flake check` inside a Claude Code web session, where outbound
# GitHub access is proxied and scoped to this repo only — so the normal
# github: tarball-API fetch of flake inputs (nixpkgs, home-manager, ...)
# gets a 403. Plain git-protocol clones aren't subject to that restriction,
# so this rewrites every top-level input to its exact locked revision via
# git+https (or passes through non-github locked URLs as-is) and runs the
# check against those overrides instead.
#
# This validates evaluation against the same commits flake.lock already
# pins — it does not change what gets built, only how inputs are fetched
# for this one invocation. CI (.github/workflows/nix-check.yml) runs the
# unmodified `nix flake check` with full GitHub access.
set -euo pipefail
cd "$(dirname "$0")/../.."

overrides=()
for name in $(jq -r '.nodes.root.inputs | keys[]' flake.lock); do
  node=$(jq -r --arg n "$name" '.nodes.root.inputs[$n]' flake.lock)
  type=$(jq -r --arg n "$node" '.nodes[$n].locked.type' flake.lock)
  case "$type" in
    github)
      owner=$(jq -r --arg n "$node" '.nodes[$n].locked.owner' flake.lock)
      repo=$(jq -r --arg n "$node" '.nodes[$n].locked.repo' flake.lock)
      rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev' flake.lock)
      overrides+=(--override-input "$name" "git+https://github.com/${owner}/${repo}.git?rev=${rev}&shallow=1")
      ;;
    tarball|git|file)
      url=$(jq -r --arg n "$node" '.nodes[$n].locked.url' flake.lock)
      overrides+=(--override-input "$name" "$url")
      ;;
    *)
      echo "warning: unhandled input type '$type' for '$name', leaving unoverridden" >&2
      ;;
  esac
done

nix flake check --no-build "${overrides[@]}" "$@"
