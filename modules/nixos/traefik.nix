{ config, pkgs, lib, ... }:

let
  # Let's Encrypt CA + storage, switched by config.homelab.letsencryptStaging.
  # Staging and production certs live in separate files so flipping the flag
  # never requires deleting cached certs.
  acmeCaServer =
    if config.homelab.letsencryptStaging
    then "https://acme-staging-v02.api.letsencrypt.org/directory"
    else "https://acme-v02.api.letsencrypt.org/directory";
  acmeStorage =
    if config.homelab.letsencryptStaging
    then "/letsencrypt/acme-staging.json"
    else "/letsencrypt/acme.json";

  # File provider config for non-Docker services.
  # Traefik watches this directory for YAML files at runtime.
  jellyfinConfig = pkgs.writeText "jellyfin.yml" ''
    http:
      routers:
        jellyfin:
          rule: "Host(`jellyfin.zjones.dev`)"
          entrypoints:
            - websecure
          tls:
            certResolver: letsencrypt
          service: jellyfin-svc

      services:
        jellyfin-svc:
          loadBalancer:
            servers:
              - url: "http://host.docker.internal:8096"
  '';

  composeFile = pkgs.writeText "traefik-compose.yml" ''
    networks:
      proxy:
        external: true

    services:
      # Hardened, read-only gateway to the rootful Docker socket. Traefik talks to
      # this over TCP instead of mounting /run/docker.sock directly, so a Traefik
      # compromise can't reach the root-equivalent socket. Only the container API
      # is exposed (CONTAINERS=1); writes are denied (POST=0). The socket itself is
      # mounted :ro here and nowhere else public-facing.
      docker-socket-proxy:
        image: tecnativa/docker-socket-proxy:latest
        container_name: docker-socket-proxy
        restart: unless-stopped
        environment:
          - CONTAINERS=1   # Traefik reads container labels/state
          - NETWORKS=1     # …and resolves the `proxy` network
          - EVENTS=1       # …and watches for container start/stop
          - POST=0         # deny all write endpoints
          - PING=1
          - VERSION=1
        volumes:
          - "/run/docker.sock:/var/run/docker.sock:ro"
        networks:
          - proxy

      traefik:
        image: traefik:v3
        container_name: traefik
        restart: unless-stopped
        depends_on:
          - docker-socket-proxy
        command:
          - "--providers.docker=true"
          - "--providers.docker.endpoint=tcp://docker-socket-proxy:2375"
          - "--providers.docker.exposedByDefault=false"
          - "--providers.docker.network=proxy"
          - "--providers.file.directory=/traefik-config"
          - "--providers.file.watch=true"
          - "--entrypoints.web.address=:80"
          - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
          - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
          - "--entrypoints.websecure.address=:443"
          - "--entrypoints.websecure.http.middlewares=secure-headers@docker"
          - "--certificatesresolvers.letsencrypt.acme.email=zoejonestx91@gmail.com"
          - "--certificatesresolvers.letsencrypt.acme.storage=${acmeStorage}"
          - "--certificatesresolvers.letsencrypt.acme.caserver=${acmeCaServer}"
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
          # Socket access is brokered by docker-socket-proxy above — Traefik no
          # longer mounts the Docker socket directly.
          - "/home/z/traefik/letsencrypt:/letsencrypt"
          - "${jellyfinConfig}:/traefik-config/jellyfin.yml:ro"
          - "/home/z/traefik/auth/htpasswd:/auth/users:ro"
        networks:
          - proxy
        labels:
          - "traefik.enable=true"
          # Dashboard on .internal (self-signed)
          - "traefik.http.routers.traefik.rule=Host(`traefik.memory-alpha.internal`)"
          - "traefik.http.routers.traefik.entrypoints=websecure"
          - "traefik.http.routers.traefik.tls=true"
          - "traefik.http.routers.traefik.middlewares=dashboard-auth"
          - "traefik.http.services.traefik.loadbalancer.server.port=8080"
          # Dashboard on .zjones.dev — also triggers the wildcard cert request
          # for *.memory-alpha.zjones.dev, which all other .zjones.dev routers reuse.
          - "traefik.http.routers.traefik-dev.rule=Host(`traefik.memory-alpha.zjones.dev`)"
          - "traefik.http.routers.traefik-dev.entrypoints=websecure"
          - "traefik.http.routers.traefik-dev.tls.certresolver=letsencrypt"
          - "traefik.http.routers.traefik-dev.tls.domains[0].main=memory-alpha.zjones.dev"
          - "traefik.http.routers.traefik-dev.tls.domains[0].sans=*.memory-alpha.zjones.dev"
          - "traefik.http.routers.traefik-dev.tls.domains[1].main=monitor.zjones.dev"
          - "traefik.http.routers.traefik-dev.tls.domains[1].sans=*.monitor.zjones.dev"
          - "traefik.http.routers.traefik-dev.service=traefik"
          - "traefik.http.routers.traefik-dev.middlewares=dashboard-auth"
          # Dashboard basic auth — credentials read from mounted sops secret
          - "traefik.http.middlewares.dashboard-auth.basicauth.usersfile=/auth/users"
          # Secure headers middleware
          - "traefik.http.middlewares.secure-headers.headers.frameDeny=true"
          - "traefik.http.middlewares.secure-headers.headers.contentTypeNosniff=true"
          - "traefik.http.middlewares.secure-headers.headers.referrerPolicy=strict-origin-when-cross-origin"
          - "traefik.http.middlewares.secure-headers.headers.browserXssFilter=true"
  '';
