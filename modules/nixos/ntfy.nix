{ config, pkgs, lib, ... }:

{
  # ntfy — push notifications. Native NixOS module (services.ntfy-sh).
  # Used by the NUT module (nut.nix) for UPS power alerts on the "ups" topic,
  # and available for Uptime Kuma / other services.
  #
  # Listens on localhost; Traefik terminates TLS at ntfy.hopper.internal.
  # base-url must match the externally-reachable URL for the web app / links.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.hopper.internal";
      listen-http = "127.0.0.1:2586";
      behind-proxy = true;
      # Lock down who can publish/subscribe once you've created users:
      #   auth-default-access = "deny-all";
      # and manage tokens with `ntfy user` / `ntfy access`.
    };
  };
}
