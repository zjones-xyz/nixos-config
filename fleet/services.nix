# ── Fleet singleton-service registry ─────────────────────────────────────────
# One entry per single-host service, rendered into galactica's AdGuard
# rewrites by fleet/lib.nix. Planes (documented in modules/nixos/fleet.nix):
# internal and private default on, public (`.xyz`, via Pangolin) off; scope
# defaults to "host". Wildcard groups (*.maker, read.*, *.3dp) stay hand-written.
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
    planes.public = true;
    note = "Own single-name LE cert in traefik.nix; .xyz via Newt on memory-alpha.";
  };

  # The two dashboards (hosts/galactica/homepages.nix). `home` is the admin
  # one, deliberately Tailscale/LAN-only with no `.xyz` name.
  home = flatOnGalactica;
  guest = flatOnGalactica // {
    planes.public = true;
  };

  # One Traefik router pair each, in the same-named hosts/galactica/*.nix.
  ferdium = flatOnGalactica;
  karakeep = flatOnGalactica;
  paperless = flatOnGalactica;
  syncthing = flatOnGalactica;
  memos = flatOnGalactica;
}
