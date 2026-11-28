{
  config,
  pkgs,
  lib,
  ...
}:

# Automatic Ripping Machine — rips whatever disc goes into the BD-ROM
# (https://github.com/automatic-ripping-machine/automatic-ripping-machine).
# No nixpkgs module, hence a container; served at autoripper.{internal,zjones.dev}.
# Rips land in `tank/arm`, the Unraid `arm` share re-homed: Regenerable, since
# a rip can be redone from the disc (SHARES.md). Owner steps: MANUAL-STEPS.md §#272.

let
  image = "automaticrippingmachine/automatic-ripping-machine:2.25.0";
  appDir = "/tank/appdata/arm"; # job DB, MakeMKV/HandBrake state, arm.yaml, logs
  mediaDir = "/tank/arm"; # media/{raw,transcode,completed}, music
  port = 3027; # next free loopback slot after memos.nix's 3026
  uid = toString config.users.users.z.uid;
  gid = toString config.users.groups.${config.users.users.z.group}.gid;
in
{
  # MakeMKV drives the BD-ROM through its SCSI-generic node (/dev/sg*), not
  # /dev/sr0. Something loads `sg` today; this keeps it from being luck.
  boot.kernelModules = [ "sg" ];

  # `d` also re-owns an existing directory, so this chowns the fresh dataset
  # to the uid ARM runs as — ARM refuses to start on volumes it can't write.
  systemd.tmpfiles.rules = [
    "d ${appDir} 0750 ${uid} ${gid} - -"
    "d ${appDir}/home 0750 ${uid} ${gid} - -"
    "d ${appDir}/config 0750 ${uid} ${gid} - -"
    "d ${appDir}/logs 0750 ${uid} ${gid} - -"
    "d ${mediaDir} 0755 ${uid} ${gid} - -"
    "d ${mediaDir}/media 0755 ${uid} ${gid} - -"
    "d ${mediaDir}/music 0755 ${uid} ${gid} - -"
  ];

  # Same degraded-boot guard as memos.nix: don't rip onto empty mountpoints.
  systemd.services.docker-arm.unitConfig.RequiresMountsFor = [
    appDir
    mediaDir
  ];

  virtualisation.oci-containers.containers.arm = {
    inherit image;
    environment = {
      ARM_UID = uid;
      ARM_GID = gid;
      TZ = config.time.timeZone;
    };
    volumes = [
      "${appDir}/home:/home/arm"
      "${appDir}/config:/etc/arm/config"
      "${appDir}/logs:/home/arm/logs"
      "${mediaDir}/media:/home/arm/media"
      "${mediaDir}/music:/home/arm/music"
    ];
    ports = [ "127.0.0.1:${toString port}:8080" ];
    # ── Privileged, deliberately ──
    # The container runs its own udev to catch disc insertion and mounts the
    # disc itself; upstream's only supported shape. It sees every host device
    # at container start, so a drive attached later (USB) needs a restart.
    extraOptions = [ "--privileged" ];
  };

  # No tsdproxy node, unlike memos.nix: ripping means standing at the drive.
  services.traefik.dynamicConfigOptions.http = {
    routers = {
      autoripper = {
        rule = "Host(`autoripper.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "autoripper-svc";
      };
      "autoripper-dev" = {
        rule = "Host(`autoripper.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "autoripper-svc";
      };
    };
    services.autoripper-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
}
