{ config, pkgs, lib, ... }:

let
  cfg = config.services.beszelAgent;

  # Agent-only Beszel unit. Deliberately NOT modules/nixos/beszel.nix — that file
  # is hopper's own hub+agent bundle (hardcoded `beszel.hopper.internal` Traefik
  # hostnames, a dependency on hopper's docker-proxy-network/traefik-docker units,
  # and the rootless `/run/user/1000/docker.sock`). Importing it elsewhere would
  # stand up a second, redundant hub. This module is just the agent: report this
  # host's metrics to the hub hopper already runs.
  #
  # Same compose-file-in-systemd shape the rest of the fleet uses
  # (arcane-agent.nix, dockge.nix, beszel.nix) rather than virtualisation.oci-
  # containers, which the fleet doesn't use anywhere.
  #
  # Socket is the *rootful* daemon (`/run/docker.sock`) — hopper's beszel.nix
  # mounts the rootless `/run/user/1000/docker.sock` because hopper once ran
  # rootless, but every current NixOS host takes rootful Docker from common.nix
  # (`virtualisation.docker.enable = true`). Mounted read-only: the agent only
  # needs to *read* container stats, never control the daemon.
  composeFile = pkgs.writeText "beszel-agent-compose.yml" ''
    services:
      beszel-agent:
        image: ${cfg.image}
        container_name: beszel-agent
        restart: unless-stopped
        # Host network so the hub can reach the agent on cfg.port over the LAN
        # (the hub dials the agent in Beszel's default SSH/pull model), and so
        # the agent reads real host-level network/disk counters rather than a
        # container's namespaced view.
        network_mode: host
        volumes:
          - /run/docker.sock:/var/run/docker.sock:ro
        environment:
          - LISTEN=${toString cfg.port}
          # KEY = the hub's SSH *public* key, which authorises the hub to
          # connect and pull metrics. Injected from cfg.keyFile at runtime (see
          # the script below) so the key never lands in a world-readable store
          # path. HUB_URL is only consulted by Beszel's newer WebSocket/push
          # registration; harmless in the default pull model, and included so a
          # future switch to that model needs no compose edit.
          - KEY
          - HUB_URL=${cfg.hubUrl}
  '';
in
{
  options.services.beszelAgent = {
    enable = lib.mkEnableOption "Beszel agent reporting this host's metrics to a Beszel hub";

    hubUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://beszel.hopper.internal";
      description = ''
        URL of the Beszel hub this agent belongs to. The fleet's hub runs on
        hopper (modules/nixos/beszel.nix), fronted by Traefik at
        beszel.hopper.internal. Only read by Beszel's WebSocket/push
        registration; the default SSH/pull model ignores it, but it costs
        nothing to set correctly now.
      '';
    };

    keyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a decrypted secret file (e.g. a sops-nix secret path) whose
        entire contents are the hub's SSH *public* key — the raw `KEY` value,
        no `KEY=` prefix. This is what authorises the hub to connect to this
        agent. Obtained by registering this host as a new system in the hub's
        web UI, which prints the key to paste in. One value, shared by every
        agent the same hub manages.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 45876;
      description = ''
        Port the agent listens on for the hub's connection. Matches the fleet
        convention set by hopper's own agent (modules/nixos/beszel.nix).
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open cfg.port in the host firewall so the hub can reach the agent.
        List-merges with any other allowedTCPPorts, so it's safe alongside a
        host that already opens ports elsewhere.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "henrygd/beszel-agent:latest";
      description = ''
        Beszel agent OCI image. `:latest` matches hopper's existing hub+agent
        (modules/nixos/beszel.nix) so both ends of the fleet track the same
        release rather than drifting apart on a pinned tag.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.beszel-agent = {
      description = "Beszel monitoring agent";
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name beszel-agent down";
      };

      # KEY exported into the compose invocation's environment (compose's bare
      # `- KEY` above pulls it from here), same pattern as arcane-agent.nix's
      # AGENT_TOKEN — keeps the secret out of the compose file and the store.
      script = ''
        export KEY="$(cat ${cfg.keyFile})"
        exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name beszel-agent up --remove-orphans
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
