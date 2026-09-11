{ config, pkgs, lib, ... }:

# ── The two dashboards, re-homed from Tower's Unraid Docker ─────────────────
# (homelab-stacks tower/homepage and tower/guesthome, dead since the
# bare-metal cutover.) Same Homepage app twice, different audiences:
#   admin — full service directory; home.{internal,zjones.dev} (Traefik) +
#           galactica.peacock-koi.ts.net (Tailscale serve).
#   guest — friends-and-family links; guest.{internal,zjones.dev} (Traefik,
#           LAN) and guest.zjones.xyz (Pangolin tunnel, off-network —
#           homelab.newt in configuration.nix).
# Dashboard content lives in ./homepage as plain YAML — edit there, `nrs`.
# MANUAL-STEPS.md §13 has the owner steps that put both on the network.

let
  # Pinned for the same reason as the socket proxy in traefik-galactica.nix:
  # with pull="missing", :latest resolves once and then never updates.
  image = "ghcr.io/gethomepage/homepage:v2.2.0";

  # Per-file read-only mounts, so /app/config itself stays writable for the
  # logs/ directory Homepage creates at startup. Each instance gets the shared
  # `common/` dir (custom.css) plus its own. Enumerated with readDir rather
  # than a hand-kept list: a file added to ./homepage would otherwise lint
  # clean in CI while never actually reaching the container.
  mkConfigMounts = dirs:
    lib.concatMap
      (dir: lib.mapAttrsToList
        (name: _: "${dir}/${name}:/app/config/${name}:ro")
        (lib.filterAttrs (_: type: type == "regular") (builtins.readDir dir)))
      dirs;
in
{
  # ── Widget API keys → HOMEPAGE_VAR_* ──────────────────────────────────────
  # Reuses the nixflix/* keys already in secrets/galactica.yaml. Two separate
  # env files on purpose: the guest container is publicly reachable through
  # Pangolin, so it only carries the three keys its calendar widget needs.
  # checks/homepage-config reads these two lists back and fails the build if
  # either instance's YAML references a key its own file does not define.
  sops.templates."homepage-admin.env".content = ''
    HOMEPAGE_VAR_SONARR_API_KEY=${config.sops.placeholder."nixflix/sonarrApiKey"}
    HOMEPAGE_VAR_SONARR_ANIME_API_KEY=${config.sops.placeholder."nixflix/sonarrAnimeApiKey"}
    HOMEPAGE_VAR_RADARR_API_KEY=${config.sops.placeholder."nixflix/radarrApiKey"}
    HOMEPAGE_VAR_LIDARR_API_KEY=${config.sops.placeholder."nixflix/lidarrApiKey"}
    HOMEPAGE_VAR_PROWLARR_API_KEY=${config.sops.placeholder."nixflix/prowlarrApiKey"}
    HOMEPAGE_VAR_SABNZBD_API_KEY=${config.sops.placeholder."nixflix/sabnzbdApiKey"}
  '';

  sops.templates."homepage-guest.env".content = ''
    HOMEPAGE_VAR_SONARR_API_KEY=${config.sops.placeholder."nixflix/sonarrApiKey"}
    HOMEPAGE_VAR_SONARR_ANIME_API_KEY=${config.sops.placeholder."nixflix/sonarrAnimeApiKey"}
    HOMEPAGE_VAR_RADARR_API_KEY=${config.sops.placeholder."nixflix/radarrApiKey"}
  '';

  # Loopback-only publishes: both instances are reached through Traefik
  # (router pairs below) or, for admin, Tailscale serve — nothing dials
  # either port from the LAN directly. Guest also gets a Pangolin tunnel
  # (homelab.newt) for its public `.zjones.xyz` name; that's a DNS-level
  # split-horizon and a Newt resource target, not a second Traefik route.
  virtualisation.oci-containers.containers = {
    homepage-admin = {
      inherit image;
      environment.HOMEPAGE_ALLOWED_HOSTS =
        "home.internal,home.zjones.dev,galactica.peacock-koi.ts.net";
      environmentFiles = [ config.sops.templates."homepage-admin.env".path ];
      ports = [ "127.0.0.1:3010:3000" ];
      volumes = mkConfigMounts [ ./homepage/common ./homepage/admin ];
    };

    homepage-guest = {
      inherit image;
      environment.HOMEPAGE_ALLOWED_HOSTS =
        "guest.internal,guest.zjones.dev,guest.zjones.xyz";
      environmentFiles = [ config.sops.templates."homepage-guest.env".path ];
      ports = [ "127.0.0.1:3011:3000" ];
      volumes = mkConfigMounts [ ./homepage/common ./homepage/guest ];
    };
  };

  # ── Traefik routes — flat top-level names, not arrExtraUpstreams ───────────
  # `homelab.arrExtraUpstreams` (bazarr.nix's mechanism) only ever produces
  # `*.arr.{internal,zjones.dev}` names, so these dashboards register their
  # own router pairs directly instead, same shape as configuration.nix's
  # `adguard`/`adguard-dev` pair. `guest.zjones.xyz` is NOT routed here —
  # per dns.nix's rewrites comment, `.xyz` names are terminated by Pangolin
  # (a Newt tunnel target), not Traefik. Neither `home.zjones.dev` nor
  # `guest.zjones.dev` falls under the arr wildcard's SAN list
  # (`*.arr.zjones.dev`), so each requests its own single-name LE
  # cert — the same one-time cost the adguard pair already accepted.
  services.traefik.dynamicConfigOptions.http = {
    routers = {
      home = {
        rule = "Host(`home.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "home-svc";
      };
      "home-dev" = {
        rule = "Host(`home.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "home-svc";
      };
      guest = {
        rule = "Host(`guest.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "guest-svc";
      };
      "guest-dev" = {
        rule = "Host(`guest.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "guest-svc";
      };
    };
    services = {
      home-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:3010"; } ];
      guest-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:3011"; } ];
    };
  };
}
