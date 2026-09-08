# ── Fleet host registry ──────────────────────────────────────────────────────
# Pure data: host name → { ip; certAnchors; traefik; }. This is the single
# source of truth dns.nix derives `clients.persistent` from and fleet/lib.nix
# derives service rewrites from — see modules/nixos/fleet.nix for the option
# shim that exposes it as `config.homelab.fleet.hosts`.
#
# `certAnchors` are the domain(s) each host's Traefik module requests a
# wildcard/anchor cert for (traefik.nix, traefik-galactica.nix,
# traefik-local.nix) — informational today, input to Phase 2/3 Traefik
# generation. `traefik` is the deployment shape ("compose" | "native"),
# also informational until Traefik generation lands.
#
# hamilton is deliberately absent: not yet deployed, no known IP (same
# reasoning as the commented-out line in dns.nix's clients.persistent).
{
  router = {
    ip = "192.168.8.1";
  };

  hopper = {
    ip = "192.168.8.10";
    certAnchors = [ "hopper.zjones.dev" ];
  };

  pegasus = {
    ip = "192.168.8.72";
  };

  memory-alpha-2 = {
    ip = "192.168.8.98";
  };

  memory-alpha = {
    ip = "192.168.8.99";
    certAnchors = [ "memory-alpha.zjones.dev" "monitor.zjones.dev" ];
    traefik = "compose";
  };

  homeassistant = {
    ip = "192.168.8.142";
  };

  galactica = {
    ip = "192.168.8.190";
    certAnchors = [ "arr.zjones.dev" ];
    traefik = "native";
  };

  towerbmc = {
    ip = "192.168.8.191";
  };
}
