{ config, pkgs, lib, ... }:

let
  fleetLib = import ../../fleet/lib.nix { inherit lib; };

  # Same eight names/IPs as before, now sourced from homelab.fleet.hosts
  # (modules/nixos/fleet.nix, fleet/hosts.nix) instead of hardcoded here.
  # Order is explicit, not derived by enumerating the registry (Nix attrsets
  # always enumerate alphabetically, which would reorder this list) — it
  # matches AdGuardHome.yaml's existing client order byte-for-byte, which
  # the Phase 1 no-op proof (`jq -S .` — sorts object keys, not array
  # elements) depends on.
  clientOrder = [
    "router"
    "hopper"
    "pegasus"
    "memory-alpha-2"
    "memory-alpha"
    "homeassistant"
    "galactica"
    "towerbmc"
    # hamilton: not yet deployed, no known IP — add once it exists.
  ];
in
{
  # DNS stack: AdGuard Home (LAN-facing filter) → Unbound (recursive resolver).
  #
  #   client → AdGuard Home :53 (LAN)  →  Unbound 127.0.0.1:5335 (localhost only)
  #
  # Unbound is the recursive resolver and is NOT an open resolver — it listens
  # on localhost only and answers nothing from the LAN. AdGuard is the single
  # thing bound to :53 on the network.

  # NetworkManager would otherwise hand DNS to systemd-resolved, whose stub
  # listener squats on 127.0.0.53:53. Disable it so AdGuard can own :53 and so
  # the box resolves through AdGuard like every other client.
  services.resolved.enable = false;

  # ── Unbound: localhost-only recursive resolver ─────────────────────────────
  services.unbound = {
    enable = true;
    # AdGuard manages the root hints / forwarding; don't let unbound also try to
    # write a resolv.conf or register as the system resolver.
    resolveLocalQueries = false;
    settings = {
      server = {
        interface = [ "127.0.0.1" ];
        port = 5335;
        access-control = [ "127.0.0.1/32 allow" ];
        # Sensible recursive-resolver hardening.
        hide-identity = true;
        hide-version = true;
        harden-glue = true;
        harden-dnssec-stripped = true;
        use-caps-for-id = false;
        prefetch = true;
        edns-buffer-size = 1232;
        # Don't leak private ranges out to the internet.
        private-address = [
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "169.254.0.0/16"
          "fd00::/8"
          "fe80::/10"
        ];
      };
    };
  };

  # ── AdGuard Home: LAN-facing filtering DNS + web UI ────────────────────────
  services.adguardhome = {
    enable = true;
    # Fully declarative config — the web UI becomes read-only for settings.
    mutableSettings = false;
    # We open ports ourselves (web UI goes through Traefik, DNS is opened below).
    openFirewall = false;
    host = "127.0.0.1";   # web UI bind; Traefik proxies to it
    port = 3000;          # web UI port
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];   # serve DNS to the LAN
        port = 53;
        # Forward everything to the local Unbound recursive resolver.
        upstream_dns = [ "127.0.0.1:5335" ];
        # Bootstrap is only used to resolve upstream hostnames — irrelevant
        # here since upstream is an IP, but AdGuard wants it set.
        bootstrap_dns = [ "127.0.0.1:5335" ];
        # Don't fall back to public resolvers; keep all recursion in Unbound.
        upstream_mode = "load_balance";
        ratelimit = 0;
      };
      # ── Filter lists ────────────────────────────────────────────────────────
      filters = [
        { enabled = true; id = 1; name = "AdGuard DNS filter";
          url = "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"; }
        { enabled = true; id = 2; name = "OISD Small";
          url = "https://small.oisd.nl/"; }
        { enabled = true; id = 3; name = "AdAway Default Blocklist";
          url = "https://raw.githubusercontent.com/AdAway/adaway.github.io/master/hosts.txt"; }
      ];

      # ── Global filtering policy ─────────────────────────────────────────────
      filtering = {
        safebrowsing_enabled = false;
        parental_enabled = false;
        safe_search.enabled = false;
      };

      # ── Per-client names ────────────────────────────────────────────────────
      # Identify devices by IP so the AdGuard UI/query log reads by name
      # instead of address. `ids` also accepts IPv6, MAC, CIDR, or a
      # DoH/DoT ClientID. With mutableSettings = false, this has to be
      # declared here — the web UI can't hold it across a rebuild.
      # use_global_settings defaults to Go's zero-value `false` when omitted
      # (same class of bug as the rewrites' `enabled` field) — without it,
      # AdGuard disables filtering, rewrites included, specifically for
      # queries sourced *from* these IPs, which silently broke DNS
      # resolution for every fleet host talking to another fleet host
      # (confirmed live, 2026-09-08 — the router replica inherited the same
      # bug via AdGuardHome-Sync, since it just mirrors whatever origin
      # reports).
      clients.persistent = map (c: c // { use_global_settings = true; }) (
        map (name: {
          inherit name;
          ids = [ config.homelab.fleet.hosts.${name}.ip ];
        }) clientOrder
      );

      # Note: hopper and hamilton also import this module (currently dead
      # code — hosts/README-rpi-os.md) alongside galactica, so any clients
      # defined here would appear on all instances that actually run it.

      # ── Generated service rewrites (fleet/services.nix) ────────────────────
      # Appended to, not replacing, galactica's hand-written list below it in
      # its own configuration.nix — the module system concatenates list
      # definitions of the same freeform-settings path. Order between the two
      # lists is therefore undefined; that's fine, AdGuard's rewrite lookup
      # doesn't depend on file order, and the Phase 1 no-op proof sorts by
      # domain before comparing. Only the three rows fleet/services.nix seeds
      # today (jellyfin.zjones.dev/.xyz, guesthome.zjones.xyz) come from here
      # — see fleet/services.nix and fleet/lib.nix's `rewritesFor`.
      filtering.rewrites = fleetLib.rewritesFor {
        hosts = config.homelab.fleet.hosts;
        services = config.homelab.fleet.services;
        splitHorizonGlobal = config.homelab.dns.splitHorizon;
      };
    };
  };

  # Only DNS is exposed on the LAN; the web UI stays behind Traefik/tailnet.
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
