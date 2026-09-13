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
          # ⚠ The collector's cron runs UTC without this, so a schedule written
          # as local time fires hours off with nothing to show for it
          # (arcane.nix and speedtest-tracker.nix set TZ for the same reason).
          # Follows the host's own time.timeZone rather than a second hardcoded
          # copy; UTC when that is unset, which is the container's own default.
          - TZ=${if config.time.timeZone == null then "UTC" else config.time.timeZone}
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

        ⚠ `memory-alpha.internal` resolves via an AdGuard rewrite on the LAN's
        DNS host, so this inherits that dependency: if DNS is down the
        collector cannot resolve the hub. It retries on the next cron tick,
        and missing a day of SMART history is not an incident.
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
      description = ''
        Collector cron schedule. Upstream's default is daily at midnight, and
        the container now reads it in the host's timezone (see the TZ line in
        the compose above) rather than UTC.

        Each run sweeps every block device, so on a host that parks disks this
        is a guaranteed daily spin-up — worth placing next to whatever else
        already wakes them. galactica's PLATFORM.md §13e has the reasoning.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      # ⚠ Must match the RUNNING hub, which is v0.9.3-omnibus — not the
      # master-omnibus its compose file claims (memory-alpha's monitoring stack
      # has drifted from homelab-stacks). A master collector against a v0.9.3
      # hub POSTs its device list, gets accepted, and silently collects nothing.
      # Re-check the hub's actual tag (docker ps) before bumping this.
      default = "ghcr.io/analogj/scrutiny:v0.9.3-collector";
      description = "Collector image, pinned to match the running Scrutiny hub.";
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
        ExecStop = "${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name scrutiny-collector down";
      };

      script = ''
        exec ${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name scrutiny-collector up --remove-orphans
      '';
    };
  };
}
