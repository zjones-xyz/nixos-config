{ config, pkgs, lib, ... }:

let
  composeFile = pkgs.writeText "arcane-compose.yml" ''
    networks:
      proxy:
        external: true

    services:
      arcane:
        image: ghcr.io/getarcaneapp/manager:v2.3.2
        container_name: arcane
        restart: unless-stopped
        # Improves the manager's own container/resource self-detection.
        cgroup: host
        environment:
          - ENCRYPTION_KEY
          - JWT_SECRET
          - PROJECTS_DIRECTORY=/home/z/homelab-stacks/memory-alpha
          - TZ=America/Los_Angeles
        volumes:
          # Arcane manages containers/compose stacks directly, so — like
          # Dockge — it needs full read/write socket access, not the
          # read-only proxy Traefik uses.
          - "/run/docker.sock:/var/run/docker.sock"
          - "/home/z/arcane/data:/app/data"
          # Same stacks directory Dockge already manages (modules/nixos/dockge.nix)
          # rather than a second, divergent projects tree. Bind-mounted at the
          # same path on both sides: Arcane shells out to `docker compose`
          # against host paths for projects it manages, so the in-container
          # path must match the host path.
          - "/home/z/homelab-stacks/memory-alpha:/home/z/homelab-stacks/memory-alpha"
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.arcane.rule=Host(`arcane.memory-alpha.internal`)"
          - "traefik.http.routers.arcane.entrypoints=websecure"
          - "traefik.http.routers.arcane.tls=true"
          - "traefik.http.routers.arcane-dev.rule=Host(`arcane.memory-alpha.zjones.dev`)"
          - "traefik.http.routers.arcane-dev.entrypoints=websecure"
          - "traefik.http.routers.arcane-dev.tls.certresolver=letsencrypt"
          - "traefik.http.routers.arcane-dev.service=arcane"
          - "traefik.http.services.arcane.loadbalancer.server.port=3552"
  '';
in
{
  # No Traefik-level basic-auth in front of this one (unlike the Traefik
  # dashboard) — Arcane's own login (forces a password change off the
  # `admin`/`arcane-admin` default on first login) is the only auth layer.
  sops.secrets."arcane/encryptionKey".owner = "z";
  sops.secrets."arcane/jwtSecret".owner = "z";

  # Both hop through docker-proxy-network's `proxy` network, defined in
  # traefik.nix. List merging means this doesn't require editing that file.
  systemd.services.docker-proxy-network = {
    before = [ "arcane.service" ];
    requiredBy = [ "arcane.service" ];
  };

  systemd.services.arcane = {
    description = "Arcane Docker manager";
    after = [ "network-online.target" "docker.service" "docker-proxy-network.service" "traefik-docker.service" ];
    wants = [ "network-online.target" "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/arcane/data /home/z/homelab-stacks/memory-alpha && chown -R z:users /home/z/arcane /home/z/homelab-stacks'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name arcane down";
    };

    script = ''
      export ENCRYPTION_KEY="$(cat ${config.sops.secrets."arcane/encryptionKey".path})"
      export JWT_SECRET="$(cat ${config.sops.secrets."arcane/jwtSecret".path})"
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name arcane up --remove-orphans
    '';
  };
}
