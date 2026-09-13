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
# Consumption folder is deliberately NOT under tank/documents (nor the old
# bundled `.../consumption`, nor `tank/sort/inbox/paperless-consumption`):
# owner's call, scans land in `/inbox/paperless` on the NVMe root instead —
# fast, and dropped files are consumed (moved into `data`/`media` under
# tank/documents, which IS backed up) within moments, so the inbox itself
# needs neither ZFS redundancy nor offsite coverage. NFS-exported now; SMB
# is planned but not built yet.

let
  webImage = "ghcr.io/paperless-ngx/paperless-ngx:3.1.3";
  brokerImage = "valkey/valkey:9.1-alpine";
  liveDir = "/tank/documents/paperless"; # already exists — do not tmpfiles this
  brokerDataDir = "/tank/appdata/paperless";
  inboxDir = "/inbox/paperless"; # NVMe root, not tank — see header
  port = 3022;
  uid = toString config.users.users.z.uid;
  gid = toString config.users.groups.${config.users.users.z.group}.gid;
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

  # Only the broker's dir and the new inbox — the live paperless
  # data/media/export dirs under tank/documents already exist with real
  # content and whatever ownership the old setup left them with; tmpfiles
  # has no business touching that (see the USERMAP_UID/GID note below for
  # the one thing that DOES need reconciling there).
  systemd.tmpfiles.rules = [
    "d ${brokerDataDir} 0750 root root - -"
    "d /inbox 0755 root root - -"
    "d ${inboxDir} 0770 ${uid} ${gid} - -"
  ];

  # NFS export for the inbox — LAN-wide since no specific client is known
  # yet (same reasoning as bambuddy_library in configuration.nix's export
  # table). `async` rather than the fleet's usual `sync`: this share
  # explicitly trades durability for speed (header above), and forcing a
  # sync on every write would undercut the one property it exists for.
  services.nfs.server.exports = ''
    ${inboxDir}  192.168.8.0/24(rw,async,no_subtree_check,fsid=105)
  '';

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
        # Matches user z on the host, so the container can actually write
        # into the NFS-exported /inbox/paperless. ⚠ Not previously set (this
        # image defaults to a baked-in 1000:1000), so the pre-existing
        # tank/documents/paperless tree needs a one-time chown to match —
        # MANUAL-STEPS.md §15 carries it.
        USERMAP_UID = uid;
        USERMAP_GID = gid;
      };
      environmentFiles = [ config.sops.templates."paperless.env".path ];
      volumes = [
        "${liveDir}/data:/usr/src/paperless/data"
        "${liveDir}/media:/usr/src/paperless/media"
        "${liveDir}/export:/usr/src/paperless/export"
        "${inboxDir}:/usr/src/paperless/consume"
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
