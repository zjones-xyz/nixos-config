{ config, pkgs, lib, ... }:

# ── Syncthing — the fleet's one always-on sync hub ─────────────────────────
# Runs here rather than on pegasus/serenity because galactica is the one
# machine that's always on; the other two are peers that dial in. Reached at
# syncthing.internal/.zjones.dev (Traefik, below) and
# syncthing.peacock-koi.ts.net (tsdproxy, homepages.nix's own pattern) for
# the GUI. Actual device pairing (IDs, shared folders) isn't declared here —
# MANUAL-STEPS.md §15 has that; a config a fresh container hasn't generated
# yet has no device IDs to declare.

let
  image = "syncthing/syncthing:2.1.5";
in
{
  systemd.tmpfiles.rules = [ "d /tank/appdata/syncthing 0755 1000 1000 -" ];

  virtualisation.oci-containers.containers.syncthing = {
    inherit image;
    volumes = [ "/tank/appdata/syncthing:/var/syncthing" ];
    # Host networking, not the `proxy` bridge — same reasoning as
    # tsdproxy.nix: the sync protocol (22000) and LAN discovery (21027) need
    # to see real interfaces/addresses, which Docker's bridge NAT hides from
    # them (the upstream image's own README says so). This also means the
    # GUI's 127.0.0.1:8384 default is the HOST's loopback, which is exactly
    # what lets the native Traefik process below reach it.
    extraOptions = [ "--network=host" ];
    # Picked up by homelab.tsdproxy (tsdproxy.nix), which registers a
    # tailnet node of this name — port is the container's own since host
    # networking means there's no separate "published" port to track.
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "syncthing";
      "tsdproxy.port.1" = "443/https:8384/http";
    };
  };

  # ⚠ Host networking bypasses Docker's own NAT, so these are real host
  # firewall openings, unlike the loopback-only publishes elsewhere in this
  # repo (homepages.nix, dockge.nix) — trustedInterfaces already covers the
  # tailnet, so this is what LAN peers (pegasus) need.
  networking.firewall.allowedTCPPorts = [ 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];

  # ⚠ Ships with GUI authentication OFF. Set a username/password (Settings →
  # GUI) before relying on the .zjones.dev route below — same blocking step
  # bazarr.nix's MANUAL-STEPS item took, and for the same reason: nothing
  # here can seed a password before the container's first start generates a
  # config to hold one.
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
    services.syncthing-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:8384"; } ];
  };
}
