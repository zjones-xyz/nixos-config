{
  config,
  pkgs,
  lib,
  ...
}:

# Memos — self-hosted note/memo server (https://github.com/usememos/memos).
# No nixpkgs module for the server, hence a container — same shape as
# ferdium.nix: loopback-only publish, fronted by Traefik, with its own
# tsdproxy tailnet node. SQLite-backed, single container, no secret needed
# (no signing-key env var upstream).

let
  image = "neosmemo/memos:0.31.0";
  dataDir = "/tank/appdata/memos";
  port = 3026; # next free loopback slot after spoolman.nix's 3025
in
{
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 root root - -"
  ];

  # tank's crypttab entries are all `nofail` (configuration.nix) — a degraded
  # boot with the array unimported is a real state on this host, and without
  # this docker.service would start the container anyway against an empty
  # bind-mount source. Same pattern as nixflix.nix/bazarr.nix.
  systemd.services.docker-memos.unitConfig.RequiresMountsFor = [ dataDir ];

  virtualisation.oci-containers.containers.memos = {
    inherit image;
    volumes = [ "${dataDir}:/var/opt/memos" ];
    # Loopback only — reached through Traefik (LAN/zjones.dev) or tsdproxy
    # (tailnet), same as every other dashboard-shaped container on this host.
    ports = [ "127.0.0.1:${toString port}:5230" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "memos";
      "tsdproxy.port.1" = "443/https:${toString port}/http";
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      memos = {
        rule = "Host(`memos.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "memos-svc";
      };
      "memos-dev" = {
        rule = "Host(`memos.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "memos-svc";
      };
    };
    services.memos-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
