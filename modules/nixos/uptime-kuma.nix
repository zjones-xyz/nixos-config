{ config, pkgs, lib, ... }:

{
  # Uptime Kuma — status/uptime monitoring. Native NixOS module.
  # State lives in /var/lib/uptime-kuma; first-run setup is via the web UI.
  # Fronted by Traefik (kuma.hopper.internal); not opened on the LAN firewall.
  services.uptime-kuma = {
    enable = true;
    settings = {
      HOST = "127.0.0.1";
      PORT = "3001";
    };
  };
}
