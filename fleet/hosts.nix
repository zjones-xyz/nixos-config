# ── Fleet address registry ───────────────────────────────────────────────────
# Fixed LAN addresses that need a name, not just NixOS hosts: devices (router,
# BMC) and containers (bambuddy) too. dns.nix makes each an AdGuard client name;
# fleet/lib.nix resolves a service's `host` (fleet/services.nix) to its IP
# here, so that should be the machine that serves its names. hamilton is
# paused; its address stays reserved.
{
  router.ip = "192.168.8.1";
  hopper.ip = "192.168.8.10";
  hamilton.ip = "192.168.8.11";
  pegasus.ip = "192.168.8.72";
  bambuddy.ip = "192.168.8.98"; # container on memory-alpha (bambuddy.nix)
  memory-alpha.ip = "192.168.8.99";
  homeassistant.ip = "192.168.8.142";
  galactica.ip = "192.168.8.190";
  towerbmc.ip = "192.168.8.191";
}
