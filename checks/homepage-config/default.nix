# Flake check for galactica's Homepage dashboard configs.
#
# Two passes over hosts/galactica/homepage: yamllint for syntax/duplicate keys,
# then validate.py for the cross-file invariants (see its docstring). `instances`
# carries each dashboard's HOMEPAGE_VAR_* set, read by flake.nix out of the
# evaluated sops templates so the check can't drift from what the containers get.
#
# ⚠ `nix flake check --no-build` only *evaluates* this — it has to actually run
# to check anything. CI therefore builds it explicitly; see
# .github/workflows/nix-check.yml.
{ pkgs, configDir, instances }:

pkgs.runCommand "homepage-config-check"
{
  nativeBuildInputs = [
    pkgs.yamllint
    (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
  ];
  instancesJson = builtins.toJSON instances;
  passAsFile = [ "instancesJson" ];
} ''
  echo "── yamllint ─────────────────────────────────────────────"
  yamllint --strict --config-file ${./yamllint.yaml} ${configDir}
  echo "clean"

  echo "── structural + cross-file validation ───────────────────"
  python3 ${./validate.py} \
    --config-dir ${configDir} \
    --instances "$(cat "$instancesJsonPath")"

  touch $out
''
