# ── Fleet singleton-service registry ─────────────────────────────────────────
# Pure data: service name → where it lives and which DNS planes it answers on.
# fleet/lib.nix's `rewritesFor` turns this into AdGuard rewrite rows;
# modules/nixos/fleet.nix exposes it as `config.homelab.fleet.services` and
# fills in the submodule defaults documented below (scope "host", planes
# internal/dev on, xyz off, splitHorizon on).
#
#   host          — must be a key of fleet/hosts.nix
#   scope         — "flat": name.internal / name.zjones.dev / name.zjones.xyz
#                   "host" (default): name.host.internal / name.host.zjones.dev / …
#   planes        — internal (self-signed, Traefik) / dev (LE, Traefik) /
#                   xyz (Pangolin/Newt tunnel, split-horizon only — see below)
#   splitHorizon  — whether the `.xyz` LAN rewrite row is emitted at all for
#                   this service; ANDed with the fleet-wide
#                   homelab.dns.splitHorizon kill switch in fleet/lib.nix.
#   note          — free text, not consumed by any generator.
{
  jellyfin = {
    host = "memory-alpha";
    scope = "flat";
    # ⚠ internal = false is deliberate: jellyfin.internal does not exist
    # today (only jellyfin.zjones.dev/.xyz are routed — traefik.nix has no
    # .internal router for it). Flipping this to true is the Phase-3 change
    # that adds that route; until then this registry must stay a rewrite-
    # table no-op against what galactica's configuration.nix already had.
    planes = {
      internal = false;
      dev = true;
      xyz = true;
    };
    note = ''
      Flat name, not *.memory-alpha.zjones.dev — Traefik (modules/nixos/traefik.nix,
      on memory-alpha) already routes jellyfin.zjones.dev with its own single-name
      LE cert; the rewrite was the only missing piece. jellyfin.zjones.xyz is the
      split-horizon shortcut for the Pangolin-tunneled public name (Newt runs on
      memory-alpha, newt.nix) — LAN clients bypass the tunnel, not a second route.
    '';
  };

  guesthome = {
    host = "galactica";
    scope = "flat";
    planes = {
      internal = false;
      dev = false;
      xyz = true;
    };
    note = ''
      .xyz only, like jellyfin — split-horizon shortcut for the Pangolin-tunneled
      public name, LAN clients hit galactica directly instead of round-tripping
      through the tunnel. No .internal/.zjones.dev route exists for this name.
    '';
  };
}
