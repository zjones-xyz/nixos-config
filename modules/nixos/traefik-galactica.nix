{ config, pkgs, lib, ... }:

# Traefik for galactica's media stack.
#
# ── Why this one is native, when the other three are Docker ────────────────
# `traefik.nix` (memory-alpha), `traefik-local.nix` (hopper) and
# `traefik-hamilton.nix` all run Traefik as a Docker Compose stack. Those hosts
# serve Docker workloads, so Traefik lives next to the things it proxies.
#
# galactica is the opposite shape: every service it proxies — the five *arrs,
# SABnzbd, qBittorrent, Navidrome — is a native systemd unit from nixflix, and
# it runs no containers today. Wrapping Traefik in Docker there would mean
# enabling rootless Docker beside the rootful daemon already present, plus
# compose plumbing, to reach services on the host it is already running on.
#
# The Docker *provider* is a separate question from Traefik's own packaging,
# and it is kept: a native Traefik reads container labels perfectly well, it
# just needs to reach the Docker API. So containers added to galactica later
# get exactly the label-based config the other hosts use, with no migration —
# join the `proxy` network, set `traefik.enable=true`, done.
#
# ── Why a socket proxy rather than the docker group ───────────────────────
# Reaching /run/docker.sock directly would mean putting the traefik user in the
# `docker` group, which is root-equivalent. `traefik.nix` already rejected that
# for the same reason, in its own words: "a Traefik compromise can't reach the
# root-equivalent socket". Same answer here — tecnativa/docker-socket-proxy
# exposes a read-only slice of the API on loopback, and Traefik talks to that.
#
# ── Naming ────────────────────────────────────────────────────────────────
# `*.arr.internal` / `*.arr.zjones.dev`, NOT `*.galactica.*` like the rest of
# the fleet. Deliberate, and the owner's call: these names follow the media
# *stack*, so moving it to another host later is a DNS change rather than a
# rename of every bookmark, Prowlarr application URL and *arr cross-reference.

let
  # Let's Encrypt CA + storage, switched by config.homelab.letsencryptStaging.
  # Staging and production certs live in separate files so flipping the flag
  # never requires deleting cached certs. Same contract as the other three
  # Traefik modules; only the paths differ, because a native Traefik keeps
  # state in its own dataDir rather than a bind-mounted host directory.
  acmeCaServer =
    if config.homelab.letsencryptStaging
    then "https://acme-staging-v02.api.letsencrypt.org/directory"
    else "https://acme-v02.api.letsencrypt.org/directory";
  acmeStorage =
    if config.homelab.letsencryptStaging
    then "/var/lib/traefik/acme-staging.json"
    else "/var/lib/traefik/acme.json";

  internalDomain = "arr.internal";
  publicDomain = "arr.zjones.dev";

  nixflix = config.nixflix;

  # Every routed service, as subdomain → upstream URL.
  #
  # Ports are read from the evaluated nixflix config rather than written out,
  # so changing a port in hosts/galactica/nixflix.nix cannot leave a stale
  # route pointing at nothing.
  upstreams = {
    prowlarr = "http://127.0.0.1:${toString nixflix.prowlarr.config.hostConfig.port}";
    sonarr = "http://127.0.0.1:${toString nixflix.sonarr.config.hostConfig.port}";
    sonarr-anime = "http://127.0.0.1:${toString nixflix.sonarr-anime.config.hostConfig.port}";
    radarr = "http://127.0.0.1:${toString nixflix.radarr.config.hostConfig.port}";
    lidarr = "http://127.0.0.1:${toString nixflix.lidarr.config.hostConfig.port}";
    navidrome = "http://127.0.0.1:${toString config.services.navidrome.settings.Port}";
    sabnzbd = "http://127.0.0.1:${toString config.services.sabnzbd.settings.misc.port}";

    # NOT 127.0.0.1. qBittorrent is confined to the wg namespace and binds the
    # namespace address; the host reaches it directly over the wg-br bridge
    # (host side 192.168.15.5), which is why no port mapping is involved here.
    qbittorrent = "http://${nixflix.torrentClients.qbittorrent.connectionAddress}:${
      toString nixflix.torrentClients.qbittorrent.webuiPort
    }";
  };

  # FlareSolverr is deliberately absent. It has no UI worth reaching, it is an
  # unauthenticated HTTP endpoint that fetches arbitrary URLs through a real
  # browser, and its only client (Prowlarr) talks to it on loopback.

  mkRouters = lib.concatMapAttrs (name: _: {
    # *.arr.internal — Traefik's own self-signed cert. No ACME, so these work
    # on a LAN with no outbound path and no DNS provider.
    ${name} = {
      rule = "Host(`${name}.${internalDomain}`)";
      entrypoints = [ "websecure" ];
      tls = { };
      service = "${name}-svc";
    };
    # *.arr.zjones.dev — the Let's Encrypt wildcard anchored below.
    "${name}-dev" = {
      rule = "Host(`${name}.${publicDomain}`)";
      entrypoints = [ "websecure" ];
      tls.certResolver = "letsencrypt";
      service = "${name}-svc";
    };
  }) upstreams;

  mkServices = lib.concatMapAttrs (name: url: {
    "${name}-svc".loadBalancer.servers = [ { inherit url; } ];
  }) upstreams;
