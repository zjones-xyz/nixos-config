{ config, pkgs, lib, ... }:

# Traefik for galactica's media stack.
#
# Native, not the fleet's Docker-compose shape: everything proxied here is a
# native systemd unit. The Docker *provider* is kept (label-based config for
# future containers) but talks to a read-only socket proxy on loopback —
# joining the `docker` group would be root-equivalent, per traefik.nix.
# Names are `*.arr.*`, not `*.galactica.*`, the owner's call: they follow the
# media stack, so relocating it is a DNS change, not a rename of every URL.

let
  # Staging and production certs live in separate files so flipping
  # homelab.letsencryptStaging never requires deleting cached certs. The CA
  # URL and ACME email are the shared options from letsencrypt.nix; only the
  # storage path is this module's own, because a native Traefik keeps state in
  # its dataDir rather than a bind-mounted host directory.
  acmeStorage =
    if config.homelab.letsencryptStaging
    then "/var/lib/traefik/acme-staging.json"
    else "/var/lib/traefik/acme.json";

  internalDomain = "arr.internal";
  publicDomain = "arr.zjones.dev";

  # The one certificate every *.arr.zjones.dev router requests. Declared once
  # and shared so no router can drift into asking for a different SAN set,
  # which would defeat the deduplication described at mkRouters below.
  domains = [
    {
      main = publicDomain;
      sans = [ "*.${publicDomain}" ];
    }
  ];

  nixflix = config.nixflix;

  # Every routed service, as subdomain → upstream URL. Both halves come from
  # the service's own evaluated options — ⚠ hardcoding 127.0.0.1 breaks any
  # service in (or later moved into) the VPN namespace, whose
  # `connectionAddress` is the namespace address. qBittorrent is that case.
  svcUrl = svc: port: "http://${svc.connectionAddress}:${toString port}";
  arrUrl = name: svcUrl nixflix.${name} nixflix.${name}.config.hostConfig.port;

  upstreams =
    lib.genAttrs [
      "prowlarr"
      "sonarr"
      "sonarr-anime"
      "radarr"
      "lidarr"
    ] arrUrl
    // {
      navidrome = svcUrl nixflix.navidrome nixflix.navidrome.settings.Port;
      # "usenet", not the service's own name — sabnzbd is a typo trap.
      # Must stay in step with its host_whitelist (hosts/galactica/nixflix.nix).
      usenet = svcUrl nixflix.usenetClients.sabnzbd nixflix.usenetClients.sabnzbd.settings.misc.port;
      qbittorrent = svcUrl nixflix.torrentClients.qbittorrent nixflix.torrentClients.qbittorrent.webuiPort;
    }
    # Host-local services nixflix does not know about; they register
    # themselves so each port stays written once, where the service is defined.
    // config.homelab.arrExtraUpstreams;

  # ⚠ FlareSolverr is deliberately absent: an unauthenticated endpoint that
  # fetches arbitrary URLs through a real browser; its only client is local.

  # One pair per service: `.internal` on the self-signed cert, `.zjones.dev`
  # on the LE wildcard. The dashboard reuses it, so the invariant below is
  # written once.
  mkRouterPair =
    {
      name,
      host,
      service,
    }:
    {
      # *.arr.internal — no ACME, so these work on a LAN with no outbound path
      # and no DNS provider.
      ${name} = {
        rule = "Host(`${host}.${internalDomain}`)";
        entrypoints = [ "websecure" ];
        tls = { };
        inherit service;
      };
      # ⚠ Every -dev router asks for the SAME wildcard, and that is the
      # dedup: Traefik skips a domain only once a covering cert is already
      # stored, so per-host `domains` here lose a cold-start race and issue
      # ~9 individual certs — against production, a fifth of the weekly
      # allowance.
      "${name}-dev" = {
        rule = "Host(`${host}.${publicDomain}`)";
        entrypoints = [ "websecure" ];
        tls = {
          certResolver = "letsencrypt";
          inherit domains;
        };
        inherit service;
      };
    };

  mkRouters = lib.concatMapAttrs (
    name: _:
    mkRouterPair {
      inherit name;
      host = name;
      service = "${name}-svc";
    }
  ) upstreams;

  mkServices = lib.concatMapAttrs (name: url: {
    "${name}-svc".loadBalancer.servers = [ { inherit url; } ];
  }) upstreams;
in
{
  options.homelab.arrExtraUpstreams = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = lib.literalExpression ''{ bazarr = "http://127.0.0.1:6767"; }'';
    description = ''
      Extra subdomain → upstream-URL pairs to publish under `arr.internal` and
      `arr.zjones.dev`, for services nixflix does not manage. Each gets the
      same router pair as a nixflix service, wildcard certificate included.
    '';
  };

  config = {
    # The dashboard pair claims the router names `dashboard`/`dashboard-dev`
    # and the host `traefik`; an upstream taking either would silently lose.
    assertions = [
      {
        assertion = !(upstreams ? dashboard) && !(upstreams ? traefik);
        message = "traefik-galactica: the upstream names `dashboard` and `traefik` are reserved for the dashboard router pair.";
      }
    ];

    # ── The Cloudflare DNS-01 token ───────────────────────────────────────────
    # DNS-01 because these names never resolve publicly; `environmentFiles` is
    # the supported way to keep the token out of the world-readable store.
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
          email = config.homelab.letsencryptEmail;
          storage = acmeStorage;
          caServer = config.homelab.letsencryptCaServer;
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
        routers =
          mkRouters
          // mkRouterPair {
            name = "dashboard";
            host = "traefik";
            service = "api@internal";
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
      # (and a Beszel agent watching a Docker socket). Set explicitly;
      # ARCHIVE-DESIGN-snapraid.md §6.5 flags the same trap.
      backend = "docker";

      containers.docker-socket-proxy = {
        # Pinned: with the oci-containers default pull="missing", :latest is
        # resolved once on first start and then NEVER updated — the worst of
        # both directions, on the component brokering /run/docker.sock.
        image = "tecnativa/docker-socket-proxy:v0.5.0";
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

    # Deliberately NO ordering or dependency on the socket proxy: Traefik's
    # Docker provider retries on its own, and waiting out docker.service plus
    # a container start on every boot would hold nine file-provider routes
    # hostage to a container that today proxies nothing.

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
  };
}
