{ config, pkgs, lib, ... }:

# Slicer sidecars for Bambuddy (bambuddy.nix): HTTP wrappers around the
# OrcaSlicer and BambuStudio CLIs, so Bambuddy's "Slice" action produces a
# printable .gcode.3mf without a desktop slicer. Ported from homelab-stacks
# memory-alpha/orca-slicer-api; MANUAL-STEPS.md §2.
#
# No --health-cmd: both images bake in the compose stack's curl /health check.

let
  # Upstream tags each sidecar build `bambuddy-<version>`, after the Bambuddy
  # release it shipped with, so bumping bambuddy.nix's image bumps these too.
  # The match skips a trailing @sha256 digest.
  tag = "bambuddy-" + builtins.head (builtins.match ".*:([^@:/]+)(@.*)?"
    config.virtualisation.oci-containers.containers.bambuddy.image);

  # listen: the activation socket Bambuddy calls. backend: the container,
  # published on loopback only. The +10000 keeps clear of Bambuddy's upstream
  # defaults (3001/3003), which Uptime Kuma also uses elsewhere in the fleet.
  sidecars = {
    orca-slicer-api = { listen = 13003; backend = 23003; };
    bambu-studio-api = { listen = 13001; backend = 23001; };
  };

  idleTimeout = "30min";
  docker = "${config.virtualisation.docker.package}/bin/docker";
  image = name: "ghcr.io/maziggy/${name}:${tag}";

  container = name: s: {
    image = image name;
    # Started by the activation socket below, not at boot.
    autoStart = false;
    environment = {
      NODE_ENV = "production";
      PORT = "3000";
    };
    ports = [ "127.0.0.1:${toString s.backend}:3000" ];
    volumes = [ "/home/z/${name}:/app/data" ];
    # Same slice and CPU quota as Bambuddy and Obico; DECISIONS.md §2.
    extraOptions = [ "--cgroup-parent=system-maker.slice" ];
  };

  # ── Load on demand, unload on idle ────────────────────────────────────────
  # A connection to `listen` starts slicer-<name>, which pulls in the
  # container, waits for /health, then hands over to systemd-socket-proxyd.
  # The proxy exits after idleTimeout without connections, and the
  # container goes with it (StopWhenUnneeded). DECISIONS.md §3.
  proxy = name: s: {
    description = "On-demand proxy to the ${name} slicer sidecar";
    wants = [ "docker-${name}.service" ];
    after = [ "docker-${name}.service" ];
    path = [ pkgs.curl config.systemd.package ];
    # Never fails: a failed start leaves the triggering connection queued, and
    # the socket would re-trigger on it forever. Handing over to proxyd drains
    # it instead, and the idle timeout then unloads everything as usual.
    preStart = ''
      while [ "$SECONDS" -lt 300 ]; do
        curl -sf --max-time 2 -o /dev/null http://127.0.0.1:${toString s.backend}/health && exit 0
        systemctl is-failed -q docker-${name}.service && break
        sleep 0.5
      done
      echo "${name} is not healthy; proxying anyway" >&2
    '';
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${idleTimeout} 127.0.0.1:${toString s.backend}";
      TimeoutStartSec = "6min";
    };
  };
in
{
  virtualisation.oci-containers.containers = lib.mapAttrs container sidecars // {
    # Bambuddy's defaults when Settings → Slicer's URL is left blank. It
    # reaches the host over `proxy`, whose bridge the host firewall trusts.
    bambuddy = {
      environment = {
        SLICER_API_URL = "http://host.docker.internal:${toString sidecars.orca-slicer-api.listen}";
        BAMBU_STUDIO_API_URL = "http://host.docker.internal:${toString sidecars.bambu-studio-api.listen}";
      };
      extraOptions = [ "--add-host=host.docker.internal:host-gateway" ];
    };
  };

  # Every address, but not in allowedTCPPorts: the firewall admits only its
  # trusted interfaces, br-proxy (traefik.nix) and loopback.
  systemd.sockets = lib.mapAttrs' (name: s: lib.nameValuePair "slicer-${name}" {
    description = "On-demand socket for the ${name} slicer sidecar";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ (toString s.listen) ];
  }) sidecars;

  systemd.services = lib.mapAttrs' (name: s: lib.nameValuePair "slicer-${name}" (proxy name s)) sidecars
    // lib.mapAttrs' (name: _: lib.nameValuePair "docker-${name}" {
      unitConfig.StopWhenUnneeded = true;
      # `docker stop` on a Node PID 1: SIGTERM or SIGKILL, not a failure.
      # That makes a crash look clean too, so restart on any exit; a stop
      # systemd itself makes (StopWhenUnneeded) still never restarts.
      serviceConfig.SuccessExitStatus = "137 143";
      serviceConfig.Restart = lib.mkForce "always";
    }) sidecars
    // {
      # Pull at boot and on switch, so a cold start never waits on a ~400 MB
      # download. The images stay on disk while the containers are stopped.
      slicer-images = {
        description = "Pre-pull the slicer sidecar images";
        after = [ "docker.service" "network-online.target" ];
        requires = [ "docker.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # One failed pull must not skip the other.
        script = "rc=0\n" + lib.concatMapStringsSep "\n" (name:
          "${docker} image inspect ${image name} >/dev/null 2>&1 || ${docker} pull ${image name} || rc=1"
        ) (lib.attrNames sidecars) + "\nexit $rc";
      };
    };
}
