# ── Fleet registry generators ────────────────────────────────────────────────
# Pure functions over fleet/hosts.nix + fleet/services.nix shapes (or their
# config.homelab.fleet.* equivalents, once submodule defaults are applied).
# No NixOS module machinery here — modules/nixos/fleet.nix wires these into
# actual options/assertions, dns.nix calls `rewritesFor` directly.
{ lib }:

rec {
  # FQDN for one (service, plane) pair. "flat" services own a bare name
  # (jellyfin.internal); "host"-scoped ones are namespaced under their host
  # (name.host.internal) so two services with the same short name on
  # different hosts can't collide.
  domainFor =
    { name, host, scope, plane }:
    let
      suffix = {
        internal = "internal";
        dev = "zjones.dev";
        xyz = "zjones.xyz";
      }.${plane};
    in
    if scope == "flat" then "${name}.${suffix}" else "${name}.${host}.${suffix}";

  # Every (service, enabled plane) pair a service *could* emit, ignoring the
  # splitHorizon gate — used by the uniqueness assertion, which must catch a
  # collision regardless of whether split-horizon happens to be on right now.
  rowsFor =
    services:
    lib.flatten (
      lib.mapAttrsToList (
        name: svc:
        map
          (plane: {
            inherit name plane;
            domain = domainFor {
              inherit name plane;
              inherit (svc) host;
              scope = svc.scope or "host";
            };
          })
          (lib.filter (p: svc.planes.${p} or false) [ "internal" "dev" "xyz" ])
      ) services
    );

  # AdGuard rewrite rows for the whole registry, sorted by domain.
  rewritesFor =
    { hosts, services, splitHorizonGlobal }:
    let
      rowFor =
        name: svc: plane:
        {
          domain = domainFor {
            inherit name plane;
            inherit (svc) host;
            scope = svc.scope or "host";
          };
          answer = hosts.${svc.host}.ip;
        };

      xyzEnabled = svc: (svc.splitHorizon or true) && splitHorizonGlobal;

      rowsForService =
        name: svc:
        lib.optional (svc.planes.internal or false) (rowFor name svc "internal")
        ++ lib.optional (svc.planes.dev or false) (rowFor name svc "dev")
        ++ lib.optional ((svc.planes.xyz or false) && xyzEnabled svc) (rowFor name svc "xyz");

      unsorted = lib.flatten (lib.mapAttrsToList rowsForService services);
      sorted = lib.sort (a: b: a.domain < b.domain) unsorted;
    in
    # `enabled = true` MUST be added here, inside the generator — AdGuard's
    # per-rewrite enable toggle renders Go's zero-value `false` when omitted,
    # silently disabling the rewrite (the same trap galactica's hand-written
    # list works around in dns.nix's header comment).
    map (r: r // { enabled = true; }) sorted;

  # ── Assertions (NixOS `assertions` shape: { assertion; message; }) ────────
  # Wired into modules/nixos/fleet.nix's `config.assertions`. NixOS's own
  # top-level module throws — naming every failing message — the moment
  # `config.system.build.toplevel` is forced, which is exactly what CI's
  # per-host `nix eval …toplevel.drvPath` does.
  hostAssertions =
    { hosts, services }:
    lib.mapAttrsToList (name: svc: {
      assertion = hosts ? ${svc.host};
      message = "fleet/services.nix: service '${name}' references unknown host '${svc.host}' — add it to fleet/hosts.nix or fix the typo.";
    }) services;

  uniqueDomainAssertions =
    { services }:
    let
      rows = rowsFor services;
      byDomain = lib.groupBy (r: r.domain) rows;
      dupes = lib.filterAttrs (_: rs: lib.length rs > 1) byDomain;
    in
    lib.mapAttrsToList (domain: rs: {
      assertion = false;
      message = "fleet: duplicate DNS name '${domain}' claimed by both '${lib.concatMapStringsSep "' and '" (r: r.name) rs}'";
    }) dupes;
}
