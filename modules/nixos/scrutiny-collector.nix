{ config, pkgs, lib, ... }:

let
  cfg = config.services.scrutinyCollector;

  # Collector-only. The fleet's Scrutiny hub is the omnibus container on
  # memory-alpha (homelab-stacks memory-alpha/monitoring), which publishes its
  # API on 0.0.0.0:8080 specifically so remote collectors can POST straight to
  # it — deliberately NOT via Traefik, whose dashboard-auth basicauth sits in
  # front of the web routes and would reject the collector.
  #
  # Same compose-file-in-systemd shape as beszel-agent.nix / arcane-agent.nix.
  composeFile = pkgs.writeText "scrutiny-collector-compose.yml" ''
    services:
      scrutiny-collector:
        image: ${cfg.image}
        container_name: scrutiny-collector
        restart: unless-stopped
        # privileged rather than an enumerated `devices:` list. Upstream's
        # example names each disk (--device=/dev/sda …), which is wrong for this
        # fleet: sdX letters are not stable across reboots or recabling — a
        # thing galactica has already demonstrated — so an enumerated list
        # silently monitors the wrong disks, or none. privileged exposes every
        # block device, which is what the Unraid-era tower/monitoring compose
        # did for the same reason. SYS_RAWIO is SMART access; SYS_ADMIN is
        # required on top of it for NVMe.
        privileged: true
        cap_add:
          - SYS_RAWIO
          - SYS_ADMIN
        volumes:
          - /run/udev:/run/udev:ro
        environment:
          # ⚠ COLLECTOR_API_ENDPOINT, *not* SCRUTINY_API_ENDPOINT (which is what
          # homelab-stacks/hopper/README.md claims). The wrong name is accepted
          # silently and the collector then reports nothing — verified against
          # upstream's own hub-and-spoke docs before writing this.
          - COLLECTOR_API_ENDPOINT=${cfg.apiEndpoint}
          - COLLECTOR_CRON_SCHEDULE=${cfg.cronSchedule}
          # Without this every node reports under the container's hostname and
          # the hub cannot tell whose disks are whose.
          - COLLECTOR_HOST_ID=${cfg.hostId}
  '';
in
{
  options.services.scrutinyCollector = {
    enable = lib.mkEnableOption "Scrutiny SMART collector reporting this host's disks to the fleet Scrutiny hub";

    apiEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://memory-alpha.internal:8080";
      description = ''
        Scrutiny hub API. Plain HTTP on the LAN port, bypassing Traefik — the
        hub's web routes carry dashboard-auth basicauth, which the collector
        cannot satisfy.

        ⚠ `memory-alpha.internal` resolves via the AdGuard rewrite on hopper, so
        this inherits that dependency: if hopper is down the collector cannot
        resolve the hub. It retries on the next cron tick, and missing a day of
        SMART history is not an incident.
      '';
    };

    hostId = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Name this host reports as in the Scrutiny UI.";
    };

    cronSchedule = lib.mkOption {
      type = lib.types.str;
      default = "0 0 * * *";
      description = "Collector cron schedule (upstream default: daily at midnight).";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/analogj/scrutiny:master-collector";
      description = ''
        Collector image. `master-collector` to match the hub's
        `master-omnibus` tag, so both ends track the same release.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.scrutiny-collector = {
      description = "Scrutiny SMART collector";
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name scrutiny-collector down";
      };

      script = ''
        exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name scrutiny-collector up --remove-orphans
      '';
    };
  };
}
