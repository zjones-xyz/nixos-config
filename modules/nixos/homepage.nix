{ config, pkgs, lib, ... }:

{
  # Homepage — service dashboard. Native NixOS module
  # (services.homepage-dashboard). Fronted by Traefik at hopper.internal root.
  services.homepage-dashboard = {
    enable = true;
    listenPort = 8082;
    # Homepage refuses requests whose Host header isn't allowed when behind a
    # proxy; list the hostnames Traefik will forward.
    allowedHosts = "hopper.internal,home.hopper.internal,hopper.zjones.dev,home.hopper.zjones.dev";

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

    # ⟨Follow-up: add galactica's media stack as a third group.⟩ Those nine
    # services went live 2026-09-04 behind their own Traefik
    # (modules/nixos/traefik-galactica.nix) and are reachable now, so the
    # entries would be purely additive `href`s — no `allowedHosts` change,
    # since that option is about the hostnames Traefik forwards *to this
    # dashboard*, not the ones it links out to:
    #
    #   prowlarr, sonarr, sonarr-anime, radarr, lidarr,
    #   navidrome, sabnzbd, qbittorrent   — all at https://<name>.arr.internal
    #                                       (and .arr.zjones.dev)
    #
    # Deliberately not added yet: hopper is backburnered and has not been
    # switched, so this whole module is declared but not serving. Adding links
    # to a dashboard nobody can load is bookkeeping, not progress — and the
    # URLs are stable, so it costs nothing to defer. hosts/galactica/
    # MANUAL-STEPS.md §12 step 5 carries the same list.
    #
    # ⚠ Homepage's *arr widgets (live queue/activity rather than plain links)
    # are a bigger ask than they look: each needs that service's API key, which
    # means putting galactica's sops secrets on hopper. Not worth it for a link
    # list — decide separately if the live status is actually wanted.

    widgets = [
      { resources = { cpu = true; memory = true; disk = "/"; }; }
    ];
  };
}
