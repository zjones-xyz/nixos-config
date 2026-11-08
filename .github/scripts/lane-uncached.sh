#!/usr/bin/env bash
# What a bump newly leaves off cache.nixos.org. Used by update-apps.yml;
# rationale in docs/NIXPKGS-APPS.md § Bumps.
#
#   lane-uncached.sh hosts                    every host's toplevel installable
#   lane-uncached.sh list OUT INSTALLABLE...  drvs a switch would build locally
#   lane-uncached.sh check BEFORE AFTER REPORT
#       Builds the x86_64-linux fixed-output drvs new in AFTER (downloads,
#       so cheap; a stale outputHash fails here) and writes REPORT, a
#       markdown list of other package names new to building locally.
set -euo pipefail

hosts() {
  local kind attr
  for kind in nixosConfigurations darwinConfigurations; do
    for attr in $(nix eval --json ".#$kind" --apply builtins.attrNames | jq -r '.[]'); do
      echo ".#$kind.$attr.config.system.build.toplevel"
    done
  done
}

list() {
  local out=$1; shift
  # Dry-run prints "these N derivations will be built:" then indented .drv
  # paths; "will be fetched" lists outputs, which never end in .drv.
  nix build --dry-run --no-link "$@" 2>&1 >/dev/null \
    | grep -E '^\s+/nix/store/\S+\.drv$' | tr -d ' ' | sort -u >"$out"
  echo "$(wc -l <"$out") derivations would build locally" >&2
}

# /nix/store/<hash>-opencode-node_modules-2.2.5.drv -> opencode-node_modules
pname() { sed -E 's|^/nix/store/[a-z0-9]{32}-||; s|\.drv$||; s|-[0-9][^/]*$||'; }

check() {
  local before=$1 after=$2 report=$3
  local new fods
  new=$(comm -13 "$before" "$after")

  fods=
  [ -n "$new" ] && fods=$(xargs nix derivation show <<<"$new" \
    | jq -r '(.derivations // .) | to_entries[]
        | select(.value.system == "x86_64-linux")
        | select([.value.outputs[] | .hash? // empty] | length > 0)  # FOD
        | .key | if startswith("/") then . else "/nix/store/" + . end')

  if [ -n "$fods" ]; then
    echo "Building $(printf '%s\n' "$fods" | wc -l) new fixed-output derivation(s):" >&2
    sed 's/^/  /' <<<"$fods" >&2
    sed 's/$/^*/' <<<"$fods" | xargs nix build --no-link --keep-going
  fi

  # Non-FOD drvs: compare by name, since every bump rebuilds the same
  # host-specific wrappers (etc, home-manager-path, ...) under new hashes.
  # shellcheck disable=SC2016  # literal backticks: markdown code spans
  comm -13 <(pname <"$before" | sort -u) \
           <(grep -vxF -e /none -f <(echo "$fods") <<<"$new" | grep . | pname | sort -u) \
    | sed 's/.*/- `&`/' >"$report"
  if [ -s "$report" ]; then
    echo "::warning::$(wc -l <"$report") package(s) newly off cache.nixos.org; listed in the PR body"
    cat "$report"
  fi
}

"$@"
