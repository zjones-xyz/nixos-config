{
  config,
  pkgs,
  lib,
  ...
}:

# Karakeep — bookmark/archive manager. Three containers (web, a headless
# Chrome for archiving pages, Meilisearch for full-text search), same shape
# as the upstream docker-compose.yml: https://github.com/karakeep-app/karakeep
#
# The three need to resolve each other by container name, which the default
# Docker bridge does not provide — hence the dedicated `karakeep` network,
# same pattern as traefik-galactica.nix's `proxy` network for the socket
# proxy. Appdata restored from the old Unraid backup — see MANUAL-STEPS.md
# §15 (dataDir is its own ZFS dataset, not a directory in the shared
# tank/appdata).

let
  webImage = "ghcr.io/karakeep-app/karakeep:0.33.2";
  chromeImage = "ghcr.io/karakeep-app/karakeep-chrome:151.0.7922.47-r1";
  meiliImage = "getmeili/meilisearch:v1.41.0";
  dataDir = "/tank/appdata/karakeep";
  port = 3021;
in
{
  # NEXTAUTH_SECRET signs session tokens; MEILI_MASTER_KEY authenticates the
  # web/worker processes against Meilisearch — both required, and must differ
  # from each other.
  sops.secrets."karakeep/nextAuthSecret" = { };
  sops.secrets."karakeep/meiliMasterKey" = { };

  sops.templates."karakeep.env".content = ''
    NEXTAUTH_SECRET=${config.sops.placeholder."karakeep/nextAuthSecret"}
    MEILI_MASTER_KEY=${config.sops.placeholder."karakeep/meiliMasterKey"}
  '';

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 root root - -"
    "d ${dataDir}/data 0750 root root - -"
    "d ${dataDir}/meilisearch 0750 root root - -"
  ];

  # `docker network create` isn't declarative — same oneshot shape as
  # traefik-galactica.nix's docker-proxy-network.
  systemd.services.docker-karakeep-network = {
    description = "Create the karakeep container network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = [
      "docker-karakeep-web.service"
      "docker-karakeep-chrome.service"
      "docker-karakeep-meilisearch.service"
    ];
    requiredBy = [
      "docker-karakeep-web.service"
      "docker-karakeep-chrome.service"
      "docker-karakeep-meilisearch.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${config.virtualisation.docker.package}/bin/docker network inspect karakeep >/dev/null 2>&1 || ${config.virtualisation.docker.package}/bin/docker network create karakeep'";
    };
  };

  # tank's crypttab entries are all `nofail` (configuration.nix) — a degraded
  # boot with the array unimported is a real state on this host, and without
  # this docker.service would start these anyway against empty bind-mount
  # sources. Same pattern as nixflix.nix/bazarr.nix. karakeep-chrome doesn't
  # touch tank, so it's not listed here.
  systemd.services.docker-karakeep-web.unitConfig.RequiresMountsFor = [ "${dataDir}/data" ];
  systemd.services.docker-karakeep-meilisearch.unitConfig.RequiresMountsFor = [
    "${dataDir}/meilisearch"
  ];

  virtualisation.oci-containers.containers = {
    karakeep-web = {
      image = webImage;
      environment = {
        MEILI_ADDR = "http://karakeep-meilisearch:7700";
        BROWSER_WEB_URL = "http://karakeep-chrome:9222";
        DATA_DIR = "/data"; # DON'T CHANGE — see the upstream compose's own warning
        NEXTAUTH_URL = "https://karakeep.zjones.dev";
        # Locked down — see MANUAL-STEPS.md §15.
        DISABLE_SIGNUPS = "true";
      };
      environmentFiles = [ config.sops.templates."karakeep.env".path ];
      volumes = [ "${dataDir}/data:/data" ];
      ports = [ "127.0.0.1:${toString port}:3000" ];
      extraOptions = [ "--network=karakeep" ];
      labels = {
        "tsdproxy.enable" = "true";
        "tsdproxy.name" = "karakeep";
        "tsdproxy.port.1" = "443/https:${toString port}/http";
      };
    };

    karakeep-chrome = {
      image = chromeImage;
      extraOptions = [
        "--network=karakeep"
        "--init"
      ];
      cmd = [
        "--disable-gpu"
        "--disable-dev-shm-usage"
        "--hide-scrollbars"
        "--disable-blink-features=AutomationControlled"
        "--window-size=1440,900"
      ];
    };

    karakeep-meilisearch = {
      image = meiliImage;
      environment.MEILI_NO_ANALYTICS = "true";
      environmentFiles = [ config.sops.templates."karakeep.env".path ];
      volumes = [ "${dataDir}/meilisearch:/meili_data" ];
      extraOptions = [ "--network=karakeep" ];
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      karakeep = {
        rule = "Host(`karakeep.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "karakeep-svc";
      };
      "karakeep-dev" = {
        rule = "Host(`karakeep.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "karakeep-svc";
      };
    };
    services.karakeep-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
