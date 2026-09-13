{
  config,
  pkgs,
  lib,
  ...
}:

# Syncthing — fresh instance, NOT a migration. The old Unraid Syncthing
# appdata is owner-confirmed junk (SHARES.md) and was dropped rather than
# backed up, unlike Ferdium/Karakeep/Paperless.
#
# Host networking, against this host's usual loopback-publish-plus-Traefik
# shape: upstream's own docs are explicit that Docker's default bridge
# prevents LAN peer discovery (the 21027/udp broadcast) and direct sync
# connections (22000 tcp+udp) from reaching real peers at all — the one
# thing this container exists to do. `STGUIADDRESS` claws the GUI back to
# loopback-only so it still goes through Traefik/tsdproxy like every other
# dashboard here, rather than sitting open on the LAN via the host network.

let
  image = "syncthing/syncthing:2.1.5";
  dataDir = "/tank/appdata/syncthing";
  guiPort = 8384;
  uid = toString config.users.users.z.uid;
  gid = toString config.users.groups.${config.users.users.z.group}.gid;
in
{
  systemd.tmpfiles.rules = [ "d ${dataDir} 0750 ${uid} ${gid} - -" ];

  virtualisation.oci-containers.containers.syncthing = {
    inherit image;
    environment = {
      PUID = uid;
      PGID = gid;
      STGUIADDRESS = "127.0.0.1:${toString guiPort}";
    };
    volumes = [ "${dataDir}:/var/syncthing" ];
    extraOptions = [ "--network=host" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "syncthing";
      "tsdproxy.port.1" = "443/https:${toString guiPort}/http";
    };
  };

  # Sync protocol and local discovery need to reach real peers on the LAN
  # (and, via trustedInterfaces, the tailnet) — unlike the GUI, these are not
  # meant to be loopback-only.
  networking.firewall.allowedTCPPorts = [ 22000 ];
  networking.firewall.allowedUDPPorts = [
    22000
    21027
  ];

  services.traefik.dynamicConfigOptions.http = {
    routers = {
      syncthing = {
        rule = "Host(`syncthing.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "syncthing-svc";
      };
      "syncthing-dev" = {
        rule = "Host(`syncthing.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "syncthing-svc";
      };
    };
    services.syncthing-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString guiPort}"; } ];
  };
}
