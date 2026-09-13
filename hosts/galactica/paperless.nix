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
# NOT a migration target like ferdium/karakeep: `/tank/documents/paperless`
# is already a live, populated instance (real db.sqlite3 + archived
# documents) — the Unraid `appdata` share's own paperless folder was only
# 9K of leftover container config. `tank/documents` already carries
# `org.torsion.borgmatic:backup=auto` (Critical tier, BACKUP-BORG.md), so
# this data is offsite-covered with no extra tagging. Only the broker's own
# transient queue state lives under `tank/appdata` — Celery scratch state,
# not documents, and fine at the default "painful to rebuild, small,
# no offsite" appdata tier (SHARES.md).
#
# ⚠ Consumption folder is provisional: pointed at the existing
# `/tank/documents/paperless/consumption` (same one the live instance
# already had) rather than the newer `/tank/sort/inbox/paperless-consumption`
# — confirm which one is meant to be the go-forward drop folder before first
# switch and adjust if it's the latter.

let
  webImage = "ghcr.io/paperless-ngx/paperless-ngx:3.1.3";
  brokerImage = "valkey/valkey:9.1-alpine";
  liveDir = "/tank/documents/paperless"; # already exists — do not tmpfiles this
  brokerDataDir = "/tank/appdata/paperless";
  port = 3022;
in
{
  # SECRET_KEY signs sessions/CSRF tokens — required, upstream ships no
  # default. Rotating it only invalidates existing sessions; it does not
  # touch document data. The admin account env vars only ever create the
  # user once — they will NOT touch or reset whatever admin account already
  # exists in the live db.sqlite3 from the old Unraid setup. If you remember
  # that account's original credentials, use those; PAPERLESS_ADMIN_USER
  # below is only a fallback in case the restored DB turns out to have no
  # superuser. Neither secret exists yet: MANUAL-STEPS.md carries generating
  # and `sops`-ing them in before the first switch (a referenced key missing
  # from secrets/galactica.yaml fails activation, not eval).
  sops.secrets."paperless/secretKey" = { };
  sops.secrets."paperless/adminPassword" = { };

  sops.templates."paperless.env".content = ''
    PAPERLESS_SECRET_KEY=${config.sops.placeholder."paperless/secretKey"}
    PAPERLESS_ADMIN_USER=z
    PAPERLESS_ADMIN_PASSWORD=${config.sops.placeholder."paperless/adminPassword"}
    PAPERLESS_ADMIN_MAIL=zoejonestx91@gmail.com
  '';

  # Only the broker's own dir — the live paperless data/media/export/
  # consumption dirs under tank/documents already exist with real content
  # and whatever ownership the old setup left them with; tmpfiles has no
  # business touching that.
  systemd.tmpfiles.rules = [ "d ${brokerDataDir} 0750 root root - -" ];

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
      volumes = [ "${brokerDataDir}/redis:/data" ];
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
        "${liveDir}/data:/usr/src/paperless/data"
        "${liveDir}/media:/usr/src/paperless/media"
        "${liveDir}/export:/usr/src/paperless/export"
        "${liveDir}/consumption:/usr/src/paperless/consume"
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
