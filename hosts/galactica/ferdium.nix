{
  config,
  pkgs,
  lib,
  ...
}:

# Ferdium-server — recipe/account backend for the Ferdium desktop client.
#
# Appdata migration from the old Unraid `appdata` share is DEFERRED: nobody
# has done the per-container inventory pass on `tank/backups/sidepool-pools`
# yet (SHARES.md still flags that as outstanding), so this starts on a fresh
# SQLite database. MANUAL-STEPS.md carries the restore as a follow-up once
# the old data is located.
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

  virtualisation.oci-containers.containers.ferdium = {
    inherit image;
    environment = {
      NODE_ENV = "production";
      APP_URL = "https://ferdium.zjones.dev";
      DB_CONNECTION = "sqlite";
      DATA_DIR = "/data";
      JWT_USE_PEM = "true";
      # Registration stays open until the owner has created an account on
      # this fresh database — an empty DB with signups off can never be
      # logged into. MANUAL-STEPS.md has the follow-up to flip this once
      # done.
      IS_REGISTRATION_ENABLED = "true";
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
