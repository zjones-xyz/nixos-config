{ config, pkgs, lib, ... }:

{
  # Homepage — service dashboard. Native NixOS module
  # (services.homepage-dashboard). Fronted by Traefik at hopper.internal root.
  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    # Homepage refuses requests whose Host header isn't allowed when behind a
    # proxy; list the hostnames Traefik will forward.
    allowedHosts = "hopper.internal,home.hopper.internal";

    settings = {
      title = "hopper";
      headerStyle = "clean";
    };

    # Declarative dashboard config. Flesh these out as services settle.
    services = [
      {
        "Network" = [
          { "AdGuard Home" = { href = "https://adguard.hopper.internal"; description = "DNS filtering"; }; }
          { "Uptime Kuma" = { href = "https://kuma.hopper.internal"; description = "Uptime monitoring"; }; }
        ];
      }
      {
        "Infra" = [
          { "Beszel" = { href = "https://beszel.hopper.internal"; description = "System metrics"; }; }
          { "Speedtest" = { href = "https://speedtest.hopper.internal"; description = "Speedtest tracker"; }; }
          { "ntfy" = { href = "https://ntfy.hopper.internal"; description = "Notifications"; }; }
        ];
      }
    ];

    widgets = [
      { resources = { cpu = true; memory = true; disk = "/"; }; }
    ];
  };
}
