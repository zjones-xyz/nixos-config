{
  config,
  pkgs,
  lib,
  ...
}:

# Part-DB — electronic component inventory. Single container, SQLite.
# Appdata restored from the old Unraid backup — see MANUAL-STEPS.md §16.
# `*.maker.{internal,zjones.dev}` grouping: tsdproxy rejects dotted names
# (`partdb.maker` fails RFC 1123 validation, confirmed empirically), so the
# tailnet name stays flat while Traefik/DNS get the subdomain grouping.

let
  image = "jbtronics/part-db1:2.17.0";
  dataDir = "/tank/appdata/partdb";
  port = 3023;
  publicDomain = "maker.zjones.dev";
  domains = [
    {
      main = publicDomain;
      sans = [ "*.${publicDomain}" ];
    }
  ];
in
{
  # Signs cookies/CSRF tokens — required, upstream ships no default.
  sops.secrets."partdb/appSecret" = { };
  sops.templates."partdb.env".content = ''
    APP_SECRET=${config.sops.placeholder."partdb/appSecret"}
  '';

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 root root - -"
    "d ${dataDir}/uploads 0750 root root - -"
    "d ${dataDir}/public_media 0750 root root - -"
    "d ${dataDir}/db 0750 root root - -"
  ];

  # tank's crypttab entries are all `nofail` (configuration.nix) — see
  # ferdium.nix's comment for why this matters.
  systemd.services.docker-partdb.unitConfig.RequiresMountsFor = [ dataDir ];

  virtualisation.oci-containers.containers.partdb = {
    inherit image;
    environment = {
      DATABASE_URL = "sqlite:///%kernel.project_dir%/var/db/app.db";
      APP_ENV = "docker";
      # NOT set: DATABASE_SQLITE_ENFORCE_FOREIGN_KEYS — upstream's own
      # warning is "only enable on a fresh database", and this one is
      # restored, not fresh.
    };
    environmentFiles = [ config.sops.templates."partdb.env".path ];
    volumes = [
      "${dataDir}/uploads:/var/www/html/uploads"
      "${dataDir}/public_media:/var/www/html/public/media"
      "${dataDir}/db:/var/www/html/var/db"
    ];
    ports = [ "127.0.0.1:${toString port}:80" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "partdb";
      "tsdproxy.port.1" = "443/https:${toString port}/http";
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      partdb = {
        rule = "Host(`partdb.maker.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "partdb-svc";
      };
      "partdb-dev" = {
        rule = "Host(`partdb.maker.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls = {
          certResolver = "letsencrypt";
          inherit domains;
        };
        service = "partdb-svc";
      };
    };
    services.partdb-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
