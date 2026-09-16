{
  config,
  pkgs,
  lib,
  ...
}:

# Paperless-ngx — document management. Two containers (webserver + a Valkey
# broker for its Celery task queue), same shape as upstream's
# docker-compose.sqlite.yml. NOT a migration target like ferdium/karakeep:
# `liveDir` below is an already-live, populated instance, not fresh state —
# see MANUAL-STEPS.md §15 and SHARES.md for the full reasoning (backup
# tiers, why the inbox lives on the NVMe root instead of tank).
#
# ⚠ `inboxDir` sits on the `@` btrfs subvolume, which IS hourly-snapshotted
# (modules/nixos/btrfs-snapshots.nix, up to 8 weeks retention) — "no ZFS
# redundancy or offsite" doesn't mean "no copies at all" for whatever's
# in-flight there.

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

  # Every crypttab entry for `tank` is `nofail` (configuration.nix) — a
  # degraded boot with the array unimported is a real, supported state on
  # this host, and without this, docker.service (only ordered `after`
  # local-fs.target, never blocked by it) would start these anyway. Same
  # pattern as nixflix.nix's serviceDependencies / bazarr.nix's
  # RequiresMountsFor — missing here would mean paperless-webserver runs its
  # migrations into a fresh empty database at the bind-mount source instead
  # of failing closed.
  systemd.services.docker-paperless-webserver.unitConfig.RequiresMountsFor = [
    liveDir
    brokerDataDir
  ];
  systemd.services.docker-paperless-broker.unitConfig.RequiresMountsFor = [ brokerDataDir ];

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
        # Django only trusts PAPERLESS_URL for CSRF by default — every other
        # name this is reachable under (paperless.internal, the tsdproxy
        # tailnet name) 403s on login otherwise, confirmed live. PROXY_SSL_HEADER
        # is needed alongside it: without it Django doesn't know the request
        # was HTTPS (Traefik terminates TLS and forwards plain HTTP), so
        # `request.is_secure()` is false and the trusted-origin check fails
        # regardless of the list above.
        PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.zjones.dev,https://paperless.internal,https://paperless.peacock-koi.ts.net";
        PAPERLESS_PROXY_SSL_HEADER = ''["HTTP_X_FORWARDED_PROTO", "https"]'';
        # Matches user z on the host, so the container can actually write
        # into the NFS-exported /inbox/paperless.
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
