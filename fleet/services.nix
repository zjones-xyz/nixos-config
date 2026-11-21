# ── Fleet singleton-service registry ─────────────────────────────────────────
# One entry per single-host service, rendered into galactica's AdGuard
# rewrites by fleet/lib.nix. Defaults (modules/nixos/fleet.nix): scope "host",
# planes internal+dev on, xyz off. `.xyz` is Pangolin-terminated, so it's a
# LAN shortcut only. Wildcard groups (*.maker, read.*, *.3dp) stay hand-written.
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
