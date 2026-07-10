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
      example = "https://arcane.memory-alpha.zjones.dev";
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
      default = "ghcr.io/getarcaneapp/arcane-headless:v2.3.2";
      description = ''
        Pinned Arcane agent image. As of v2.3.2 the published manifest only
        covers amd64 + riscv64 — arm64 support exists in newer `next`
        pre-release builds but hasn't reached a stable tag yet (confirmed by
        inspecting the GHCR manifest list directly, not assumed). Any
        aarch64 host needs a build that actually publishes an arm64 variant;
        re-check before pointing a Pi-class host at a pinned tag here.
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
