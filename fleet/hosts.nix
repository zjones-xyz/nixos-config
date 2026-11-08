# ── Fleet host registry ──────────────────────────────────────────────────────
# Pure data, exposed as `homelab.fleet.hosts` by modules/nixos/fleet.nix.
# dns.nix derives AdGuard's `clients.persistent` from it; fleet/lib.nix
# resolves each service's host to an IP. IP only for now — Traefik fields
# (cert anchors, deployment shape) land with the phase that consumes them.
# hamilton is paused, but its address is reserved so it can rejoin as-is.
{
  router.ip = "192.168.8.1";
  hopper.ip = "192.168.8.10";
  hamilton.ip = "192.168.8.11";
  pegasus.ip = "192.168.8.72";
  memory-alpha-2.ip = "192.168.8.98";
  memory-alpha.ip = "192.168.8.99";
  homeassistant.ip = "192.168.8.142";
  galactica.ip = "192.168.8.190";
  towerbmc.ip = "192.168.8.191";
}
