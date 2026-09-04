{ config, pkgs, lib, ... }:

let
  cfg = config.services.beszelAgent;

  # Agent-only Beszel unit. Deliberately NOT modules/nixos/beszel.nix — that
  # file is an old hopper-shaped hub+agent bundle; the fleet's Beszel hub
  # actually runs as a Docker stack on memory-alpha (homelab-stacks
  # memory-alpha/monitoring), reachable at beszel.monitor.zjones.dev. This
  # module is just the agent: report this host's metrics to that hub.
  #
  # Config mirrors memory-alpha's own working beszel-agent (that compose is the
  # source of truth for the current Beszel model): host network + LISTEN, plus
  # KEY (the hub's shared public key) AND TOKEN (this host's per-agent
  # registration token) AND HUB_URL. The agent listens on cfg.port for the
  # hub's pull, and registers itself via the token/hub_url path — both wired,
  # matching what memory-alpha runs.
  #
  # Same compose-file-in-systemd shape the rest of the fleet uses
  # (arcane-agent.nix, dockge.nix). Socket is the rootful daemon
  # (`/run/docker.sock`), mounted read-only — the agent only reads container
  # stats. The data volume persists the agent's identity across restarts.
  composeFile = pkgs.writeText "beszel-agent-compose.yml" ''
    services:
      beszel-agent:
        image: ${cfg.image}
        container_name: beszel-agent
        restart: unless-stopped
        security_opt:
          - no-new-privileges:true
        # Host network: real host-level counters (not a container's namespaced
        # view) and the agent listens on cfg.port over the LAN for the hub.
        network_mode: host
        volumes:
          - /run/docker.sock:/var/run/docker.sock:ro
          - ${cfg.dataDir}:/var/lib/beszel-agent
        environment:
          - LISTEN=${toString cfg.port}
          # KEY = the hub's shared public key; TOKEN = this host's per-agent
          # registration token. Both injected from their sops secret files at
          # runtime (see the script) so neither lands in a world-readable store
          # path. HUB_URL is where the agent registers itself.
          - KEY
          - TOKEN
          - HUB_URL=${cfg.hubUrl}
  '';
in
{
  options.services.beszelAgent = {
    enable = lib.mkEnableOption "Beszel agent reporting this host's metrics to the fleet Beszel hub";

    hubUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://beszel.monitor.zjones.dev";
      description = ''
        URL of the Beszel hub this agent registers with. The fleet's hub runs
        as a Docker stack on memory-alpha (homelab-stacks memory-alpha/
        monitoring), fronted by Traefik at beszel.monitor.zjones.dev.
      '';
    };

    keyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a decrypted secret file (e.g. a sops-nix secret path) whose
        contents are the hub's shared public KEY value (no `KEY=` prefix). One
        value shared by every agent the same hub manages; shown by the hub's
        "Add system" dialog.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a decrypted secret file whose contents are this host's per-agent
        registration TOKEN (no prefix), generated per-host by the hub's "Add
        system" dialog alongside the shared KEY.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/beszel-agent";
      description = "Host path persisting the agent's state across restarts.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 45876;
      description = ''
        Port the agent listens on for the hub's connection. Matches the fleet
        convention (memory-alpha's own agent listens here too).
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open cfg.port so the hub can reach the agent. List-merges with any other allowedTCPPorts.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "henrygd/beszel-agent:latest";
      description = ''
        Beszel agent OCI image. `:latest` matches the memory-alpha hub+agent so
        both ends of the fleet track the same release rather than drifting apart.
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
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${cfg.dataDir}";
        ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name beszel-agent down";
      };

      # KEY/TOKEN exported into the compose invocation's environment (compose's
      # bare `- KEY`/`- TOKEN` pull them from here), same pattern as
      # arcane-agent.nix's AGENT_TOKEN — keeps both secrets out of the store.
      script = ''
        export KEY="$(cat ${cfg.keyFile})"
        export TOKEN="$(cat ${cfg.tokenFile})"
        exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name beszel-agent up --remove-orphans
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
