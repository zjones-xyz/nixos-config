{ config, pkgs, lib, ... }:

let
  cfg = config.services.arcaneAgent;

  composeFile = pkgs.writeText "arcane-agent-compose.yml" ''
    services:
      arcane-agent:
        image: ${cfg.image}
        container_name: arcane-agent
        restart: unless-stopped
        environment:
          - EDGE_AGENT=true
          - EDGE_TRANSPORT=auto
          - MANAGER_API_URL=${cfg.managerUrl}
          - AGENT_TOKEN
        volumes:
          - "/run/docker.sock:/var/run/docker.sock"
  '';
in
{
  options.services.arcaneAgent = {
    enable = lib.mkEnableOption "Arcane remote agent (edge mode: dials out to the manager, no inbound ports required)";

    managerUrl = lib.mkOption {
      type = lib.types.str;
      # Defaults to the fleet manager (modules/nixos/arcane.nix on memory-alpha,
      # behind Traefik), so an agent host normally sets only enable + tokenFile —
      # same shape as beszel-agent.nix's hubUrl. Overridable per host.
      default = "https://arcane.monitor.zjones.dev";
      description = "URL of the Arcane manager this agent reports to.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a decrypted secret file (e.g. a sops-nix secret path) whose
        entire contents are the raw AGENT_TOKEN value — no `KEY=` prefix.
        Generated per-host from the manager's Settings -> Environments page
        after Phase 1's manager is live; one token per agent host.
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/getarcaneapp/arcane-headless:v2.10.1";
      description = ''
        Pinned Arcane agent image. Keep this in lockstep with memory-alpha's
        manager tag (modules/nixos/arcane.nix) — the edge-agent protocol tracks
        the manager release, so a mismatched agent can fail to attach. As of
        v2.10.1 the manifest publishes arm64 alongside amd64 (the old v2.3.2
        amd64/riscv64-only limitation is gone), so Pi-class hosts can share this
        tag; still re-check the GHCR manifest before pinning a new tag.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.arcane-agent = {
      description = "Arcane remote agent";
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name arcane-agent down";
      };

      script = ''
        export AGENT_TOKEN="$(cat ${cfg.tokenFile})"
        exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name arcane-agent up --remove-orphans
      '';
    };
  };
}
