{ config, pkgs, lib, ... }:

let
  composeFile = pkgs.writeText "traefik-compose.yml" ''
    networks:
      proxy:
        external: true

    services:
      traefik:
        image: traefik:v3
        container_name: traefik
        restart: unless-stopped
        command:
          - "--providers.docker=true"
          - "--providers.docker.exposedByDefault=false"
          - "--providers.docker.network=proxy"
          - "--entrypoints.web.address=:80"
          - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
          - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
          - "--entrypoints.websecure.address=:443"
          - "--entrypoints.websecure.http.middlewares=secure-headers@docker"
          - "--api.dashboard=true"
          - "--accesslog=true"
          - "--accesslog.format=json"
        ports:
          - "80:80"
          - "443:443"
        logging:
          driver: json-file
          options:
            max-size: "10m"
            max-file: "5"
        volumes:
          - "/run/user/1000/docker.sock:/var/run/docker.sock:ro"
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.traefik.rule=Host(`traefik.memory-alpha.internal`)"
          - "traefik.http.routers.traefik.entrypoints=websecure"
          - "traefik.http.routers.traefik.tls=true"
          - "traefik.http.services.traefik.loadbalancer.server.port=8080"
          - "traefik.http.middlewares.secure-headers.headers.frameDeny=true"
          - "traefik.http.middlewares.secure-headers.headers.contentTypeNosniff=true"
          - "traefik.http.middlewares.secure-headers.headers.referrerPolicy=strict-origin-when-cross-origin"
          - "traefik.http.middlewares.secure-headers.headers.browserXssFilter=true"
  '';
in
{
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Rootless Docker can't bind ports < 1024 by default; lower the threshold
  # so Traefik can publish 80/443. ip_forward is needed for bridge networking.
  boot.kernel.sysctl = {
    "net.ipv4.ip_unprivileged_port_start" = 80;
    "net.ipv4.ip_forward" = 1;
  };

  # Single owner for the shared `proxy` network. Both Traefik and Dockge
  # reference it as `external: true`, avoiding compose project-ownership
  # conflicts that caused Traefik to ignore its own container.
  systemd.services.docker-proxy-network = {
    description = "Create shared Docker proxy network";
    after = [ "user@1000.service" ];
    wants = [ "user@1000.service" ];
    before = [ "traefik-docker.service" "dockge.service" ];
    requiredBy = [ "traefik-docker.service" "dockge.service" ];

    environment.DOCKER_HOST = "unix:///run/user/1000/docker.sock";

    serviceConfig = {
      User = "z";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.docker}/bin/docker network inspect proxy >/dev/null 2>&1 || ${pkgs.docker}/bin/docker network create proxy'";
    };
  };

  systemd.services.traefik-docker = {
    description = "Traefik reverse proxy";
    after = [ "network-online.target" "user@1000.service" "docker-proxy-network.service" ];
    wants = [ "network-online.target" "user@1000.service" ];
    wantedBy = [ "multi-user.target" ];

    environment.DOCKER_HOST = "unix:///run/user/1000/docker.sock";

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name traefik down";
    };

    script = ''
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name traefik up --remove-orphans
    '';
  };
}