in
{
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Traefik runs in Docker but proxies the native Jellyfin service (port 8096 on
  # the host) via host.docker.internal:host-gateway. Under rootless that path
  # bypassed the host INPUT firewall; under the rootful bridge it does not, so
  # trust the pinned proxy bridge to let containers reach host-published services
  # like Jellyfin. Scoped to br-proxy rather than all docker bridges.
  networking.firewall.trustedInterfaces = [ "br-proxy" ];

  # The rootful daemon binds 80/443 as root, so the rootless-era
  # ip_unprivileged_port_start lowering is no longer needed. ip_forward stays on
  # for container networking (Docker would set it anyway).
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # Both secrets are read by the traefik service, which runs as `z`, so they
  # must be owned by z rather than the sops-nix default of root:0400.
  sops.secrets."cloudflare/apiToken".owner = "z";
  sops.secrets."traefik/dashboardAuth".owner = "z";

  systemd.services.docker-proxy-network = {
    description = "Create shared Docker proxy network";
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
    before = [ "traefik-docker.service" "dockge.service" ];
    requiredBy = [ "traefik-docker.service" "dockge.service" ];

    serviceConfig = {
      User = "z";
      Type = "oneshot";
      RemainAfterExit = true;
      # Pin the bridge interface name (br-proxy) so the host firewall can trust
      # it deterministically — Traefik reaches the native Jellyfin service over
      # this bridge via host.docker.internal:host-gateway (see below).
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.docker}/bin/docker network inspect proxy >/dev/null 2>&1 || ${pkgs.docker}/bin/docker network create --opt com.docker.network.bridge.name=br-proxy proxy'";
    };
  };

  systemd.services.traefik-docker = {
    description = "Traefik reverse proxy";
    after = [ "network-online.target" "docker.service" "docker-proxy-network.service" ];
    wants = [ "network-online.target" "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      # Runs as root (+) so it can read the sops secret and stage it for the
      # container bind-mount. (Kept from the rootless era; with the rootful
      # daemon the mount would also work straight from /run/secrets, but staging
      # under /home/z keeps ownership predictable.)
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/traefik/letsencrypt /home/z/traefik/auth && cp ${config.sops.secrets."traefik/dashboardAuth".path} /home/z/traefik/auth/htpasswd && chmod 640 /home/z/traefik/auth/htpasswd && chown -R z:users /home/z/traefik'";
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name traefik down";
    };

    script = ''
      export CF_DNS_API_TOKEN="$(cat ${config.sops.secrets."cloudflare/apiToken".path})"
      exec ${pkgs.docker}/bin/docker compose -f ${composeFile} --project-name traefik up --remove-orphans
    '';
  };
}
