# ── Fleet address registry ───────────────────────────────────────────────────
# Every fixed LAN address, not just NixOS hosts: devices (router, BMC) and
# containers (bambuddy) too. Each becomes an AdGuard client name (dns.nix);
# a service's `host` in fleet/services.nix should be the machine that actually
# serves its names. hamilton is paused; its address stays reserved.
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