in
{
  # ── The Cloudflare DNS-01 token ───────────────────────────────────────────
  # A twelfth secret for this host. DNS-01 rather than HTTP-01 because these
  # names never resolve publicly — the challenge is answered by writing a TXT
  # record, so no inbound path from the internet is needed or wanted.
  #
  # Rendered as an EnvironmentFile rather than read in a script: the nixpkgs
  # Traefik module takes `environmentFiles` and runs envsubst over the static
  # config before start, which is the supported way to keep the token out of
  # the world-readable store.
  sops.secrets."cloudflare/apiToken" = { };

  sops.templates."traefik.env" = {
    content = ''
      CF_DNS_API_TOKEN=${config.sops.placeholder."cloudflare/apiToken"}
    '';
    owner = "traefik";
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  services.traefik = {
    enable = true;
    environmentFiles = [ config.sops.templates."traefik.env".path ];

    staticConfigOptions = {
      entryPoints = {
        web = {
          address = ":80";
          http.redirections.entryPoint = {
            to = "websecure";
            scheme = "https";
          };
        };
        websecure.address = ":443";
      };

      providers.docker = {
        # The read-only socket proxy below, not the socket itself.
        endpoint = "tcp://127.0.0.1:2375";
        exposedByDefault = false;
        network = "proxy";
      };

      certificatesResolvers.letsencrypt.acme = {
        # The same address the other three Traefik modules already register
        # with Let's Encrypt; kept identical so all four hosts share one ACME
        # account rather than creating a fourth.
        email = "zoejonestx91@gmail.com";
        storage = acmeStorage;
        caServer = acmeCaServer;
        dnsChallenge = {
          provider = "cloudflare";
          resolvers = [
            "1.1.1.1:53"
            "1.0.0.1:53"
          ];
        };
      };

      api.dashboard = true;
      accessLog.format = "json";
      log.level = "INFO";
    };

    dynamicConfigOptions.http = {
      routers = mkRouters // {
        dashboard = {
          rule = "Host(`traefik.${internalDomain}`)";
          entrypoints = [ "websecure" ];
          tls = { };
          service = "api@internal";
        };
        # The wildcard anchor. One router requests
        # `arr.zjones.dev` + `*.arr.zjones.dev` once, and every other
        # *.arr.zjones.dev router above reuses that cert — same trick as
        # traefik-local.nix's `traefik-dev`. Without it each subdomain would
        # request its own cert and walk straight into Let's Encrypt's rate
        # limits.
        dashboard-dev = {
          rule = "Host(`traefik.${publicDomain}`)";
          entrypoints = [ "websecure" ];
          tls = {
            certResolver = "letsencrypt";
            domains = [
              {
                main = publicDomain;
                sans = [ "*.${publicDomain}" ];
              }
            ];
          };
          service = "api@internal";
        };
      };
      services = mkServices;
    };
  };

  # ── Docker socket proxy ───────────────────────────────────────────────────
  # Inert until galactica actually runs containers — it exists so that when it
  # does, they are label-configurable on day one rather than needing this
  # module reopened.
  virtualisation.oci-containers = {
    # ⚠ NixOS defaults this to podman, against a host running rootful Docker
    # (and a Beszel agent watching a Docker socket). DESIGN.md §6.5 flags the
    # same trap. Set explicitly.
    backend = "docker";

    containers.docker-socket-proxy = {
      image = "tecnativa/docker-socket-proxy:latest";
      autoStart = true;
      environment = {
        CONTAINERS = "1"; # Traefik reads container labels/state
        NETWORKS = "1"; # …and resolves the `proxy` network
        EVENTS = "1"; # …and watches for container start/stop
        POST = "0"; # deny all write endpoints
        PING = "1";
        VERSION = "1";
      };
      volumes = [ "/run/docker.sock:/var/run/docker.sock:ro" ];
      # Loopback only — nothing off-box should reach even the read-only API.
      ports = [ "127.0.0.1:2375:2375" ];
      extraOptions = [ "--network=proxy" ];
    };
  };

  # Ordering only, deliberately not a dependency: if the socket proxy is down
  # (image pull failed, Docker itself broken) Traefik still starts and every
  # file-provider route below still serves — it just logs that the Docker
  # provider is unreachable. Binding them would trade nine working web UIs for
  # a container that today proxies nothing.
  systemd.services.traefik.after = [ "docker-docker-socket-proxy.service" ];

  # The shared network future containers join to become visible to Traefik.
  # Mirrors hopper's docker-proxy-network unit; `docker network create` is not
  # declarative, so it has to be a oneshot.
  systemd.services.docker-proxy-network = {
    description = "Create shared Docker proxy network";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = [ "docker-docker-socket-proxy.service" ];
    requiredBy = [ "docker-docker-socket-proxy.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c '${config.virtualisation.docker.package}/bin/docker network inspect proxy >/dev/null 2>&1 || ${config.virtualisation.docker.package}/bin/docker network create proxy'";
    };
  };
}
