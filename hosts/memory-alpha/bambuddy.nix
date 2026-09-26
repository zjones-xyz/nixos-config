{ config, pkgs, lib, ... }:

# Bambuddy — Bambu Lab printer command center. Ported from homelab-stacks'
# unmerged feat/bambuddy-migrate-to-memory-alpha compose stack; why this host
# (spare NIC for the printer network, Obico alongside) and the bring-up are in
# MANUAL-STEPS.md §1.
#
# Addresses on bambuddy-lan are container-only, riding on eth-secondary (the
# MAC-pinned dongle in configuration.nix) — not addresses of eth-secondary:
#   .98       Bambuddy itself — the real printer's MQTT/FTPS/RTSP peer, and
#             memory-alpha-2.internal (galactica's AdGuard).
#   .95–.97   VP-athena / VP-conway / VP-queue. Each virtual printer needs its
#             own address: the slicer bind/detect ports (3000/3002/2024-2026)
#             are fixed by the Bambu LAN protocol and can't be shared.
# All four must stay out of the router's DHCP pool.

let
  image = "ghcr.io/maziggy/bambuddy:1.2.5.6";
  dataDir = "/home/z/bambuddy";
  libraryDir = "/mnt/bambuddy_library";
  controlIp = "192.168.8.98";
  vpIps = [ "192.168.8.95" "192.168.8.96" "192.168.8.97" ];
  docker = "${config.virtualisation.docker.package}/bin/docker";
