{ config, pkgs, lib, ... }:

let
  composeFile = pkgs.writeText "dockge-compose.yml" ''
    networks:
      proxy:
        external: true

    services:
      dockge:
        image: louislam/dockge:1
        container_name: dockge
        restart: unless-stopped
        volumes:
          - /run/user/1000/docker.sock:/var/run/docker.sock
          - /home/z/dockge/data:/app/data
          - /home/z/stacks:/opt/stacks
        environment:
          - DOCKGE_STACKS_DIR=/opt/stacks
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.dockge.rule=Host(`dockge.memory-alpha.internal`)"
          - "traefik.http.routers.dockge.entrypoints=websecure"
          - "traefik.http.routers.dockge.tls=true"
          - "traefik.http.services.dockge.loadbalancer.server.port=5001"
  '';
in
{
  systemd.services.dockge = {
    description = "Dockge Docker compose manager";
    after = [ "network-online.target" "user@1000.service" "docker-proxy-network.service" "traefik-docker.service" ];
    wants = [ "network-online.target" "user@1000.service" ];
    wantedBy = [ "multi-user.target" ];

    environment.DOCKER_HOST = "unix:///run/user/1000/docker.sock";

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      # Create bind-mount source dirs as z before the container starts.
      # `+` runs the command as root so it can mkdir under /home/z and chown.
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/dockge/data /home/z/stacks && chown -R z:users /home/z/dockge /home/z/stacks'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name dockge down";
    };

    script = ''
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name dockge up --remove-orphans
    '';
  };
}
