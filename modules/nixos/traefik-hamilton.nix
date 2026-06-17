{ config, pkgs, lib, ... }:

let
  # File-provider routes for hamilton's native services (AdGuard Home only).
  # Two routers per service: *.hamilton.internal (self-signed) and
  # *.hamilton.zjones.dev (Let's Encrypt wildcard, DNS challenge via Cloudflare).
  nativeRoutes = pkgs.writeText "native-hamilton.yml" ''
    http:
      routers:
        adguard:
          rule: "Host(`adguard.hamilton.internal`)"
          entrypoints: [websecure]
          tls: {}
          service: adguard-svc
        adguard-dev:
          rule: "Host(`adguard.hamilton.zjones.dev`)"
          entrypoints: [websecure]
          tls:
            certResolver: letsencrypt
          service: adguard-svc

      services:
        adguard-svc:
          loadBalancer:
            servers: [{ url: "http://host.docker.internal:3000" }]
  '';

  composeFile = pkgs.writeText "traefik-hamilton-compose.yml" ''
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
          - "--certificatesresolvers.letsencrypt.acme.email=zoejonestx91@gmail.com"
          - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
          - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
          - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
          - "--certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=1.1.1.1:53,1.0.0.1:53"
          - "--api.dashboard=false"
        ports:
          - "80:80"
          - "443:443"
        logging:
          driver: json-file
          options:
            max-size: "10m"
            max-file: "5"
        environment:
          - CF_DNS_API_TOKEN
        extra_hosts:
          - "host.docker.internal:host-gateway"
        volumes:
          - "/run/user/1000/docker.sock:/var/run/docker.sock:ro"
          - "/home/z/traefik/letsencrypt:/letsencrypt"
          - "${nativeRoutes}:/traefik-config/native.yml:ro"
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          # Wildcard cert anchor — triggers the LE DNS challenge for
          # hamilton.zjones.dev + *.hamilton.zjones.dev once; all other
          # *.hamilton.zjones.dev routers reuse the issued cert.
          - "traefik.http.routers.traefik-dev.rule=Host(`traefik.hamilton.zjones.dev`)"
          - "traefik.http.routers.traefik-dev.entrypoints=websecure"
          - "traefik.http.routers.traefik-dev.tls.certresolver=letsencrypt"
          - "traefik.http.routers.traefik-dev.tls.domains[0].main=hamilton.zjones.dev"
          - "traefik.http.routers.traefik-dev.tls.domains[0].sans=*.hamilton.zjones.dev"
          - "traefik.http.routers.traefik-dev.service=api@internal"
  '';
in
{
  sops.secrets."cloudflare/apiToken".owner = "z";

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Rootless Docker can't bind <1024 without this.
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;

  systemd.services.docker-proxy-network = {
    description = "Create shared Docker proxy network";
    after = [ "user@1000.service" ];
    wants = [ "user@1000.service" ];
    before = [ "traefik-docker.service" ];
    requiredBy = [ "traefik-docker.service" ];

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
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/traefik/letsencrypt && chown -R z:users /home/z/traefik'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name traefik down";
    };

    script = ''
      export CF_DNS_API_TOKEN="$(cat ${config.sops.secrets."cloudflare/apiToken".path})"
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name traefik up --remove-orphans
    '';
  };
}
