{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — the *arr media stack, via nixflix.
# ─────────────────────────────────────────────────────────────────────────────
# A clean rebuild of the Unraid stack; MANUAL-STEPS.md §12 is the run book.
# ⚠ Jellyfin and Seerr are OFF on purpose — no GPU, so playback stays on
# memory-alpha over NFS. This host is the acquisition/storage half only.
# The nixflix input is pinned to a canary-proven revision; flake.nix explains.

let
  # ── One ZFS dataset, two plain subdirectories ─────────────────────────────
  # ⚠ Load-bearing: hardlinks cannot cross ZFS datasets and the *arrs hardlink
  # imports. A later `zfs create tank/nixflix_media/downloads` silently turns
  # every import into a full copy. MANUAL-STEPS.md §12 "The one layout rule".
  base = "/tank/nixflix_media";
  mediaDir = "${base}/media";

  # Shared by the two ProtonVPN units below.
  netns = "wg";
  gateway = "10.2.0.1";

  # One login for all five *arrs — the sops block explains why one value.
  arrHostConfig = {
    username = "admin";
    password._secret = config.sops.secrets."nixflix/arrPassword".path;
  };
in

{
  # ── Where the stack lives ─────────────────────────────────────────────────
  nixflix = {
    enable = true;

    inherit mediaDir;
    downloadsDir = "${base}/downloads";

    # On the special vdev's SSD mirror with the rest of appdata — NOT the
    # unmirrored NVMe (DECISIONS.md §7). Consequence, accepted: nothing here
    # starts until tank is imported.
    stateDir = "/tank/appdata/nixflix";

    mediaUsers = [ "z" ];

    # tank is imported in stage-2 after the LUKS opens; without this the
    # services race the mount on every cold boot.
    serviceDependencies = [ "zfs-mount.service" ];

    # ── VPN (ProtonVPN, WireGuard) ──────────────────────────────────────────
    # Only qBittorrent is confined; the host's own networking is untouched.
    vpn = {
      enable = true;

      # ⚠ MUST be a P2P **and** port-forwarding server, or the NAT-PMP
      # sidecar below has nothing to map. In sops: it holds the private key.
      wgConfFile = config.sops.secrets."nixflix/protonWgConf".path;

      # ⚠ The fleet LAN is 192.168.8.0/24 (confirmed from live host addresses,
      # MANUAL-STEPS.md §8) — NOT the module's 192.168.1.0/24 default. With
      # the default left in place the confined services' web UIs are simply
      # unreachable from the LAN, which presents as "qBittorrent is down".
      accessibleFrom = [ "192.168.8.0/24" ];
    };

    # ── Indexers ────────────────────────────────────────────────────────────
    # Prowlarr reaches FlareSolverr on loopback; two upstream corrections
    # live below the nixflix block.
    flaresolverr.enable = true;

    prowlarr = {
      enable = true;
      config = {
        apiKey._secret = config.sops.secrets."nixflix/prowlarrApiKey".path;
        hostConfig = arrHostConfig;
      };
    };

    sonarr = {
      enable = true;
      mediaDirs = [ "${mediaDir}/tv" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/sonarrApiKey".path;
        hostConfig = arrHostConfig;
      };
    };

    radarr = {
      enable = true;
      mediaDirs = [ "${mediaDir}/movies" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/radarrApiKey".path;
        hostConfig = arrHostConfig;
      };
    };

    # ── Anime (series) ──────────────────────────────────────────────────────
    # A second first-class instance (port 8990), not a profile — and there is
    # deliberately no radarr-anime. MANUAL-STEPS.md §12 "Anime".
    sonarr-anime = {
      enable = true;
      mediaDirs = [ "${mediaDir}/anime" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/sonarrAnimeApiKey".path;
        hostConfig = arrHostConfig;
      };
    };

    # ── Quality profiles and custom formats (TRaSH guides) ──────────────────
    # What makes the clean rebuild affordable. The *arr keys pass through as
    # { _secret = path; }; the rendered YAML carries paths, not values.
    recyclarr = {
      enable = true;

      # Pinned, not the module default (same value today): this decides what
      # lands on a 4×12 TB array, and nothing here transcodes. Change
      # deliberately, not via `nix flake update`.
      sonarrQuality = "1080p";
      radarrQuality = "1080p";

      # ⚠ `cleanupUnmanagedProfiles` stays OFF: on, it deletes every profile
      # the managed list does not name, stock and hand-made included.
    };

    # ── Music: acquisition ──────────────────────────────────────────────────
    # ⚠ Points at a FRESH media/music. SHARES.md marks `music` Protected, and
    # Lidarr renames/moves/deletes under its root — import the old collection
    # copy-not-move. MANUAL-STEPS.md §12 "Music".
    lidarr = {
      enable = true;
      mediaDirs = [ "${mediaDir}/music" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/lidarrApiKey".path;
        hostConfig = arrHostConfig;
      };
    };

    # ── Music: playback ─────────────────────────────────────────────────────
    # Navidrome belongs here — audio transcoding is cheap (MANUAL-STEPS.md §12
    # "Music"). MusicFolder defaults to lidarr's mediaDirs head; read-only.
    navidrome = {
      enable = true;
      users.z = {
        # Required — defaults to null and fails the type check, rather than
        # being inferred from the attribute name.
        userName = "z";
        isAdmin = true;
        password._secret = config.sops.secrets."nixflix/navidromePassword".path;
        # ⚠ Applied at user CREATION only — and navidrome-users-config also
        # logs in WITH this value on every switch, so rotating the secret
        # alone both fails to change the login and breaks the next switch.
        # Rotate in Navidrome's UI FIRST, then here. MANUAL-STEPS.md §12.
      };
    };

    # ── Usenet ──────────────────────────────────────────────────────────────
    usenetClients.sabnzbd = {
      enable = true;

      # ⚠ Defaults to nixflix.vpn.enable, i.e. silently INTO the tunnel.
      # Deliberately outside: usenet is already TLS, the tunnel caps
      # throughput, and no inbound port is needed.
      vpn.enable = false;

      settings.misc = {
        api_key._secret = config.sops.secrets."nixflix/sabnzbdApiKey".path;
        nzb_key._secret = config.sops.secrets."nixflix/sabnzbdNzbKey".path;

        # SABnzbd refuses Host headers not listed here, and the module only
        # fills this from its own (unused) reverseProxy option. An omission
        # presents as a Traefik-looking 403 while loopback keeps working.
        # `usenet`, matching the Traefik subdomain (traefik-galactica.nix).
        host_whitelist = "usenet.arr.internal,usenet.arr.zjones.dev";
      };
    };

    # ── Torrents ────────────────────────────────────────────────────────────
    torrentClients.qbittorrent = {
      enable = true;

      # vpn.enable is left implicit: it follows nixflix.vpn.enable, which is
      # the intent — qBittorrent is the reason the VPN exists.

      # What the *arrs and the NAT-PMP sidecar authenticate WITH. qBittorrent's
      # own login is the PBKDF2 block below; the two must match.
      password._secret = config.sops.secrets."nixflix/qbittorrentPassword".path;

      # Cannot come from sops: the module reinstalls qBittorrent.conf from the
      # store on every start, so declarative is the only form that sticks.
      # ⚠ The hash pairs with nixflix/qbittorrentPassword — regenerate them
      # together or every client locks out. Generator: MANUAL-STEPS.md §12.
      serverConfig.Preferences.WebUI = {
        Username = "admin";
        Password_PBKDF2 = "@ByteArray(qLRngRuEr+F6yTqp9dj6/g==:m2eO3yy7JkTxaK0DoEiVA8hjNMOAn5qomGyBhTBCQYIR7UDQc+e/l8uQwCw+kvBDNO4BZ1K+J5FosAunqRw4KA==)";

        # qBittorrent rejects Hosts that are not its bind address — exactly
        # what a proxy sends. Off rather than whitelisted: the WebUI is only
        # reachable through Traefik anyway (firewall opens 80/443 only).
        HostHeaderValidation = false;

        # 192.168.15.5 is the host side of the wg bridge — Traefik's source
        # address when it reaches the confined WebUI.
        ReverseProxySupportEnabled = true;
        TrustedReverseProxiesList = "192.168.15.5";
      };

      # Declared so they survive: the module reinstalls qBittorrent.conf from
      # the store on every start, so a UI change lasts until the next restart.
      serverConfig.Preferences.General.StatusbarExternalIPDisplayed = true;

      serverConfig.BitTorrent = {
        ExcludedFileNamesEnabled = true;

        Session = {
          ExcludedFileNames = "*.exe";

          # KiB/s. Not a throttle — ~244 MiB/s is roughly a third of the link,
          # so it bounds a runaway without touching normal use.
          GlobalDLSpeedLimit = 250000;
          GlobalUPSpeedLimit = 250000;

          # Queueing is off, so the two Max* values are inert until it is
          # turned back on — kept so they survive rather than reset.
          QueueingSystemEnabled = false;
          MaxActiveDownloads = 2000;
          MaxActiveTorrents = 200;
        };
      };
    };
  };

  # ── FlareSolverr: two corrections to upstream's wiring ────────────────────
  # Local because we track upstream nixflix; delete when upstream adopts them.
  # MANUAL-STEPS.md §12 "FlareSolverr" carries the full argument.
  # (1) Upstream's 30s readiness probe dies inside the cold Chromium launch
  #     (43s on fast hardware) and an ExecStartPost failure kills the unit —
  #     a permanent restart loop. Raised to 180s.
  #     ⚠ TimeoutStartSec moves WITH it: the probe runs inside the start
  #     phase, where systemd's 90s default would kill it first.
  # (2) `requires` on flaresolverr relaxed to `wants`: a failed start CANCELS
  #     the dependent's job (result 'dependency' — no Restart, no visibility).
  #     Safe because the script only calls Prowlarr's API, with ?forceSave=true.
  #
  # Both guarded with mkIf: an unguarded override of a disabled service would
  # CREATE a bare unit systemd refuses.
  systemd.services.flaresolverr = lib.mkIf config.nixflix.flaresolverr.enable {
    serviceConfig = {
      # One curl retrying internally, not a curl+sleep fork pair per second on
      # the CPU that is busy launching the Chromium being waited for.
      ExecStartPost = lib.mkForce (
        pkgs.writeShellScript "wait-for-flaresolverr" ''
          ${pkgs.curl}/bin/curl -sf --retry 180 --retry-delay 1 --retry-all-errors --retry-connrefused \
            --max-time 5 --retry-max-time 180 \
            http://127.0.0.1:${toString config.nixflix.flaresolverr.port}/ >/dev/null 2>&1 || {
            echo "FlareSolverr did not become ready within 180s" >&2
            exit 1
          }
        ''
      );

      # 240 not 180: the probe's own message reports a slow start, rather
      # than systemd's generic timeout killing it mid-poll.
      TimeoutStartSec = 240;
    };
  };

  systemd.services.prowlarr-indexer-proxies = lib.mkIf config.nixflix.prowlarr.enable {
    requires = lib.mkForce [
      "prowlarr-config.service"
      "prowlarr-tags.service"
    ];
    wants = [ "flaresolverr.service" ];
  };

  # ── navidrome-create-admin: survive a slow first start ────────────────────
  # Upstream's oneshot has no Restart, so one timed-out readiness wait means
  # the admin is never created and nothing retries. The script is idempotent,
  # so retrying is safe.
  systemd.services.navidrome-create-admin = lib.mkIf config.nixflix.navidrome.enable {
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 30;
    };

    # Bounded, or "retries visibly" is false: the NixOS default burst (5 over
    # 10s) never trips at RestartSec = 30, and a unit cycling through
    # `activating` forever never reaches `failed` — less visible than failing
    # once. Five tries over half an hour rides out a slow boot, then stops.
    startLimitIntervalSec = 1800;
    startLimitBurst = 5;
  };

  # ── SABnzbd's per-category complete directories ───────────────────────────
  # nixflix's qBittorrent module makes a tmpfiles entry per category; its
  # SABnzbd module stops at `complete_dir`. So `complete/<category>` does not
  # exist until the first finished download there, and the *arrs report that as
  # "cannot see this directory… adjust the folder's permissions" — a misleading
  # guess, since they cannot tell missing from unreadable.
  #
  # Derived from the evaluated category list, so a new *arr cannot be left
  # without one. `*` is skipped: it means "default", not a subdirectory.
  systemd.tmpfiles.settings."11-sabnzbd-categories" = lib.mergeAttrsList (
    map
      (cat: {
        "${config.nixflix.usenetClients.sabnzbd.settings.misc.complete_dir}/${cat.dir}".d = {
          inherit (config.nixflix.usenetClients.sabnzbd) user group;
          mode = "0775";
        };
      })
      (
        lib.filter (cat: (cat.dir or "") != "")
          config.nixflix.usenetClients.sabnzbd.settings.categories
      )
  );

  # ── qBittorrent's umask ───────────────────────────────────────────────────
  # nixflix sets this for every *arr and SABnzbd defaults `permissions = 775`,
  # but its qBittorrent module sets neither and nor does nixpkgs' — so release
  # directories land 0755 and nothing else in `media` can write inside one.
  # ⚠ A umask covers new files only; MANUAL-STEPS §12 step 10 repairs the rest.
  systemd.services.qbittorrent = lib.mkIf config.nixflix.torrentClients.qbittorrent.enable {
    serviceConfig.UMask = "0002";
  };


  # ── ProtonVPN NAT-PMP → qBittorrent listen port ───────────────────────────
  # nixflix's vpn.openVPNPorts models a STATIC forwarded port; Proton only
  # hands out NAT-PMP leases (~60s, port changes on reconnect). Without this
  # loop no peer can initiate a connection, which kills seeding. If the
  # provider ever changes to static forwarding, delete this block and set
  # openVPNPorts instead.
  systemd.services.protonvpn-natpmp = {
    description = "Renew ProtonVPN NAT-PMP forward and publish it to qBittorrent";

    # In the namespace: natpmpc must reach Proton's gateway, and the WebUI
    # binds the namespace address.
    vpnConfinement = {
      enable = true;
      vpnNamespace = netns;
    };

    after = [ "qbittorrent.service" ];
    wants = [ "qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      # A supervised forever-loop, not a oneshot: the lease dies in ~60s and
      # the port changes across reconnects, so this must keep running.
      Restart = "always";
      RestartSec = 15;
      DynamicUser = true;
      LoadCredential = [
        "qbPassword:${config.sops.secrets."nixflix/qbittorrentPassword".path}"
      ];

      Environment = [
        # NOT 127.0.0.1 — confined, the WebUI binds the namespace address.
        # `connectionAddress` is the module's own derivation and follows if
        # the VPN is ever turned off.
        "QB_URL=http://${config.nixflix.torrentClients.qbittorrent.connectionAddress}:${toString config.nixflix.torrentClients.qbittorrent.webuiPort}"
        "QB_USER=admin"
        "GATEWAY=${gateway}"
      ];

      # writeShellApplication: shellcheck runs over the .sh at build time.
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "protonvpn-natpmp";
          runtimeInputs = with pkgs; [
            libnatpmp
            curl
            coreutils
          ];
          text = builtins.readFile ./protonvpn-natpmp.sh;
        }
      );
    };
  };

  # ── ProtonVPN tunnel health check ─────────────────────────────────────────
  # wg.service is a RemainAfterExit oneshot, so an outage AFTER boot is
  # silent: the namespace black-holes qBittorrent's packets and nothing fails.
  # ⚠ Handshake age, not reachability, is the signal — Proton's gateway may
  # ignore ICMP, so the ping exists only to provoke a rekey and its exit
  # status is deliberately ignored.
  systemd.services.protonvpn-healthcheck = {
    description = "Check the ProtonVPN tunnel is still carrying traffic";

    # Not confined: `wg show` needs CAP_NET_ADMIN, so root + `ip netns exec`.
    # Deliberately NOT BindsTo wg.service — that would CANCEL this job on wg
    # failure instead of failing it loudly, and loud is the point.
    after = [ "wg.service" ];

    serviceConfig = {
      Type = "oneshot";

      # MAX_AGE: WireGuard rekeys at 120s and expires sessions at 180s, so a
      # healthy tunnel never reads much past 180. 240 is that ceiling plus
      # margin — detection about four minutes behind an outage.
      Environment = [
        "NETNS=${netns}"
        "WG_IFACE=wg0"
        "GATEWAY=${gateway}"
        "MAX_AGE=240"
      ];

      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "protonvpn-healthcheck";
          runtimeInputs = with pkgs; [
            iproute2
            wireguard-tools
            iputils
            coreutils
            gawk
          ];
          text = builtins.readFile ./protonvpn-healthcheck.sh;
        }
      );
    };

    # ⟨Follow-up: route to ntfy⟩ — same reasoning and answer as the identical
    # note in modules/nixos/smart.nix. Until then the alarm is a failed unit.
  };

  systemd.timers.protonvpn-healthcheck = {
    description = "Periodic ProtonVPN tunnel health check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Past the tunnel coming up and the sidecar's first provoked handshake.
      OnBootSec = "3min";
      OnUnitActiveSec = "60s";
      AccuracySec = "10s";
      Unit = "protonvpn-healthcheck.service";
    };
  };

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # ⚠ Every secret must exist before this activates or sops-nix fails the
  # switch. MANUAL-STEPS.md §12 has the run book and generator commands.
  sops.secrets = {
    "nixflix/protonWgConf" = { };

    "nixflix/prowlarrApiKey" = { };
    "nixflix/sonarrApiKey" = { };
    "nixflix/sonarrAnimeApiKey" = { };
    "nixflix/radarrApiKey" = { };
    "nixflix/lidarrApiKey" = { };
    "nixflix/sabnzbdApiKey" = { };
    "nixflix/sabnzbdNzbKey" = { };

    # ⚠ Rotate in Navidrome's UI first, then here — see the option comment.
    "nixflix/navidromePassword" = { };

    # One shared *arr login (admin on all five): single-user homelab, and five
    # near-identical secrets is friction without a gain.
    "nixflix/arrPassword" = { };

    # ⚠ Must stay the plaintext of the PBKDF2 hash in serverConfig, or every
    # *arr grab fails to authenticate.
    "nixflix/qbittorrentPassword" = { };
  };
}
