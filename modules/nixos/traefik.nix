{ config, pkgs, lib, ... }:

let
  composeFile = pkgs.writeText "traefik-compose.yml" ''
    networks:
      proxy:
        name: proxy
        driver: bridge

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

  systemd.services.traefik-docker = {
    description = "Traefik reverse proxy";
    after = [ "network-online.target" "user@1000.service" ];
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
