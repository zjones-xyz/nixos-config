{ config, pkgs, lib, ... }:

let
  cfg = config.services.adguardhomeSync;

  indexedReplicas = lib.imap0 (i: r: r // { idx = i; }) cfg.replicas;

  # Real passwords are never written here — this template only carries
  # ${VAR}-style placeholders, substituted by envsubst (real environment
  # variables, not shell text substitution) into a runtime-only (tmpfs)
  # copy by the unit's script. envsubst deliberately replaces an earlier
  # sed-based approach: sed's replacement text treats `&`/`\` as special,
  # so any password containing one would be silently corrupted rather than
  # inserted verbatim.
  # Replicas with useCookieAuth get a session cookie instead of
  # username/password — GL.iNet's patched AdGuard rejects HTTP Basic Auth,
  # which is the only auth method adguardhome-sync's own client sends when
  # username/password are set.
  # Deliberately conservative about what syncs: rewrites, filter lists, and
  # client names are the only things this repo actually declares for
  # galactica's AdGuard. dns.serverConfig/dhcp.* stay off since a replica
  # (e.g. the router) has its own upstream/DHCP needs that shouldn't be
  # overwritten by origin's.
  configTemplate = pkgs.writeText "adguardhome-sync-config.yaml.tmpl" ''
    cron: "${cfg.cron}"
    runOnStart: true

    api:
      port: ${toString cfg.port}

    origin:
      url: ${cfg.originUrl}
      username: "${cfg.originUsername}"
      password: "''${ORIGIN_PASSWORD}"

    replicas:
    ${lib.concatMapStrings (r:
      if r.useCookieAuth then ''
        - url: ${r.url}
          cookie: "''${REPLICA_${toString r.idx}_COOKIE}"
      '' else ''
        - url: ${r.url}
          username: "${r.username}"
          password: "''${REPLICA_${toString r.idx}_PASSWORD}"
      ''
    ) indexedReplicas}

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

  # network_mode: host — required, not cosmetic. Under the default bridge
  # network, 127.0.0.1 inside the container is the container's own loopback,
  # not the host's, so originUrl's default (127.0.0.1:3000, this host's own
  # AdGuard) is unreachable without it. Confirmed live: first deploy without
  # this failed every sync with "connection refused" on the origin.
  composeFile = pkgs.writeText "adguardhome-sync-compose.yml" ''
    services:
      adguardhome-sync:
        image: ${cfg.image}
        container_name: adguardhome-sync
        restart: unless-stopped
        network_mode: host
        command: run --config /config/adguardhome-sync.yaml
        volumes:
          - /run/adguardhome-sync/config.yaml:/config/adguardhome-sync.yaml:ro
  '';

  # Names of the env vars envsubst substitutes, passed as its own restrict-list
  # so it touches only these tokens and leaves any stray `${...}` elsewhere in
  # the rendered YAML (there shouldn't be any, but be defensive) untouched.
  envVarNames = [ "ORIGIN_PASSWORD" ] ++
    map (r: if r.useCookieAuth then "REPLICA_${toString r.idx}_COOKIE" else "REPLICA_${toString r.idx}_PASSWORD") indexedReplicas;
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
          useCookieAuth = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Log into this replica via POST /control/login at sync startup and
              use the resulting session cookie instead of HTTP Basic Auth.
              Needed for GL.iNet's patched AdGuard build, which accepts the
              browser login flow but returns 401 for Basic Auth even with
              correct credentials (confirmed live). Stock AdGuard Home
              replicas (e.g. a future hopper/hamilton) don't need this.
            '';
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
      default = 8090;
      description = ''
        Port for adguardhome-sync's own status API (config.yaml `api.port`).
        Default deliberately isn't the upstream default of 8080 — with
        network_mode: host this shares the whole host's port space, and 8080
        collides with SABnzbd on hosts running nixflix (confirmed live).
        With no networking.firewall.allowedTCPPorts entry for it, the host
        firewall blocks LAN access by default; use an SSH tunnel to check
        sync status.
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
        export ORIGIN_PASSWORD="$(cat ${cfg.originPasswordFile})"
        ${lib.concatMapStrings (r:
          if r.useCookieAuth then ''
            login_body=$(${pkgs.jq}/bin/jq -n --arg name '${r.username}' --arg password "$(cat ${r.passwordFile})" '{name:$name,password:$password}')
            login_headers=$(${pkgs.curl}/bin/curl -s -D - -o /dev/null -X POST '${r.url}/control/login' -H 'Content-Type: application/json' -d "$login_body")
            export REPLICA_${toString r.idx}_COOKIE="$(printf '%s' "$login_headers" | grep -i '^set-cookie:' | head -1 | sed -E 's/^[Ss]et-[Cc]ookie: *([^;]+);.*/\1/' | tr -d '\r')"
            [ -n "$REPLICA_${toString r.idx}_COOKIE" ] || { echo "login to replica ${r.url} failed" >&2; exit 1; }
          '' else ''
            export REPLICA_${toString r.idx}_PASSWORD="$(cat ${r.passwordFile})"
          ''
        ) indexedReplicas}
        ${pkgs.gettext}/bin/envsubst '${lib.concatMapStringsSep " " (n: "$" + n) envVarNames}' \
          < ${configTemplate} > /run/adguardhome-sync/config.yaml
        unset ORIGIN_PASSWORD ${lib.concatMapStringsSep " " (r: if r.useCookieAuth then "REPLICA_${toString r.idx}_COOKIE" else "REPLICA_${toString r.idx}_PASSWORD") indexedReplicas}
        exec ${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name adguardhome-sync up --remove-orphans
      '';
    };
  };
}
