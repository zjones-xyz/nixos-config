# ── Fleet registry generators ────────────────────────────────────────────────
# Pure functions over the typed `homelab.fleet.*` values (defaults already
# filled by modules/nixos/fleet.nix). Exact names only: no wildcard support,
# so wildcard groups and host-identity wildcards stay hand-written — a
# "wildcard-group" scope is the natural next phase.
{ lib }:

let
  suffix = {
    internal = "internal";
    private = "zjones.dev";
    public = "zjones.xyz";
  };

  domainFor =
    name: svc: plane:
    if svc.scope == "flat" then "${name}.${suffix.${plane}}" else "${name}.${svc.host}.${suffix.${plane}}";

  # The public plane is the only one the split-horizon switches can drop.
  emitted =
    splitHorizonGlobal: svc: plane:
    svc.planes.${plane} && (plane != "public" || (svc.splitHorizon && splitHorizonGlobal));

  unknownHost =
    name: svc: "fleet/services.nix: `${name}` names unknown host `${svc.host}` (not in fleet/hosts.nix).";

  # One row per (service, plane) passing `keep`.
  rowsWhere =
    keep: f: services:
    lib.concatLists (
      lib.mapAttrsToList (
        name: svc: map (plane: f name svc plane) (lib.filter (keep svc) (lib.attrNames suffix))
      ) services
    );
in
{
  # AdGuard rewrite rows, sorted by domain. `enabled = true` is set here: an
  # omitted bool renders as Go's zero value and silently disables the row.
  rewritesFor =
    { hosts, services, splitHorizonGlobal }:
    lib.sort (a: b: a.domain < b.domain) (
      rowsWhere (emitted splitHorizonGlobal) (name: svc: plane: {
        domain = domainFor name svc plane;
        # Reached before the assertions report, so it needs its own message.
        answer = hosts.${svc.host}.ip or (throw (unknownHost name svc));
        enabled = true;
      }) services
    );

  # NixOS `assertions` entries; forced by every toplevel eval (CI's per-host
  # drvPath step), since fleet.nix is imported from common.nix.
  hostAssertions =
    { hosts, services }:
    lib.mapAttrsToList (name: svc: {
      assertion = hosts ? ${svc.host};
      message = unknownHost name svc;
    }) services;

  uniqueDomainAssertions =
    { services }:
    let
      # Ignores split-horizon, so a collision fails whether or not it's on.
      claims = rowsWhere (svc: plane: svc.planes.${plane}) (name: svc: plane: {
        inherit name;
        domain = domainFor name svc plane;
      }) services;
      dupes = lib.filterAttrs (_: cs: lib.length cs > 1) (lib.groupBy (c: c.domain) claims);
    in
    lib.mapAttrsToList (domain: cs: {
      assertion = false;
      message = "fleet/services.nix: `${domain}` is claimed by ${lib.concatMapStringsSep " and " (c: "`${c.name}`") cs}.";
    }) dupes;

  # Backstop over the final merged list, so a generated row that duplicates a
  # hand-written one fails too. Exact match only: a wildcard overlapping a
  # generated name isn't flagged, and needn't be, since AdGuard prefers exact.
  mergedRewriteAssertions =
    rows:
    let
      dupes = lib.filterAttrs (_: rs: lib.length rs > 1) (lib.groupBy (r: r.domain) rows);
    in
    lib.mapAttrsToList (domain: rs: {
      assertion = false;
      message = "AdGuard rewrites: `${domain}` appears ${toString (lib.length rs)} times — generated (fleet/services.nix) and hand-written rows collide.";
    }) dupes;
}
