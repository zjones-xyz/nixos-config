{ config, pkgs, lib, ... }:

# Slicer sidecars for Bambuddy (bambuddy.nix): HTTP wrappers around the
# OrcaSlicer and BambuStudio CLIs, so Bambuddy's "Slice" action produces a
# printable .gcode.3mf without a desktop slicer. Ported from homelab-stacks
# memory-alpha/orca-slicer-api; MANUAL-STEPS.md §2.
#
# No --health-cmd: both images bake in the compose stack's curl /health check.

let
  # Upstream tags each sidecar build with the Bambuddy release it shipped
  # with. Bump together with bambuddy.nix's image.
  tag = "bambuddy-1.2.5.6";

  sidecar = { name, host }: {
    image = "ghcr.io/maziggy/${name}:${tag}";
    environment = {
      NODE_ENV = "production";
      PORT = "3000";
    };
    volumes = [ "/home/z/${name}:/app/data" ];
    labels = {
      "traefik.enable" = "true";
      "traefik.http.routers.${host}-internal.rule" = "Host(`${host}.memory-alpha.internal`)";
      "traefik.http.routers.${host}-internal.entrypoints" = "websecure";
      "traefik.http.routers.${host}-internal.tls" = "true";
      "traefik.http.routers.${host}-internal.service" = name;
      "traefik.http.routers.${host}-dev.rule" = "Host(`${host}.3dp.zjones.dev`)";
      "traefik.http.routers.${host}-dev.entrypoints" = "websecure";
      "traefik.http.routers.${host}-dev.tls.certresolver" = "letsencrypt";
      "traefik.http.routers.${host}-dev.service" = name;
      "traefik.http.services.${name}.loadbalancer.server.port" = "3000";
    };
    # Same slice and 200% quota as Bambuddy and Obico; DECISIONS.md §2.
    extraOptions = [
      "--network=proxy"
      "--cgroup-parent=system-maker.slice"
    ];
  };

  sidecars = {
    orca-slicer-api = "orca-slicer";
    bambu-studio-api = "bambu-slicer";
  };
in
{
  virtualisation.oci-containers.containers =
    lib.mapAttrs (name: host: sidecar { inherit name host; }) sidecars // {
      # Bambuddy's defaults when Settings → Slicer's URL is left blank. Over
      # `proxy` by container name, like Obico: no Traefik hop.
      bambuddy.environment = {
        SLICER_API_URL = "http://orca-slicer-api:3000";
        BAMBU_STUDIO_API_URL = "http://bambu-studio-api:3000";
      };
    };

  # `proxy` is created by traefik.nix's oneshot, not by these containers.
  systemd.services = lib.mapAttrs' (name: _: lib.nameValuePair "docker-${name}" {
    after = [ "docker-proxy-network.service" ];
    requires = [ "docker-proxy-network.service" ];
  }) sidecars;
}
