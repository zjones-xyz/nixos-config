{ config, pkgs, lib, ... }:

let
  # File-provider routes for the native (non-Docker) services on hopper.
  # Each service gets two routers:
  #   *.hopper.internal  — self-signed TLS, reachable on LAN without external DNS
  #   *.hopper.zjones.dev — Let's Encrypt wildcard cert, reachable on tailnet
  # The LE wildcard is issued once (triggered by the traefik dashboard label
  # below) and reused by all *.hopper.zjones.dev routers.
  nativeRoutes = pkgs.writeText "native.yml" ''
    http:
      routers:
        # ── *.hopper.internal (self-signed) ───────────────────────────────────
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

        # ── *.hopper.zjones.dev (Let's Encrypt wildcard) ───────────────────────
        homepage-dev:
          rule: "Host(`hopper.zjones.dev`) || Host(`home.hopper.zjones.dev`)"
          entrypoints: [websecure]
          tls:
            certResolver: letsencrypt
          service: homepage-svc
        adguard-dev:
          rule: "Host(`adguard.hopper.zjones.dev`)"
          entrypoints: [websecure]
          tls:
            certResolver: letsencrypt
          service: adguard-svc
        kuma-dev:
          rule: "Host(`kuma.hopper.zjones.dev`)"
          entrypoints: [websecure]
          tls:
            certResolver: letsencrypt
          service: kuma-svc
        ntfy-dev:
          rule: "Host(`ntfy.hopper.zjones.dev`)"
          entrypoints: [websecure]
          tls:
            certResolver: letsencrypt
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
          - "--certificatesresolvers.letsencrypt.acme.email=zoejonestx91@gmail.com"
          - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
          - "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
          - "--certificatesresolvers.letsencrypt.acme.dnschallenge=true"
          - "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare"
          - "--certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=1.1.1.1:53,1.0.0.1:53"
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
          # Dashboard — *.internal, self-signed.
          - "traefik.http.routers.traefik.rule=Host(`traefik.hopper.internal`)"
          - "traefik.http.routers.traefik.entrypoints=websecure"
          - "traefik.http.routers.traefik.tls=true"
          - "traefik.http.routers.traefik.service=api@internal"
          # Dashboard — *.zjones.dev with LE wildcard cert.
          # This router is the wildcard "anchor": requesting the cert for
          # hopper.zjones.dev + *.hopper.zjones.dev once; all other
          # *.hopper.zjones.dev routers reuse it automatically.
          - "traefik.http.routers.traefik-dev.rule=Host(`traefik.hopper.zjones.dev`)"
          - "traefik.http.routers.traefik-dev.entrypoints=websecure"
          - "traefik.http.routers.traefik-dev.tls.certresolver=letsencrypt"
          - "traefik.http.routers.traefik-dev.tls.domains[0].main=hopper.zjones.dev"
          - "traefik.http.routers.traefik-dev.tls.domains[0].sans=*.hopper.zjones.dev"
          - "traefik.http.routers.traefik-dev.service=api@internal"
  '';
in
{
  # Cloudflare token needs to be readable by the traefik service (runs as z).
  sops.secrets."cloudflare/apiToken".owner = "z";

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
