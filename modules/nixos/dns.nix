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
      };
      # Add filter lists / clients declaratively here as you settle them, e.g.
      # filters = [ { enabled = true; url = "..."; name = "..."; id = 1; } ];
    };
  };

  # Only DNS is exposed on the LAN; the web UI stays behind Traefik/tailnet.
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
