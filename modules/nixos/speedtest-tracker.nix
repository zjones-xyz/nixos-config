{ config, pkgs, lib, ... }:

let
  # No native NixOS module for speedtest-tracker, so run it as a Docker
  # container managed by a systemd unit — same shape as the dockge module.
  composeFile = pkgs.writeText "speedtest-tracker-compose.yml" ''
    networks:
      proxy:
        external: true

    services:
      speedtest-tracker:
        image: lscr.io/linuxserver/speedtest-tracker:latest
        container_name: speedtest-tracker
        restart: unless-stopped
        environment:
          - PUID=1000
          - PGID=100
          - TZ=America/Los_Angeles
          - APP_URL=https://speedtest.hopper.internal
          - DB_CONNECTION=sqlite
          - SPEEDTEST_SCHEDULE=0 */6 * * *
        env_file:
          - ${config.sops.secrets."speedtest-tracker/appKey".path}
        volumes:
          - /home/z/speedtest-tracker/config:/config
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          - "traefik.http.routers.speedtest.rule=Host(`speedtest.hopper.internal`)"
          - "traefik.http.routers.speedtest.entrypoints=websecure"
          - "traefik.http.routers.speedtest.tls=true"
          - "traefik.http.services.speedtest.loadbalancer.server.port=80"
  '';
in
{
  # APP_KEY must be a `base64:...` Laravel key. Generate one with:
  #   echo "APP_KEY=base64:$(openssl rand -base64 32)"
  # and store the whole `APP_KEY=...` line in secrets/hopper.yaml.
  sops.secrets."speedtest-tracker/appKey".owner = "z";

  systemd.services.speedtest-tracker = {
    description = "Speedtest Tracker";
    after = [ "network-online.target" "user@1000.service" "docker-proxy-network.service" "traefik-docker.service" ];
    wants = [ "network-online.target" "user@1000.service" ];
    wantedBy = [ "multi-user.target" ];

    environment.DOCKER_HOST = "unix:///run/user/1000/docker.sock";

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/speedtest-tracker/config && chown -R z:users /home/z/speedtest-tracker'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name speedtest-tracker down";
    };

    script = ''
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name speedtest-tracker up --remove-orphans
    '';
  };
}
