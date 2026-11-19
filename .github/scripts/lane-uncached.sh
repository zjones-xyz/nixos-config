#!/usr/bin/env bash
# What a bump newly leaves off cache.nixos.org. Used by update-apps.yml;
# rationale and limits in docs/NIXPKGS-APPS.md § Bumps.
#
#   lane-uncached.sh hosts                    every host's toplevel installable
#   lane-uncached.sh list OUT INSTALLABLE...  drvs a switch would build locally
#   lane-uncached.sh check BEFORE AFTER REPORT
#       Builds the x86_64-linux fixed-output drvs whose *output* is new in
#       AFTER (a stale outputHash fails here) and writes REPORT, a markdown
#       list of other package names that build locally after but not before.
set -euo pipefail
export LC_ALL=C # sort and join must agree on order

hosts() {
  local kind attrs attr
  for kind in nixosConfigurations darwinConfigurations; do
    # Assigned first: a failure inside a for-list wouldn't trip errexit.
    attrs=$(nix eval --json ".#$kind" --apply builtins.attrNames | jq -r '.[]')
    for attr in $attrs; do
      echo ".#$kind.$attr.config.system.build.toplevel"
    done
  done
}

list() {
  local out=$1 log; shift
  log=$(mktemp)
  # Dry-run prints "these N derivations will be built:" then indented .drv
  # paths; "will be fetched" lists outputs, which never end in .drv.
  if ! nix build --dry-run --no-link "$@" 2>"$log" >/dev/null; then
    cat "$log" >&2
    exit 1
  fi
  { grep -E '^\s+/nix/store/\S+\.drv$' "$log" || true; } | tr -d ' ' | sort -u >"$out"
  rm -f "$log"
  echo "$(wc -l <"$out") derivations would build locally" >&2
}

# /nix/store/<hash>-opencode-node_modules-2.2.5.drv -> opencode-node_modules
pname() { sed -E 's|^/nix/store/[a-z0-9]{32}-||; s|\.drv$||; s|-[0-9][^/]*$||'; }

# x86_64-linux fixed-output drvs among the drv paths in file $1, one per
# line as "<drv> <output path>".
fod_outputs() {
  local drv
  [ -s "$1" ] || return 0
  xargs nix derivation show <"$1" \
    | jq -r '(.derivations // .) | to_entries[]
        | select(.value.system == "x86_64-linux")
        | select([.value.outputs[] | .hash? // empty] | length > 0)
        | .key | if startswith("/") then . else "/nix/store/" + . end' \
    | while read -r drv; do echo "$drv $(nix-store -q --outputs "$drv")"; done
}

check() {
  local before=$1 after=$2 report=$3 tmp
  tmp=$(mktemp -d)
  comm -13 "$before" "$after" >"$tmp/new"
  fod_outputs "$tmp/new" | sort -k2,2 >"$tmp/new-fods"
  fod_outputs "$before" | cut -d' ' -f2 | sort -u >"$tmp/old-outs"

  # A new FOD *drv* often has the same output as before: a fetcher change
  # rehashes every drv without changing what it downloads. Only an output
  # that wasn't already uncached before the bump counts as new.
  join -v1 -1 2 -2 1 "$tmp/new-fods" "$tmp/old-outs" | cut -d' ' -f2 >"$tmp/build"
  if [ -s "$tmp/build" ]; then
    # Building one also builds any uncached input its fetcher needs.
    echo "Building $(wc -l <"$tmp/build") fixed-output derivation(s) with new outputs:" >&2
    sed 's/^/  /' "$tmp/build" >&2
    sed 's/$/^*/' "$tmp/build" | xargs nix build --no-link --keep-going
  fi

  # Non-FOD drvs: compare by name, since every bump rebuilds the same
  # host-specific wrappers (etc, home-manager-path, ...) under new hashes.
  # So a package that already built locally before the bump never shows.
  cut -d' ' -f1 "$tmp/new-fods" >"$tmp/fod-drvs"
  { grep -vxF -f "$tmp/fod-drvs" "$tmp/new" || true; } | pname | sort -u >"$tmp/new-names"
  pname <"$before" | sort -u >"$tmp/old-names"
  # shellcheck disable=SC2016  # literal backticks: markdown code spans
  comm -13 "$tmp/old-names" "$tmp/new-names" | sed 's/.*/- `&`/' >"$report"
  rm -rf "$tmp"
  if [ -s "$report" ]; then
    echo "::warning::$(wc -l <"$report") package(s) newly build locally; listed in the PR body"
    cat "$report"
  fi
}

"$@"
