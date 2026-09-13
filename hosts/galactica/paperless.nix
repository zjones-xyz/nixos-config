{
  config,
  pkgs,
  lib,
  ...
}:

# Paperless-ngx — document management. Two containers (webserver + a Valkey
# broker for its Celery task queue), same shape as upstream's
# docker-compose.sqlite.yml. SQLite, not Postgres: this is a single-user
# instance and the sqlite compose is upstream's own recommended minimal
# deployment.
#
# Appdata migration from Unraid is deferred — see ferdium.nix's header for
# why; this starts on a fresh database. The `consume` directory below is
# real and live from day one regardless: it's how the owner feeds it new
# scans, not migrated state.

let
  webImage = "ghcr.io/paperless-ngx/paperless-ngx:3.1.3";
  brokerImage = "valkey/valkey:9.1-alpine";
  dataDir = "/tank/appdata/paperless";
  port = 3022;
in
{
  # SECRET_KEY signs sessions/CSRF tokens — required, upstream ships no
  # default. The admin account env vars only ever create the user once (they
  # don't touch an existing one), so headless bring-up is safe to leave in
  # place for the life of the container. None of the three exist yet:
  # MANUAL-STEPS.md carries generating and `sops`-ing them in before the
  # first switch (a referenced key missing from secrets/galactica.yaml fails
  # activation, not eval).
  sops.secrets."paperless/secretKey" = { };
  sops.secrets."paperless/adminPassword" = { };

  sops.templates."paperless.env".content = ''
    PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless/secretKey"}
    PAPERLESS_ADMIN_USER=z
    PAPERLESS_ADMIN_PASSWORD=${config.sops.placeholder."paperless/adminPassword"}
    PAPERLESS_ADMIN_MAIL=zoejonestx91@gmail.com
  '';

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 root root - -"
    "d ${dataDir}/data 0750 root root - -"
    "d ${dataDir}/media 0750 root root - -"
    "d ${dataDir}/export 0750 root root - -"
    "d ${dataDir}/consume 0750 root root - -"
    "d ${dataDir}/redis 0750 root root - -"
  ];

  # Same reasoning as karakeep.nix's dedicated network: the webserver needs
  # to resolve `paperless-broker` by name, which the default bridge won't do.
  systemd.services.docker-paperless-network = {
    description = "Create the paperless container network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = [
      "docker-paperless-webserver.service"
      "docker-paperless-broker.service"
    ];
    requiredBy = [
      "docker-paperless-webserver.service"
      "docker-paperless-broker.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${config.virtualisation.docker.package}/bin/docker network inspect paperless >/dev/null 2>&1 || ${config.virtualisation.docker.package}/bin/docker network create paperless'";
    };
  };

  virtualisation.oci-containers.containers = {
    paperless-broker = {
      image = brokerImage;
      volumes = [ "${dataDir}/redis:/data" ];
      extraOptions = [ "--network=paperless" ];
    };

    paperless-webserver = {
      image = webImage;
      environment = {
        PAPERLESS_REDIS = "redis://paperless-broker:6379";
        PAPERLESS_DBENGINE = "sqlite";
        PAPERLESS_URL = "https://paperless.zjones.dev";
      };
      environmentFiles = [ config.sops.templates."paperless.env".path ];
      volumes = [
        "${dataDir}/data:/usr/src/paperless/data"
        "${dataDir}/media:/usr/src/paperless/media"
        "${dataDir}/export:/usr/src/paperless/export"
        "${dataDir}/consume:/usr/src/paperless/consume"
      ];
      ports = [ "127.0.0.1:${toString port}:8000" ];
      extraOptions = [ "--network=paperless" ];
      labels = {
        "tsdproxy.enable" = "true";
        "tsdproxy.name" = "paperless";
        "tsdproxy.port.1" = "443/https:${toString port}/http";
      };
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      paperless = {
        rule = "Host(`paperless.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "paperless-svc";
      };
      "paperless-dev" = {
        rule = "Host(`paperless.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "paperless-svc";
      };
    };
    services.paperless-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
