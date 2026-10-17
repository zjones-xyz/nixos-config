{
  config,
  pkgs,
  lib,
  ...
}:

# Spoolman — 3D-printer filament spool inventory. Single container, SQLite.
# Appdata restored from the old Unraid backup — see MANUAL-STEPS.md §16.
# `*.maker.{internal,zjones.dev}` grouping — see partdb.nix's header for why
# the tsdproxy tailnet name stays flat instead of matching.
#
# ⚠ No authentication at all, by upstream design (not a gap to fix here) —
# owner's call to leave it behind tsdproxy/Traefik only for now; add a
# Traefik BasicAuth middleware later if that changes.
#
# Upstream's own install docs: the image runs as a fixed, non-configurable
# uid 1000 and require `chown 1000:1000` on the host data dir — matches
# user z's uid (pinned in configuration.nix), so this isn't a coincidence
# the way ferdium/karakeep's uid match was before that fix.

let
  image = "ghcr.io/donkie/spoolman:0.26.1";
  dataDir = "/tank/appdata/spoolman";
  port = 3025;
  publicDomain = "maker.zjones.dev";
  domains = [
    {
      main = publicDomain;
      sans = [ "*.${publicDomain}" ];
    }
  ];
  uid = toString config.users.users.z.uid;
  gid = toString config.users.groups.${config.users.users.z.group}.gid;
in
{
  systemd.tmpfiles.rules = [ "d ${dataDir} 0750 ${uid} ${gid} - -" ];

  systemd.services.docker-spoolman.unitConfig.RequiresMountsFor = [ dataDir ];

  virtualisation.oci-containers.containers.spoolman = {
    inherit image;
    environment.TZ = config.time.timeZone;
    volumes = [ "${dataDir}:/home/app/.local/share/spoolman" ];
    ports = [ "127.0.0.1:${toString port}:8000" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "spoolman";
      "tsdproxy.port.1" = "443/https:${toString port}/http";
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      spoolman = {
        rule = "Host(`spoolman.maker.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "spoolman-svc";
      };
      "spoolman-dev" = {
        rule = "Host(`spoolman.maker.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls = {
          certResolver = "letsencrypt";
          inherit domains;
        };
        service = "spoolman-svc";
      };
    };
    services.spoolman-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
