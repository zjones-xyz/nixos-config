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
          # Dockge manages stacks, so it needs full read/write socket access
          # (unlike Traefik, which goes through the read-only socket proxy).
          - /run/docker.sock:/var/run/docker.sock
          - /home/z/dockge/data:/app/data
          - /home/z/homelab-stacks/memory-alpha:/opt/stacks
          # NixOS stores docker in the Nix store, not at a standard path.
          # Dockge spawns `docker compose` as a child process and needs the
          # binary visible inside the container at a standard PATH location.
          - ${pkgs.docker}/bin/docker:/usr/local/bin/docker:ro
        environment:
          - DOCKGE_STACKS_DIR=/opt/stacks
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.dockge.rule=Host(`dockge.memory-alpha.internal`)"
          - "traefik.http.routers.dockge.entrypoints=websecure"
          - "traefik.http.routers.dockge.tls=true"
          - "traefik.http.routers.dockge-dev.rule=Host(`dockge.memory-alpha.zjones.dev`)"
          - "traefik.http.routers.dockge-dev.entrypoints=websecure"
          - "traefik.http.routers.dockge-dev.tls.certresolver=letsencrypt"
          - "traefik.http.routers.dockge-dev.service=dockge"
          - "traefik.http.services.dockge.loadbalancer.server.port=5001"
  '';
in
{
  # Dockge resolves relative paths in managed compose files against its
  # internal stacks dir (/opt/stacks). When Docker creates bind-mount source
  # directories via the socket it uses that same path on the HOST — so
  # /opt/stacks must exist and point at the real stacks directory.
  systemd.tmpfiles.rules = [
    "d /opt        0755 root root -"
    "L /opt/stacks -    -    -    - /home/z/homelab-stacks/memory-alpha"
  ];

  systemd.services.dockge = {
    description = "Dockge Docker compose manager";
    after = [ "network-online.target" "docker.service" "docker-proxy-network.service" "traefik-docker.service" ];
    wants = [ "network-online.target" "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      # Create bind-mount source dirs as z before the container starts.
      # `+` runs the command as root so it can mkdir under /home/z and chown.
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/dockge/data /home/z/homelab-stacks/memory-alpha && chown -R z:users /home/z/dockge /home/z/homelab-stacks'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name dockge down";
    };

    script = ''
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name dockge up --remove-orphans
    '';
  };
}
