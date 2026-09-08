{ config, pkgs, lib, ... }:

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
      clients.persistent = map (c: c // { use_global_settings = true; }) [
        { name = "router"; ids = [ "192.168.8.1" ]; }
        { name = "hopper"; ids = [ "192.168.8.10" ]; }
        { name = "pegasus"; ids = [ "192.168.8.72" ]; }
        { name = "memory-alpha-2"; ids = [ "192.168.8.98" ]; }
        { name = "memory-alpha"; ids = [ "192.168.8.99" ]; }
        { name = "homeassistant"; ids = [ "192.168.8.142" ]; }
        { name = "galactica"; ids = [ "192.168.8.190" ]; }
        { name = "towerbmc"; ids = [ "192.168.8.191" ]; }
        # hamilton: not in service, no known IP — add once it exists.
      ];

      # Every importer of this module (galactica live; hopper/hamilton staged)
      # gets the same client list — keep it host-agnostic.
    };
  };

  # Only DNS is exposed on the LAN; the web UI stays behind Traefik/tailnet.
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
