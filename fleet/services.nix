# ── Fleet singleton-service registry ─────────────────────────────────────────
# One entry per service that lives on exactly one host. fleet/lib.nix turns
# each into AdGuard rewrites on galactica, the rewrite origin.
# modules/nixos/fleet.nix types it and fills the defaults: scope "host"
# (name.<host>.internal), planes internal+dev on, xyz off, splitHorizon on.
# `.xyz` is Pangolin-terminated — a LAN rewrite only.
# Wildcard groups (*.maker, read.*, *.3dp) can't be expressed here yet.
let
  flatOnGalactica = {
    host = "galactica";
    scope = "flat";
  };
in
{
  jellyfin = {
    host = "memory-alpha";
    scope = "flat";
    # No jellyfin.internal router exists yet; turning this on is Phase 3.
    planes.internal = false;
    planes.xyz = true;
    note = "Own single-name LE cert in traefik.nix; .xyz via Newt on memory-alpha.";
  };

  # The two dashboards (hosts/galactica/homepages.nix). `home` is the admin
  # one, deliberately Tailscale/LAN-only with no `.xyz` name.
  home = flatOnGalactica;
  guest = flatOnGalactica // {
    planes.xyz = true;
  };

  # One Traefik router pair each, in the same-named hosts/galactica/*.nix.
  ferdium = flatOnGalactica;
  karakeep = flatOnGalactica;
  paperless = flatOnGalactica;
  syncthing = flatOnGalactica;
  memos = flatOnGalactica;
}
