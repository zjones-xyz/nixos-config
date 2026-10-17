{ config, pkgs, lib, ... }:

# ── tsdproxy — one tailnet node per labelled container ─────────────────────
# Gives a service its own MagicDNS name (`home.<tailnet>.ts.net`) rather than
# a path on the host's name: MagicDNS maps names to *devices*, and
# `tailscale serve` only ever serves on the node's own name, so a distinct
# name needs a distinct node. tsdproxy creates one per container carrying
# `tsdproxy.enable=true`. Not in nixpkgs, hence a pinned container.
#
# ⚠ Known upstream bug (v2 line, still open): `docker restart tsdproxy` can
# knock a previously-healthy node into `NoState`, needing another
# `docker restart tsdproxy` (sometimes twice) to re-register — confirmed live
# 2026-09-26 on both `partdb` and `home`. Not this repo's bug and not caused
# by `dataDir` — that's a real bind mount, not wiped by a restart. Upstream:
# https://github.com/almeidapaulopt/tsdproxy/issues/496.

let
  cfg = config.homelab.tsdproxy;
in
{
  options.homelab.tsdproxy = {
    enable = lib.mkEnableOption "tsdproxy, a tailnet node per labelled container";

    authKeySecret = lib.mkOption {
      type = lib.types.str;
      default = "tailscale/authKey";
      description = ''
        sops key holding a *reusable, non-ephemeral* Tailscale auth key. Shared
        with the host's own `services.tailscale` join by default — a reusable
        key registers many nodes, and state in dataDir means it is only spent
        at each node's first registration.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tsdproxy";
      description = "Per-node tailnet state. Losing it re-registers every name.";
    };

    dockerHost = lib.mkOption {
      type = lib.types.str;
      default = "tcp://127.0.0.1:2375";
      description = ''
        Where to watch for `tsdproxy.*` labels. Defaults to the read-only
        socket proxy from traefik-galactica.nix rather than /run/docker.sock;
        that proxy sets POST=0, so the dashboard's restart/pause actions are
        inert by design — reads are all tsdproxy needs to route.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8091;
      description = ''
        tsdproxy's own dashboard/API port (config `http.port`). Deliberately
        not upstream's 8080: with host networking this shares the host's whole
        port space, and 8080 is SABnzbd's on any host running nixflix — the
        same collision adguardhome-sync.nix already documents. No
        allowedTCPPorts entry, so the firewall keeps it off the LAN.
      '';
    };

    targetHostname = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Host tsdproxy dials for every proxied container, at that container's
        *published* port. 127.0.0.1 only resolves because the container runs
        with host networking (below), which is what lets proxied services keep
        loopback-only publishes instead of opening themselves to the LAN.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ⚠ Both blocks are load-bearing: supplying a config file at all disables
    # tsdproxy's built-in default docker provider, so an absent `docker:`
    # leaves it proxying nothing while Tailscale auth still succeeds — a
    # failure that looks like success in the logs.
    sops.templates."tsdproxy.yaml".content = ''
      docker:
        local:
          host: ${cfg.dockerHost}
          targetHostname: ${cfg.targetHostname}

      http:
        hostname: 0.0.0.0
        port: ${toString cfg.port}

      tailscale:
        providers:
          default:
            authKey: "${config.sops.placeholder.${cfg.authKeySecret}}"
            controlUrl: https://controlplane.tailscale.com
        dataDir: /data/

      log:
        level: info
        json: false
    '';

    systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0700 root root - -" ];

    virtualisation.oci-containers.containers.tsdproxy = {
      # Pinned for the same reason as the socket proxy and the homepages:
      # with pull="missing", a floating tag resolves once and never updates.
      image = "almeidapaulopt/tsdproxy:2";
      volumes = [
        "${cfg.dataDir}:/data"
        "${config.sops.templates."tsdproxy.yaml".path}:/config/tsdproxy.yaml:ro"
      ];
      # Host networking, not the `proxy` bridge: tsdproxy must reach both the
      # socket proxy and each service on 127.0.0.1. That shares the host's
      # port space, hence the non-default `port` above; the dashboard binds
      # every interface and the host firewall is what keeps it off the LAN.
      extraOptions = [ "--network=host" ];
    };
  };
}
