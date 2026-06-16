{ config, pkgs, lib, ... }:

let
  # File-provider routes for the native (non-Docker) services. Traefik can't
  # discover these via Docker labels, so we point it at the host ports they
  # bind on localhost. `host.docker.internal` resolves to the host gateway
  # (see extra_hosts below). All routers use the `web`→`websecure` redirect and
  # self-signed TLS — these are internal/tailnet-only names, no Let's Encrypt.
  nativeRoutes = pkgs.writeText "native.yml" ''
    http:
      routers:
        homepage:
          rule: "Host(`hopper.internal`) || Host(`home.hopper.internal`)"
          entrypoints: [websecure]
          tls: {}
          service: homepage-svc
        adguard:
          rule: "Host(`adguard.hopper.internal`)"
          entrypoints: [websecure]
          tls: {}
          service: adguard-svc
        kuma:
          rule: "Host(`kuma.hopper.internal`)"
          entrypoints: [websecure]
          tls: {}
          service: kuma-svc
        ntfy:
          rule: "Host(`ntfy.hopper.internal`)"
          entrypoints: [websecure]
          tls: {}
          service: ntfy-svc

      services:
        homepage-svc:
          loadBalancer:
            servers: [{ url: "http://host.docker.internal:8082" }]
        adguard-svc:
          loadBalancer:
            servers: [{ url: "http://host.docker.internal:3000" }]
        kuma-svc:
          loadBalancer:
            servers: [{ url: "http://host.docker.internal:3001" }]
        ntfy-svc:
          loadBalancer:
            servers: [{ url: "http://host.docker.internal:2586" }]
  '';

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
          - "--providers.file.directory=/traefik-config"
          - "--providers.file.watch=true"
          - "--entrypoints.web.address=:80"
          - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
          - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
          - "--entrypoints.websecure.address=:443"
          - "--api.dashboard=true"
        ports:
          - "80:80"
          - "443:443"
        logging:
          driver: json-file
          options:
            max-size: "10m"
            max-file: "5"
        extra_hosts:
          - "host.docker.internal:host-gateway"
        volumes:
          - "/run/user/1000/docker.sock:/var/run/docker.sock:ro"
          - "${nativeRoutes}:/traefik-config/native.yml:ro"
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          # Dashboard on .internal with self-signed TLS.
          - "traefik.http.routers.traefik.rule=Host(`traefik.hopper.internal`)"
          - "traefik.http.routers.traefik.entrypoints=websecure"
          - "traefik.http.routers.traefik.tls=true"
          - "traefik.http.routers.traefik.service=api@internal"
  '';
in
{
  # Local reverse proxy: gives every web UI a tidy *.hopper.internal name with
  # TLS. Internal/tailnet only — no public ingress, no Newt, no ACME.
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Rootless Docker can't bind <1024 without this.
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;

  systemd.services.docker-proxy-network = {
    description = "Create shared Docker proxy network";
    after = [ "user@1000.service" ];
    wants = [ "user@1000.service" ];
    before = [ "traefik-docker.service" "speedtest-tracker.service" "beszel.service" ];
    requiredBy = [ "traefik-docker.service" "speedtest-tracker.service" "beszel.service" ];

    environment.DOCKER_HOST = "unix:///run/user/1000/docker.sock";

    serviceConfig = {
      User = "z";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.docker}/bin/docker network inspect proxy >/dev/null 2>&1 || ${pkgs.docker}/bin/docker network create proxy'";
    };
  };

  systemd.services.traefik-docker = {
    description = "Traefik reverse proxy (local/internal)";
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
