{
  config,
  pkgs,
  lib,
  ...
}:

# Ferdium-server — recipe/account backend for the Ferdium desktop client.
#
# Appdata restored from the old Unraid backup — see MANUAL-STEPS.md §15 for
# the restore record (dataDir is its own ZFS dataset, not a directory in the
# shared tank/appdata).
#
# No nixpkgs module exists for the server component (only the desktop
# Electron client is packaged), hence a container — same shape as the
# homepage dashboards (homepages.nix): loopback-only publish, fronted by
# Traefik, with its own tsdproxy tailnet node.

let
  image = "ferdium/ferdium-server:2.0.13";
  dataDir = "/tank/appdata/ferdium";
  port = 3020; # next free loopback slot after homepages.nix's 3010/3011
in
{
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 root root - -"
    "d ${dataDir}/recipes 0750 root root - -"
  ];

  # tank's crypttab entries are all `nofail` (configuration.nix) — a degraded
  # boot with the array unimported is a real state on this host, and without
  # this docker.service would start the container anyway against an empty
  # bind-mount source. Same pattern as nixflix.nix/bazarr.nix.
  systemd.services.docker-ferdium.unitConfig.RequiresMountsFor = [ dataDir ];

  virtualisation.oci-containers.containers.ferdium = {
    inherit image;
    environment = {
      NODE_ENV = "production";
      APP_URL = "https://ferdium.zjones.dev";
      DB_CONNECTION = "sqlite";
      DATA_DIR = "/data";
      JWT_USE_PEM = "true";
      # Locked down — see MANUAL-STEPS.md §15.
      IS_REGISTRATION_ENABLED = "false";
      IS_CREATION_ENABLED = "true";
      IS_DASHBOARD_ENABLED = "true";
      CONNECT_WITH_FRANZ = "false";
    };
    volumes = [
      "${dataDir}:/data"
      "${dataDir}/recipes:/app/build/recipes"
    ];
    # Loopback only — reached through Traefik (LAN/zjones.dev) or tsdproxy
    # (tailnet), same as every other dashboard-shaped container on this host.
    ports = [ "127.0.0.1:${toString port}:3333" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "ferdium";
      "tsdproxy.port.1" = "443/https:${toString port}/http";
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      ferdium = {
        rule = "Host(`ferdium.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "ferdium-svc";
      };
      "ferdium-dev" = {
        rule = "Host(`ferdium.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "ferdium-svc";
      };
    };
    services.ferdium-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
