{ config, pkgs, lib, ... }:

# Obico ML API — print-failure detection for Bambuddy (bambuddy.nix). Only
# this one Obico service: Bambuddy POSTs camera snapshots and reads back
# failure scores. No Obico account, web UI, database or OctoPrint bridge.
#
# CPU inference — Obico's GPU path is CUDA-only — so it never contends for the
# iGPU Jellyfin transcodes on; CPU contention is what the maker slice is for.
# Ported from homelab-stacks memory-alpha/obico; MANUAL-STEPS.md §1.

{
  # `proxy` is created by traefik.nix's oneshot, not by this container.
  systemd.services.docker-obico-ml-api = {
    after = [ "docker-proxy-network.service" ];
    requires = [ "docker-proxy-network.service" ];
  };

  virtualisation.oci-containers.containers.obico-ml-api = {
    # Upstream publishes no release tags, only `latest` and commit SHAs.
    image = "ghcr.io/gabe565/obico/ml-api@sha256:1e18ec7e7fd97ecc186d940e3e2fcd53c7253388ab2cce47866d230dd440dd04";
    environment = {
      DEBUG = "True";
      FLASK_APP = "server.py";
    };
    cmd = [ "gunicorn" "--bind=0.0.0.0:3333" "--workers=1" "--access-logfile=-" "wsgi" ];
    labels = {
      "traefik.enable" = "true";
      "traefik.http.routers.obico-ml-api-internal.rule" = "Host(`obico.memory-alpha.internal`)";
      "traefik.http.routers.obico-ml-api-internal.entrypoints" = "websecure";
      "traefik.http.routers.obico-ml-api-internal.tls" = "true";
      "traefik.http.routers.obico-ml-api-internal.service" = "obico-ml-api";
      "traefik.http.routers.obico-ml-api-dev.rule" = "Host(`obico.3dp.zjones.dev`)";
      "traefik.http.routers.obico-ml-api-dev.entrypoints" = "websecure";
      "traefik.http.routers.obico-ml-api-dev.tls.certresolver" = "letsencrypt";
      "traefik.http.routers.obico-ml-api-dev.service" = "obico-ml-api";
      "traefik.http.services.obico-ml-api.loadbalancer.server.port" = "3333";
    };
    # `--tty` carries over the compose stack's `tty: true`.
    extraOptions = [
      "--network=proxy"
      "--tty"
      "--cgroup-parent=system-maker.slice"
    ];
  };
}
