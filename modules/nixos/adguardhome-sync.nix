{ config, pkgs, lib, ... }:

let
  cfg = config.services.adguardhomeSync;

  indexedReplicas = lib.imap0 (i: r: r // { idx = i; }) cfg.replicas;

  # Real passwords are never written here — this template only carries
  # placeholder tokens, substituted into a runtime-only (tmpfs) copy by the
  # unit's script. Deliberately conservative about what syncs: rewrites,
  # filter lists, and client names are the only things this repo actually
  # declares for galactica's AdGuard. dns.serverConfig/dhcp.* stay off since
  # a replica (e.g. the router) has its own upstream/DHCP needs that
  # shouldn't be overwritten by origin's.
  configTemplate = pkgs.writeText "adguardhome-sync-config.yaml.tmpl" ''
    cron: "${cfg.cron}"
    runOnStart: true

    origin:
      url: ${cfg.originUrl}
      username: ${cfg.originUsername}
      password: "@ORIGIN_PASSWORD@"

    replicas:
    ${lib.concatMapStrings (r: ''
      - url: ${r.url}
        username: ${r.username}
        password: "@REPLICA_${toString r.idx}_PASSWORD@"
    '') indexedReplicas}

    features:
      dns:
        rewrites: true
        accessLists: false
        serverConfig: false
      filters:
        blacklist: true
        whitelist: true
        userRules: true
      clientSettings: true
      generalSettings: false
      services: false
      dhcp:
        serverConfig: false
        staticLeases: false
      theme: false
      tlsConfig: false
  '';

  composeFile = pkgs.writeText "adguardhome-sync-compose.yml" ''
    services:
      adguardhome-sync:
        image: ${cfg.image}
        container_name: adguardhome-sync
        restart: unless-stopped
        command: run --config /config/adguardhome-sync.yaml
        ports:
          - "127.0.0.1:${toString cfg.port}:8080"
        volumes:
          - /run/adguardhome-sync/config.yaml:/config/adguardhome-sync.yaml:ro
  '';

  # sed with `|` as the delimiter — passwords must not contain `|`.
  sedArgs = lib.concatMapStringsSep " " (r:
    ''-e "s|@REPLICA_${toString r.idx}_PASSWORD@|$(cat ${r.passwordFile})|"''
  ) indexedReplicas;
in
{
  options.services.adguardhomeSync = {
    enable = lib.mkEnableOption "AdGuardHome-Sync, replicating this host's AdGuard config to replica instances";

    originUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:3000";
      description = "URL of the origin AdGuard Home instance (this host's own, by default).";
    };

    originUsername = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Admin username for the origin AdGuard Home instance.";
    };

    originPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a decrypted secret file (sops-nix) holding the origin admin's plaintext password.";
    };

    replicas = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Replica AdGuard Home URL, e.g. http://192.168.8.1:3000.";
          };
          username = lib.mkOption {
            type = lib.types.str;
            default = "admin";
            description = "Replica admin username.";
          };
          passwordFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to a decrypted secret file holding the replica admin's plaintext password.";
          };
        };
      });
      default = [ ];
      description = "Replica AdGuard Home instances to sync this host's config to.";
    };

    cron = lib.mkOption {
      type = lib.types.str;
      default = "*/10 * * * *";
      description = "Cron schedule for sync runs.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/bakito/adguardhome-sync:v0.9.2";
      description = "adguardhome-sync OCI image, pinned.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port for adguardhome-sync's own status web UI. Bound to loopback only
        (127.0.0.1) — nothing on the LAN needs this; use an SSH tunnel to
        check sync status.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.adguardhome-sync = {
      description = "AdGuardHome-Sync";
      after = [ "network-online.target" "docker.service" "adguardhome.service" ];
      wants = [ "network-online.target" "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStop = "${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name adguardhome-sync down";
      };

      script = ''
        set -euo pipefail
        install -d -m 0700 /run/adguardhome-sync
        sed \
          -e "s|@ORIGIN_PASSWORD@|$(cat ${cfg.originPasswordFile})|" \
          ${sedArgs} \
          ${configTemplate} > /run/adguardhome-sync/config.yaml
        exec ${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name adguardhome-sync up --remove-orphans
      '';
    };
  };
}
