{ config, pkgs, lib, ... }:

let
  # No native NixOS module for Beszel, so run the hub + agent as Docker
  # containers managed by a systemd unit — same shape as the dockge module.
  # The hub UI is exposed via Traefik labels on the proxy network; the agent
  # reports this host's metrics to the hub over the internal network.
  composeFile = pkgs.writeText "beszel-compose.yml" ''
    networks:
      proxy:
        external: true

    services:
      beszel:
        image: henrygd/beszel:latest
        container_name: beszel
        restart: unless-stopped
        volumes:
          - /home/z/beszel/data:/beszel_data
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.beszel.rule=Host(`beszel.hopper.internal`)"
          - "traefik.http.routers.beszel.entrypoints=websecure"
          - "traefik.http.routers.beszel.tls=true"
          - "traefik.http.routers.beszel-dev.rule=Host(`beszel.hopper.zjones.dev`)"
          - "traefik.http.routers.beszel-dev.entrypoints=websecure"
          - "traefik.http.routers.beszel-dev.tls.certresolver=letsencrypt"
          - "traefik.http.routers.beszel-dev.service=beszel"
          - "traefik.http.services.beszel.loadbalancer.server.port=8090"

      beszel-agent:
        image: henrygd/beszel-agent:latest
        container_name: beszel-agent
        restart: unless-stopped
        network_mode: host
        volumes:
          - /run/user/1000/docker.sock:/var/run/docker.sock:ro
        environment:
          - LISTEN=45876
        # KEY = the hub's public key; stored in secrets/hopper.yaml as a
        # `KEY=ssh-ed25519 ...` line and injected here at runtime.
        env_file:
          - ${config.sops.secrets."beszel/agentKey".path}
  '';
in
{
  sops.secrets."beszel/agentKey".owner = "z";

  systemd.services.beszel = {
    description = "Beszel monitoring (hub + agent)";
    after = [ "network-online.target" "user@1000.service" "docker-proxy-network.service" "traefik-docker.service" ];
    wants = [ "network-online.target" "user@1000.service" ];
    wantedBy = [ "multi-user.target" ];

    environment.DOCKER_HOST = "unix:///run/user/1000/docker.sock";

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/beszel/data && chown -R z:users /home/z/beszel'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name beszel down";
    };

    script = ''
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name beszel up --remove-orphans
    '';
  };

  # Agent listen port (host network) reachable on the tailnet.
  networking.firewall.allowedTCPPorts = [ 45876 ];
}
