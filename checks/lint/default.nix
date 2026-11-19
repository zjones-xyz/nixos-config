# Flake check: shellcheck, actionlint, deadnix and statix over the repo.
#
# One derivation so there is one check to cite; each tool prints under its own
# banner and the first one with a finding fails the build, so a CI log names
# the tool and the line.
#
# ⚠ `nix flake check --no-build` only *evaluates* this — CI builds it
# explicitly; see .github/workflows/nix-check.yml.
{ pkgs, src }:

pkgs.runCommand "lint-check"
{
  nativeBuildInputs = [
    pkgs.shellcheck
    pkgs.actionlint
    pkgs.deadnix
    pkgs.statix
  ];
} ''
  cd ${src}

  # ── shellcheck ──
  # Every script here is bash; the two shebang-less ones under
  # hosts/galactica/ are writeShellApplication bodies, which run under bash.
  echo "── shellcheck ───────────────────────────────────────────"
  find . -name '*.sh' -type f -print0 | sort -z \
    | xargs -0 shellcheck --severity=warning --shell=bash
  echo "clean"

  echo "── actionlint ───────────────────────────────────────────"
  actionlint .github/workflows/*.yml
  echo "clean"

  # ── deadnix ──
  # --no-lambda-pattern-names: otherwise every unused `lib`/`pkgs`/`config` in
  # the `{ config, pkgs, lib, ... }:` module signature CLAUDE.md mandates is a
  # finding.
  echo "── deadnix ──────────────────────────────────────────────"
  deadnix --fail --no-lambda-pattern-names .
  echo "clean"

  echo "── statix ───────────────────────────────────────────────"
  statix check --config ${./statix.toml} .
  echo "clean"

  touch $out
''
