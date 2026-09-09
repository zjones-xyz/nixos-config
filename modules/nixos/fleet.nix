# ── Fleet host map — the 192.168.8.x source of truth ─────────────────────────
# Consumed by dns.nix (AdGuard per-client names, resorted by address) and
# hosts/galactica/configuration.nix (DNS rewrites, rendered in this order).
# Plain data, imported with `import ./fleet.nix` — not a module.
# A list, not an attrset: rewrite order groups by physical box with
# galactica's big legacy block last, and an attrset would resort it.
#
# `domains` are the exact rewrite names answering with the host's IP.
# `.zjones.dev` names are LAN-side, Traefik/LE-terminated. `.xyz` is the
# owner's convention for externally-routable names — terminated by Pangolin
# (tunneling to a Newt client), not Traefik, so no local router or cert is
# expected for these; the `.xyz` entries below are split-horizon shortcuts
# (LAN clients hit the box directly instead of round-tripping the tunnel).
[
  # router (GL.iNet)
  { name = "router"; ip = "192.168.8.1";
    domains = [ "router.internal" ]; }

  # hopper
  { name = "hopper"; ip = "192.168.8.10";
    domains = [ "hopper.internal" ]; }

  # pegasus
  { name = "pegasus"; ip = "192.168.8.72";
    domains = [ "pegasus.internal" ]; }

  # memory-alpha-2
  { name = "memory-alpha-2"; ip = "192.168.8.98";
    domains = [
      "memory-alpha-2.internal"
      "*.memory-alpha-2.internal"
    ]; }

  # memory-alpha (the legacy name "nixie" is retired, no longer in use)
  { name = "memory-alpha"; ip = "192.168.8.99";
    domains = [
      "memory-alpha.internal"
      "*.memory-alpha.internal"
      "*.memory-alpha.zjones.dev"
      "*.monitor.zjones.dev"
      # jellyfin.zjones.dev: flat name, not *.memory-alpha.zjones.dev —
      # Traefik (modules/nixos/traefik.nix, on memory-alpha) already routes
      # it with its own single-name LE cert.
      "jellyfin.zjones.dev"
      # jellyfin.zjones.xyz: split-horizon for the Pangolin-tunneled public
      # name — Newt runs on memory-alpha (jellyfin.nix), so this is a LAN
      # clients-only bypass, not a second route.
      "jellyfin.zjones.xyz"
    ]; }

  # homeassistant — deliberately no `.xyz` name: stays Tailscale/LAN-only.
  { name = "homeassistant"; ip = "192.168.8.142";
    domains = [ "homeassistant.internal" ]; }

  # towerbmc (Tower's physical BMC/IPMI — separate NIC from galactica itself)
  { name = "towerbmc"; ip = "192.168.8.191";
    domains = [ "towerbmc.internal" ]; }

  # galactica — also answers to the legacy names "tower" and "arr"
  # (identities it absorbed, hosts/galactica/DECISIONS.md §2). The *arr
  # stack's `.xyz` route was dropped entirely (owner's call: not needed).
  { name = "galactica"; ip = "192.168.8.190";
    domains = [
      "galactica.internal"
      "*.galactica.internal"
      "*.galactica.zjones.dev"
      "tower.internal"
      "*.tower.internal"
      "tower.zjones.dev"
      "*.tower.zjones.dev"
      "arr.internal"
      "*.arr.internal"
      "arr.zjones.dev"
      "*.arr.zjones.dev"
      "guesthome.zjones.xyz"
    ]; }

  # hamilton: not yet deployed, no known IP — add once it exists.
]
