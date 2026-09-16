{
  config,
  pkgs,
  lib,
  ...
}:

# HomeBox — home inventory tracker. Single container, SQLite.
# Appdata restored from the old Unraid backup — see MANUAL-STEPS.md §16.
# `*.maker.{internal,zjones.dev}` grouping — see partdb.nix's header for why
# the tsdproxy tailnet name stays flat instead of matching.

let
  image = "ghcr.io/sysadminsmedia/homebox:0.26.2";
  dataDir = "/tank/appdata/homebox";
  port = 3024;
  publicDomain = "maker.zjones.dev";
  domains = [
    {
      main = publicDomain;
      sans = [ "*.${publicDomain}" ];
    }
  ];
in
{
  systemd.tmpfiles.rules = [ "d ${dataDir} 0750 root root - -" ];

  systemd.services.docker-homebox.unitConfig.RequiresMountsFor = [ dataDir ];

  virtualisation.oci-containers.containers.homebox = {
    inherit image;
    environment = {
      HBOX_DATABASE_DRIVER = "sqlite3";
      HBOX_DATABASE_DATABASE = "/data/homebox.db?_pragma=busy_timeout=2000&_pragma=journal_mode=WAL&_fk=1&_time_format=sqlite";
    };
    volumes = [ "${dataDir}:/data" ];
    ports = [ "127.0.0.1:${toString port}:7745" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "homebox";
      "tsdproxy.port.1" = "443/https:${toString port}/http";
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      homebox = {
        rule = "Host(`homebox.maker.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "homebox-svc";
      };
      "homebox-dev" = {
        rule = "Host(`homebox.maker.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls = {
          certResolver = "letsencrypt";
          inherit domains;
        };
        service = "homebox-svc";
      };
    };
    services.homebox-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