in
{
  # galactica's share, exported LAN-wide as fsid 103. Same options as the
  # media mounts in configuration.nix.
  fileSystems.${libraryDir} = {
    device = "tower.internal:/tank/bambuddy_library";
    fsType = "nfs";
    options = [ "nfsvers=4" "soft" "timeo=30" "noauto" "nofail" "x-systemd.automount" "noatime" ];
  };

  # Under /home/z so borgmatic.nix's `/home/z` source already covers it. That
  # includes data/.mfa_encryption_key, which Bambuddy generates on first start
  # (no MFA_ENCRYPTION_KEY, deliberately; see MANUAL-STEPS.md §1).
  systemd.tmpfiles.rules = [
    "d ${dataDir}      0750 z users - -"
    "d ${dataDir}/data 0750 z users - -"
    "d ${dataDir}/logs 0750 z users - -"
  ];

  # ── Printer-facing network ────────────────────────────────────────────────
  # ipvlan, not macvlan: it shares the host's MAC, and USB Ethernet chipsets
  # are unreliable with several. Every address here is static, so --ip-range
  # (.80–.87) only fences off accidental auto-assignment.
  # The host takes no address on eth-secondary. Under NetworkManager it would
  # DHCP one, and a lease on .98 would collide with Bambuddy's own address.
  networking.networkmanager.unmanaged = [ "interface-name:eth-secondary" ];

  systemd.services.docker-bambuddy-lan-network = {
    description = "Create the Bambuddy printer-facing ipvlan network";
    # A USB dongle: wait for it, and go down with it if it's unplugged.
    after = [ "docker.service" "sys-subsystem-net-devices-eth\\x2dsecondary.device" ];
    requires = [ "docker.service" ];
    bindsTo = [ "sys-subsystem-net-devices-eth\\x2dsecondary.device" ];
    before = [ "docker-bambuddy.service" ];
    requiredBy = [ "docker-bambuddy.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Unmanaged means nothing else brings the link up.
      ExecStartPre = "${pkgs.iproute2}/bin/ip link set eth-secondary up";
      ExecStart = "${pkgs.bash}/bin/bash -c '${docker} network inspect bambuddy-lan >/dev/null 2>&1 || ${docker} network create --driver=ipvlan --subnet=192.168.8.0/24 --gateway=192.168.8.1 --ip-range=192.168.8.80/29 --opt parent=eth-secondary --opt ipvlan_mode=l2 bambuddy-lan'";
    };
  };

  # The library is only wanted: printer control must come up even while
  # galactica is down. `rslave` lets a later NFS mount reach the container.
  systemd.services.docker-bambuddy = {
    after = [ "docker-proxy-network.service" "mnt-bambuddy_library.mount" ];
    requires = [ "docker-proxy-network.service" ];
    wants = [ "mnt-bambuddy_library.mount" ];
    wantedBy = [ "sys-subsystem-net-devices-eth\\x2dsecondary.device" ];
    unitConfig.RequiresMountsFor = [ dataDir ];
  };

  virtualisation.oci-containers.containers.bambuddy = {
    inherit image;
    environment = {
      TZ = config.time.timeZone;
      # z:users — NixOS puts normal users in `users` (100), not a per-user group.
      PUID = "1000";
      PGID = "100";
      PORT = "8000";
      BAMBUDDY_EXTERNAL_ROOTS = "/external/bambuddy_library";
      VIRTUAL_PRINTER_PASV_ADDRESS = controlIp;
    };
    # tsdproxy (homelab-stacks memory-alpha/tsdproxy) reaches services via
    # host.docker.internal, so the UI has to be host-published.
    ports = [ "8001:8000" ];
    volumes = [
      "${dataDir}/data:/app/data"
      "${dataDir}/logs:/app/logs"
      "${libraryDir}:/external/bambuddy_library:rslave"
    ];
    labels = {
      "traefik.enable" = "true";
      "traefik.http.routers.bambuddy-internal.rule" = "Host(`bambuddy.memory-alpha.internal`)";
      "traefik.http.routers.bambuddy-internal.entrypoints" = "websecure";
      "traefik.http.routers.bambuddy-internal.tls" = "true";
      "traefik.http.routers.bambuddy-internal.service" = "bambuddy";
      "traefik.http.routers.bambuddy-dev.rule" = "Host(`bambuddy.3dp.zjones.dev`)";
      "traefik.http.routers.bambuddy-dev.entrypoints" = "websecure";
      "traefik.http.routers.bambuddy-dev.tls.certresolver" = "letsencrypt";
      "traefik.http.routers.bambuddy-dev.service" = "bambuddy";
      "traefik.http.services.bambuddy.loadbalancer.server.port" = "8000";
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "bambuddy";
      "tsdproxy.port.1" = "443/https:8001/http";
    };
    extraOptions = [
      # gw-priority: default route via the bridge, not the printer dongle.
      "--network=name=proxy,gw-priority=1"
      "--network=name=bambuddy-lan,ip=${controlIp}"
      "--security-opt=no-new-privileges"
      "--cgroup-parent=system-maker.slice"
    ];
  };

  # ── Virtual-printer addresses ─────────────────────────────────────────────
  # A container gets one static IP per network, so the other three are added
  # to its ipvlan interface from the host. Bambuddy never holds NET_ADMIN.
  # Bound to the container unit: a new container is a new network namespace,
  # so every (re)start must re-add them.
  systemd.services.bambuddy-vp-ips = {
    description = "Attach Bambuddy's virtual-printer addresses";
    after = [ "docker-bambuddy.service" ];
    bindsTo = [ "docker-bambuddy.service" ];
    wantedBy = [ "docker-bambuddy.service" ];
    path = [ config.virtualisation.docker.package pkgs.iproute2 pkgs.util-linux pkgs.gawk ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Generous: on first start, `docker run` is still pulling the image.
      pid=0
      for _ in $(seq 600); do
        pid=$(docker inspect --format '{{.State.Pid}}' bambuddy 2>/dev/null || echo 0)
        [ "$pid" != 0 ] && break
        sleep 1
      done
      [ "$pid" != 0 ] || { echo "bambuddy container never started" >&2; exit 1; }

      iface=$(nsenter -t "$pid" -n ip -4 -o addr show to ${controlIp}/32 | awk '{print $2}')
      [ -n "$iface" ] || { echo "no interface holds ${controlIp}" >&2; exit 1; }
      for ip in ${lib.concatStringsSep " " vpIps}; do
        nsenter -t "$pid" -n ip addr replace "$ip/32" dev "$iface"
      done
      echo "VP addresses attached to $iface"
    '';
  };
}
