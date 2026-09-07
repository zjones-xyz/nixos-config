{ config, pkgs, lib, ... }:

# ── The two dashboards, re-homed from Tower's Unraid Docker ─────────────────
# (homelab-stacks tower/homepage and tower/guesthome, dead since the
# bare-metal cutover.) Same Homepage app twice, different audiences:
#   admin — full service directory; home.{internal,zjones.dev} (Traefik) +
#           galactica.peacock-koi.ts.net (Tailscale serve).
#   guest — friends-and-family links; guest.{internal,zjones.dev} (Traefik,
#           LAN) and guest.zjones.xyz (Pangolin tunnel, off-network —
#           homelab.newt in configuration.nix).
# Config is nix-rendered store files bind-mounted read-only; edit here, `nrs`.
# MANUAL-STEPS.md §13 has the owner steps that put both on the network.

let
  # Pinned for the same reason as the socket proxy in traefik-galactica.nix:
  # with pull="missing", :latest resolves once and then never updates.
  image = "ghcr.io/gethomepage/homepage:v2.2.0";

  # JetBrains Darcula ramp, shared by both instances. Homepage builds its UI
  # from the .theme-<color> Tailwind ramp; `color: stone` in each
  # settings.yaml is what this override targets.
  customCss = pkgs.writeText "homepage-custom.css" ''
    .theme-stone {
      --color-50: 211 211 211;   /* #D3D3D3  lightest text   */
      --color-100: 187 187 187;  /* #BBBBBB  UI text          */
      --color-200: 169 183 198;  /* #A9B7C6  Darcula default text */
      --color-300: 140 152 163;  /* muted                     */
      --color-400: 104 151 187;  /* #6897BB  number blue      */
      --color-500: 75 110 175;   /* #4B6EAF  accent / highlight */
      --color-600: 60 63 65;     /* #3C3F41  panel            */
      --color-700: 49 51 53;     /* #313335                   */
      --color-800: 43 43 43;     /* #2B2B2B  Darcula editor bg */
      --color-900: 30 30 30;     /* #1E1E1E  deepest bg        */
    }
  '';

  # Widget/link URLs go through Traefik's public-DNS names (real LE certs,
  # split-horizon to the LAN address) — NOT 127.0.0.1, which inside the
  # container is the container. Works identically from both instances.
  # `siteMonitor` mirrors `href` on every entry: Homepage does its own
  # periodic HTTP status check against that URL (independent of any
  # `widget:` block) and shows a colored dot next to the service name —
  # so every entry gets a live up/down indicator, not just the ones with
  # an API-backed widget.
  adminConfig = {
    "custom.css" = customCss;

    "settings.yaml" = pkgs.writeText "homepage-admin-settings.yaml" ''
      title: Home
      theme: dark
      # Darcula palette comes from custom.css overriding the stone ramp.
      color: stone
      headerStyle: clean
      target: _blank

      layout:
        Media:
          style: row
          columns: 2
        Media Management:
          style: row
          columns: 4
        Downloads:
          style: row
          columns: 2
        Infrastructure:
          style: row
          columns: 4
    '';

    # Live services only. The Tower services that have not been re-homed yet
    # (Jellyseerr, Audiobookshelf, Grimmory, Shelfmark, Immich, Paperless,
    # Karakeep, ARM, 13ft, Bambuddy) come back one group entry at a time as
    # each migrates — homelab-stacks tower/homepage/config/services.yaml is
    # the reference for what each entry looked like.
    "services.yaml" = pkgs.writeText "homepage-admin-services.yaml" ''
      - Media:
          - Jellyfin:
              href: https://jellyfin.zjones.dev
              siteMonitor: https://jellyfin.zjones.dev
              icon: jellyfin.png
              description: Streaming (memory-alpha)
          - Navidrome:
              href: https://navidrome.arr.zjones.dev
              siteMonitor: https://navidrome.arr.zjones.dev
              icon: navidrome.png
              description: Music

      - Media Management:
          - Sonarr:
              href: https://sonarr.arr.zjones.dev
              siteMonitor: https://sonarr.arr.zjones.dev
              icon: sonarr.png
              description: TV
              widget:
                type: sonarr
                url: https://sonarr.arr.zjones.dev
                key: "{{HOMEPAGE_VAR_SONARR_API_KEY}}"
          - Sonarr (Anime):
              href: https://sonarr-anime.arr.zjones.dev
              siteMonitor: https://sonarr-anime.arr.zjones.dev
              icon: sonarr.png
              description: Anime
              widget:
                type: sonarr
                url: https://sonarr-anime.arr.zjones.dev
                key: "{{HOMEPAGE_VAR_SONARR_ANIME_API_KEY}}"
          - Radarr:
              href: https://radarr.arr.zjones.dev
              siteMonitor: https://radarr.arr.zjones.dev
              icon: radarr.png
              description: Movies
              widget:
                type: radarr
                url: https://radarr.arr.zjones.dev
                key: "{{HOMEPAGE_VAR_RADARR_API_KEY}}"
          - Lidarr:
              href: https://lidarr.arr.zjones.dev
              siteMonitor: https://lidarr.arr.zjones.dev
              icon: lidarr.png
              description: Music
              widget:
                type: lidarr
                url: https://lidarr.arr.zjones.dev
                key: "{{HOMEPAGE_VAR_LIDARR_API_KEY}}"
          - Bazarr:
              href: https://bazarr.arr.zjones.dev
              siteMonitor: https://bazarr.arr.zjones.dev
              icon: bazarr.png
              description: Subtitles
          - Bazarr (Anime):
              href: https://bazarr-anime.arr.zjones.dev
              siteMonitor: https://bazarr-anime.arr.zjones.dev
              icon: bazarr.png
              description: Anime subtitles
          - Prowlarr:
              href: https://prowlarr.arr.zjones.dev
              siteMonitor: https://prowlarr.arr.zjones.dev
              icon: prowlarr.png
              description: Indexers
              widget:
                type: prowlarr
                url: https://prowlarr.arr.zjones.dev
                key: "{{HOMEPAGE_VAR_PROWLARR_API_KEY}}"

      - Downloads:
          - qBittorrent:
              href: https://qbittorrent.arr.zjones.dev
              siteMonitor: https://qbittorrent.arr.zjones.dev
              icon: qbittorrent.png
              description: Torrents
          - SABnzbd:
              href: https://usenet.arr.zjones.dev
              siteMonitor: https://usenet.arr.zjones.dev
              icon: sabnzbd.png
              description: Usenet
              widget:
                type: sabnzbd
                url: https://usenet.arr.zjones.dev
                key: "{{HOMEPAGE_VAR_SABNZBD_API_KEY}}"

      - Infrastructure:
          - Traefik:
              href: https://traefik.arr.zjones.dev
              siteMonitor: https://traefik.arr.zjones.dev
              icon: traefik.png
              description: Reverse proxy (this host)
          - Uptime Kuma:
              href: https://kuma.monitor.zjones.dev
              siteMonitor: https://kuma.monitor.zjones.dev
              icon: uptime-kuma.png
              description: Uptime monitoring
          - Beszel:
              href: https://beszel.monitor.zjones.dev
              siteMonitor: https://beszel.monitor.zjones.dev
              icon: sh-beszel
              description: Host monitoring
          - Scrutiny:
              href: https://scrutiny.monitor.zjones.dev
              siteMonitor: https://scrutiny.monitor.zjones.dev
              icon: scrutiny.png
              description: Disk health
          - Dozzle:
              href: https://dozzle.monitor.zjones.dev
              siteMonitor: https://dozzle.monitor.zjones.dev
              icon: dozzle.png
              description: Container logs
          - ntfy:
              href: https://ntfy.monitor.zjones.dev
              siteMonitor: https://ntfy.monitor.zjones.dev
              icon: ntfy.png
              description: Notifications
          - Arcane:
              href: https://arcane.monitor.zjones.dev
              siteMonitor: https://arcane.monitor.zjones.dev
              icon: sh-arcane
              description: Container management
          - Dockge:
              href: https://dockge.memory-alpha.zjones.dev
              siteMonitor: https://dockge.memory-alpha.zjones.dev
              icon: dockge.png
              description: Compose stacks
    '';

    "bookmarks.yaml" = pkgs.writeText "homepage-admin-bookmarks.yaml" ''
      - Reference:
          - Homepage docs:
              - abbr: HP
                href: https://gethomepage.dev
          - Dashboard icons:
              - abbr: IC
                href: https://github.com/walkxcode/dashboard-icons
    '';

    "widgets.yaml" = pkgs.writeText "homepage-admin-widgets.yaml" ''
      - resources:
          label: System
          cpu: true
          memory: true
          disk: /

      - search:
          provider: duckduckgo
          target: _blank

      - datetime:
          text_size: xl
          format:
            timeStyle: short
            dateStyle: short

      # Upcoming releases, pulled through the service widgets above.
      - calendar:
          firstDayInWeek: sunday
          view: agenda
          maxEvents: 10
          showTime: true
          integrations:
            - type: sonarr
              service_group: Media Management
              service_name: Sonarr
            - type: sonarr
              service_group: Media Management
              service_name: Sonarr (Anime)
            - type: radarr
              service_group: Media Management
              service_name: Radarr
    '';
  };

  guestConfig = {
    "custom.css" = customCss;

    "settings.yaml" = pkgs.writeText "homepage-guest-settings.yaml" ''
      title: Home
      theme: dark
      color: stone
      headerStyle: clean
      target: _blank

      layout:
        Media:
          style: row
          columns: 2
    '';

    # ⚠ Guest links must be names that resolve and route from the public
    # internet (Pangolin resources), since guest.zjones.xyz is the door
    # off-network — not the .arr.zjones.dev names the admin dashboard uses.
    # §13 step 6 verifies each before it goes live. Tower's guesthome also
    # listed Audiobookshelf, Grimmory, Shelfmark and 13ft — restore from
    # homelab-stacks tower/guesthome as each is re-homed.
    "services.yaml" = pkgs.writeText "homepage-guest-services.yaml" ''
      - Media:
          - Jellyfin:
              href: https://jellyfin.zjones.dev
              siteMonitor: https://jellyfin.zjones.dev
              icon: jellyfin.png
              description: Movies & TV
    '';

    "bookmarks.yaml" = pkgs.writeText "homepage-guest-bookmarks.yaml" ''
      []
    '';

    "widgets.yaml" = pkgs.writeText "homepage-guest-widgets.yaml" ''
      - search:
          provider: duckduckgo
          target: _blank

      - datetime:
          text_size: xl
          format:
            timeStyle: short
            dateStyle: short

      # What's coming to the library — direct integrations (no service
      # widgets on this instance; guests don't get queue/stats panels).
      - calendar:
          firstDayInWeek: sunday
          view: agenda
          maxEvents: 10
          showTime: true
          integrations:
            - type: sonarr
              url: https://sonarr.arr.zjones.dev
              key: "{{HOMEPAGE_VAR_SONARR_API_KEY}}"
            - type: sonarr
              url: https://sonarr-anime.arr.zjones.dev
              key: "{{HOMEPAGE_VAR_SONARR_ANIME_API_KEY}}"
            - type: radarr
              url: https://radarr.arr.zjones.dev
              key: "{{HOMEPAGE_VAR_RADARR_API_KEY}}"
    '';
  };

  # Per-file read-only mounts, so /app/config itself stays writable for the
  # logs/ directory Homepage creates at startup.
  mkConfigMounts = files: lib.mapAttrsToList (name: file: "${file}:/app/config/${name}:ro") files;
in
{
  # ── Widget API keys → HOMEPAGE_VAR_* ──────────────────────────────────────
  # Reuses the nixflix/* keys already in secrets/galactica.yaml. Two separate
  # env files on purpose: the guest container is publicly reachable through
  # Pangolin, so it only carries the three keys its calendar widget needs.
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
      volumes = mkConfigMounts adminConfig;
    };

    homepage-guest = {
      inherit image;
      environment.HOMEPAGE_ALLOWED_HOSTS =
        "guest.internal,guest.zjones.dev,guest.zjones.xyz";
      environmentFiles = [ config.sops.templates."homepage-guest.env".path ];
      ports = [ "127.0.0.1:3011:3000" ];
      volumes = mkConfigMounts guestConfig;
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
