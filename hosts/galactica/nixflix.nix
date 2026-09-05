{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — the *arr media stack, via nixflix.
# ─────────────────────────────────────────────────────────────────────────────
# Replaces the Unraid Docker stack. Deliberately a CLEAN REBUILD: the old
# `arr_config` appdata is NOT restored (it lives in `tank/backups/` as
# insurance only) — indexers, profiles and histories are re-entered through
# the services' own UIs, and collections re-enter via *arr imports from
# `tank/media_staging`. MANUAL-STEPS.md §12 is the run book.
#
# ⚠ Jellyfin and Seerr are OFF here, on purpose. This board has no GPU and
# its Xeon E3-1230 v2 can't transcode usefully (PLATFORM.md), so playback
# stays on memory-alpha, which mounts this host's library over NFS (§8).
# galactica is the *acquisition and storage* half of the media stack only.
#
# The module set comes from upstream nixflix, pinned to an exact revision that
# our zjones-xyz/nixflix-exp fork has already proven against nixos-26.05 in its
# own CI. Upstream tracks nixos-unstable and commits most days; the fork is the
# canary that rehearses each revision against the channel this fleet actually
# deploys, and only a revision it has cleared gets pinned here. flake.nix's
# input comment carries the full reasoning, including the one fork fix that
# would matter if FlareSolverr is ever enabled on this host.

let
  # ── One ZFS dataset, two plain subdirectories ─────────────────────────────
  # This is load-bearing, not stylistic. The *arrs hardlink (or atomically
  # move) completed downloads into the library, and a hardlink CANNOT cross a
  # filesystem boundary — in ZFS every dataset IS a separate filesystem. Split
  # `media` and `downloads` into two datasets and nothing errors: the *arrs
  # silently fall back to copying, so every seeding torrent costs twice its
  # size on disk and every import runs at disk-copy speed instead of being
  # instant. Keeping both as ordinary directories inside the single
  # `tank/nixflix_media` dataset is what makes hardlinks work.
  #
  # Consequence to remember when adding datasets later: `zfs create
  # tank/nixflix_media/downloads` would quietly re-introduce exactly this bug.
  base = "/tank/nixflix_media";
  mediaDir = "${base}/media";

  # Shared by the two ProtonVPN units below, which would otherwise each carry
  # their own copy — the gateway literal was written twice, under a comment
  # claiming to be "the one value to change".
  netns = "wg";
  gateway = "10.2.0.1";
in

{
  # ── Where the stack lives ─────────────────────────────────────────────────
  nixflix = {
    enable = true;

    inherit mediaDir;
    downloadsDir = "${base}/downloads";

    # State (the *arr SQLite databases) goes on `tank/appdata`, which
    # DECISIONS.md §7 / MANUAL-STEPS.md §9 deliberately forced onto the
    # special vdev's 3-way SSD mirror as "real redundancy for the host's most
    # irreplaceable mutable state" — and DESIGN.md names the *arr databases
    # exactly that. NOT /var/lib: that is the single unmirrored NVMe, the
    # arrangement this fleet already reversed once for appdata.
    #
    # Accepted consequence, already documented and unchanged here: these
    # services cannot start until the array (special vdev included) is
    # imported and mounted. There is no interim NVMe home, on purpose.
    stateDir = "/tank/appdata/nixflix";

    # `z` needs to read/write the library directly (imports, cleanup) without
    # sudo; this adds the user to the shared media group.
    mediaUsers = [ "z" ];

    # Everything above lives on `tank`, which is imported in stage-2 from
    # /dev/mapper after the crypttab LUKS opens (configuration.nix). Without
    # this the services race the mount and fail their first start on every
    # cold boot — recoverable, but noisy and needless.
    serviceDependencies = [ "zfs-mount.service" ];

    # ── VPN (ProtonVPN, WireGuard) ──────────────────────────────────────────
    # vpn-confinement puts the confined services in their own `wg` network
    # namespace; the host's own networking is untouched, so NFS, SSH and the
    # monitoring agents are unaffected by the tunnel's state.
    vpn = {
      enable = true;

      # A wg-quick config downloaded from Proton's portal. MUST be from a
      # server that supports P2P **and** port forwarding, or the NAT-PMP
      # sidecar below has nothing to map. Kept in sops so the private key
      # never lands in the Nix store.
      wgConfFile = config.sops.secrets."nixflix/protonWgConf".path;

      # ⚠ The fleet LAN is 192.168.8.0/24 (confirmed from live host addresses,
      # MANUAL-STEPS.md §8) — NOT the module's 192.168.1.0/24 default. With
      # the default left in place the confined services' web UIs are simply
      # unreachable from the LAN, which presents as "qBittorrent is down".
      accessibleFrom = [ "192.168.8.0/24" ];
    };

    # ── Indexers ────────────────────────────────────────────────────────────
    # FlareSolverr solves the Cloudflare challenges several public indexers
    # sit behind; Prowlarr reaches it over the host loopback (both run
    # unconfined — only qBittorrent is in the VPN namespace, so there is no
    # cross-namespace problem here). Two upstream behaviours are corrected
    # below the `nixflix` block; read that comment before touching either.
    flaresolverr.enable = true;

    prowlarr = {
      enable = true;
      config = {
        apiKey._secret = config.sops.secrets."nixflix/prowlarrApiKey".path;
        hostConfig = {
          username = "admin";
          password._secret = config.sops.secrets."nixflix/arrPassword".path;
        };
      };
    };

    # ── TV ──────────────────────────────────────────────────────────────────
    sonarr = {
      enable = true;
      mediaDirs = [ "${mediaDir}/tv" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/sonarrApiKey".path;
        rootFolders = [ { path = "${mediaDir}/tv"; } ];
        hostConfig = {
          username = "admin";
          password._secret = config.sops.secrets."nixflix/arrPassword".path;
        };
      };
    };

    # ── Film ────────────────────────────────────────────────────────────────
    radarr = {
      enable = true;
      mediaDirs = [ "${mediaDir}/movies" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/radarrApiKey".path;
        rootFolders = [ { path = "${mediaDir}/movies"; } ];
        hostConfig = {
          username = "admin";
          password._secret = config.sops.secrets."nixflix/arrPassword".path;
        };
      };
    };

    # ── Anime (series) ──────────────────────────────────────────────────────
    # A second Sonarr instance rather than a profile inside the one above:
    # anime needs its own quality profiles, release-group handling and
    # absolute-numbering behaviour, and nixflix treats `sonarr-anime` as a
    # first-class service — Prowlarr registers it as its own application, and
    # qBittorrent/SABnzbd each get a matching download category automatically,
    # so downloads stay separated end to end without hand-wiring.
    #
    # Port 8990 (module default; the main Sonarr is 8989) and its own state
    # directory under stateDir, so the two instances share nothing but the
    # media group.
    sonarr-anime = {
      enable = true;
      mediaDirs = [ "${mediaDir}/anime" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/sonarrAnimeApiKey".path;
        rootFolders = [ { path = "${mediaDir}/anime"; } ];
        hostConfig = {
          username = "admin";
          password._secret = config.sops.secrets."nixflix/arrPassword".path;
        };
      };
    };

    # ── Quality profiles and custom formats (TRaSH guides) ──────────────────
    # Recyclarr syncs the TRaSH guides into Sonarr, sonarr-anime and Radarr:
    # custom formats, their scores, quality definitions and one quality profile
    # per instance. It is the piece that makes a CLEAN REBUILD affordable —
    # otherwise every custom format and score is re-entered by hand through
    # three web UIs, which is exactly the work this host's rebuild was going to
    # have to redo.
    #
    # nixflix wires all three instances automatically from the options already
    # set above, including their API keys. Those keys stay out of the Nix store:
    # nixpkgs' recyclarr module handles `{ _secret = path; }` natively through
    # `utils.genJqSecretsReplacement`, substituting at start from
    # LoadCredential, so the rendered YAML in the store carries paths and not
    # values. Verified in the evaluated config rather than assumed.
    #
    # Runs daily on a timer, and after each *arr's own `-config` service.
    recyclarr = {
      enable = true;

      # Pinned rather than left at the module default, which is the same value
      # today. This decides what actually lands on a 4×12 TB array, so an
      # upstream default flipping to 4K should not silently quadruple every
      # grab. Change deliberately, not by `nix flake update`.
      #
      # 1080p because galactica cannot transcode (no GPU, 2012 Xeon) and
      # playback is memory-alpha's job over NFS — 4K would bet every file on
      # every client direct-playing it. Changing this later is cheap: recyclarr
      # creates the other profile on the next run and existing files are
      # untouched; only newly-grabbed releases follow the new profile.
      sonarrQuality = "1080p";
      radarrQuality = "1080p";

      # `cleanupUnmanagedProfiles` is left OFF (the module default). Turning it
      # on deletes every quality profile the managed list does not name —
      # including the *arrs' stock ones and anything hand-made later. Tempting
      # on a clean rebuild, but it is a destructive daily job guarding against
      # mess that does not exist yet.
    };

    # ── Music: acquisition ──────────────────────────────────────────────────
    # ⚠ Read this before pointing Lidarr at the OLD library. SHARES.md marks
    # `music` 🛡 Protected, and DECISIONS.md §'s re-acquirable table
    # deliberately omits it — unlike `arr_media`, this collection cannot simply
    # be re-downloaded. Lidarr is not a read-only cataloguer: it renames, moves
    # and (on upgrade) deletes files under its root folder.
    #
    # So this points at a FRESH `media/music`, consistent with the clean
    # rebuild everywhere else, and the existing collection stays untouched in
    # `tank/media_staging` until you deliberately import it. Do that import
    # with the staging copy still intact, not as a move — see MANUAL-STEPS §12.
    lidarr = {
      enable = true;
      mediaDirs = [ "${mediaDir}/music" ];
      config = {
        apiKey._secret = config.sops.secrets."nixflix/lidarrApiKey".path;
        hostConfig = {
          username = "admin";
          password._secret = config.sops.secrets."nixflix/arrPassword".path;
        };
      };
      # `rootFolders` is left at the module default, unlike the other *arrs
      # above: Lidarr's /rootfolder API needs more than a path
      # (defaultQualityProfileId, defaultMetadataProfileId, monitor options),
      # and nixflix already derives all of that from `mediaDirs`. Overriding it
      # by hand here would mean restating those IDs for no gain.
    };

    # ── Music: playback ─────────────────────────────────────────────────────
    # Navidrome is a Subsonic-compatible streaming server, and unlike Jellyfin
    # it belongs on this host: audio transcoding is cheap enough for the
    # E3-1230 v2 (the no-GPU reasoning that exiles video playback to
    # memory-alpha simply does not apply), and serving from local disk avoids
    # bouncing the library over NFS.
    #
    # `MusicFolder` is left implicit: it defaults to the head of
    # `lidarr.mediaDirs`, so the two stay pointed at the same place by
    # construction. Navidrome only ever reads it. Port 4533, bound 0.0.0.0
    # (no reverse proxy and not VPN-confined here), state under stateDir.
    navidrome = {
      enable = true;
      users.z = {
        # Required, and NOT inferred from the attribute name — the module
        # defaults it to null, which fails the type check rather than falling
        # back to "z".
        userName = "z";
        isAdmin = true;
        password._secret = config.sops.secrets."nixflix/navidromePassword".path;
        # ⚠ Passwords are applied at user CREATION only and never updated
        # declaratively — changing this secret later does not change the
        # login. Use Navidrome's own UI for that.
      };
    };

    # Deliberately NOT enabled yet: `recyclarr` (TRaSH profile sync — an easy
    # add once the base stack has actually run), a few lines here plus its own
    # sops API key.
    #
    # There is no `radarr-anime` to enable: nixflix ships no such module, and
    # unlike `sonarr-anime` it would not be a thin wrapper — the service name
    # is enumerated by hand in Prowlarr's application list, the qBittorrent
    # and SABnzbd category maps and Recyclarr's profiles, so a second Radarr
    # would run but would not be wired into any of them. Anime *films* are
    # handled in the Radarr above via their own root folder and quality
    # profile, which is the common arrangement; see MANUAL-STEPS.md §12.

    # ── Usenet ──────────────────────────────────────────────────────────────
    usenetClients.sabnzbd = {
      enable = true;

      # ⚠ Explicitly OUTSIDE the VPN. This option defaults to
      # `nixflix.vpn.enable`, so enabling the VPN above would otherwise pull
      # SABnzbd into the tunnel silently. Usenet is already TLS to a paid
      # provider, so the tunnel adds little privacy while capping throughput
      # at Proton's bandwidth — and usenet needs no inbound port, so none of
      # the NAT-PMP machinery below applies to it either.
      vpn.enable = false;

      settings.misc = {
        api_key._secret = config.sops.secrets."nixflix/sabnzbdApiKey".path;
        nzb_key._secret = config.sops.secrets."nixflix/sabnzbdNzbKey".path;

        # SABnzbd verifies the Host header and refuses anything not listed
        # here. The module's default fills this in from its own reverseProxy
        # option, which is off — galactica is proxied by the fleet's Traefik
        # (modules/nixos/traefik-galactica.nix) instead, so nixflix cannot
        # know these names and the list has to be given explicitly. Miss this
        # and the proxied UI answers "Access denied - Hostname verification
        # failed" while direct access on loopback keeps working, which reads
        # like a Traefik fault and is not one.
        host_whitelist = "sabnzbd.arr.internal,sabnzbd.arr.zjones.dev";
      };
    };

    # ── Torrents ────────────────────────────────────────────────────────────
    torrentClients.qbittorrent = {
      enable = true;

      # vpn.enable defaults to nixflix.vpn.enable — i.e. ON. That is the
      # intent here and the reason the VPN exists at all; left implicit
      # rather than restated so it can never drift from the global switch.

      # Used by Prowlarr/Sonarr/Radarr to authenticate to qBittorrent's API,
      # and by the NAT-PMP sidecar below. This does NOT set qBittorrent's own
      # password — that is `serverConfig.Preferences.WebUI.Password_PBKDF2`,
      # a PBKDF2 hash the owner generates once (MANUAL-STEPS.md §12).
      password._secret = config.sops.secrets."nixflix/qbittorrentPassword".path;

      # qBittorrent's OWN WebUI credentials. These cannot come from sops: the
      # value is rendered into qBittorrent.conf at build time and reinstalled
      # over the live file on every start (`install -Dm600` in the nixpkgs
      # module's ExecStartPre), so anything set through the WebUI by hand is
      # erased on the next restart. Declarative is the only form that sticks.
      #
      # Password_PBKDF2 is a PBKDF2-HMAC-SHA512 digest — 100k iterations,
      # random 16-byte salt, salt and key both base64 — of the same plaintext
      # held in sops as `nixflix/qbittorrentPassword`. The two must move
      # together: the hash is what qBittorrent verifies, the sops value is
      # what the *arrs and the NAT-PMP sidecar present. Regenerating one
      # without the other locks every client out (MANUAL-STEPS.md §12).
      serverConfig.Preferences.WebUI = {
        Username = "admin";
        Password_PBKDF2 = "@ByteArray(qLRngRuEr+F6yTqp9dj6/g==:m2eO3yy7JkTxaK0DoEiVA8hjNMOAn5qomGyBhTBCQYIR7UDQc+e/l8uQwCw+kvBDNO4BZ1K+J5FosAunqRw4KA==)";

        # qBittorrent rejects requests whose Host header is not its own bind
        # address, which is exactly what a reverse proxy sends — the UI would
        # answer "Unauthorized" through Traefik while working fine on
        # 192.168.15.1:8282 directly. Turned off rather than whitelisted:
        # the WebUI is not reachable from the LAN except through Traefik (the
        # firewall opens 80/443 only), so the header buys nothing here.
        HostHeaderValidation = false;

        # Log the real client rather than the proxy. 192.168.15.5 is the host
        # side of the wg bridge — the source address Traefik connects from,
        # since it reaches the confined WebUI over that bridge.
        ReverseProxySupportEnabled = true;
        TrustedReverseProxiesList = "192.168.15.5";
      };
    };
  };

  # ── FlareSolverr: two corrections to upstream's wiring ────────────────────
  # Both of these are local because galactica tracks upstream nixflix, which
  # has neither fix (flake.nix's input comment explains why we are on upstream).
  # Delete both if upstream ever adopts them.
  #
  # (1) The readiness probe. Upstream's ExecStartPost polls FlareSolverr for
  #     30 seconds, and FlareSolverr's startup includes a COLD CHROMIUM LAUNCH.
  #     Measured on a modern cloud runner: 43s on the first try, 30.2s on the
  #     second — i.e. the 30s budget is already marginal on hardware far
  #     faster than this Xeon E3-1230 v2 (2012). An ExecStartPost failure
  #     fails the whole unit and kills the process, so on a machine that
  #     consistently misses the window FlareSolverr does not merely stumble:
  #     it restart-loops forever and is never usable. 180s is generous enough
  #     that a cold first boot on this box is not a coin flip.
  #
  #     ⚠ TimeoutStartSec has to move with it. ExecStartPost runs INSIDE the
  #     start phase, and neither upstream nor nixpkgs sets a timeout on this
  #     unit, so systemd's 90s default applies — a 180s probe under a 90s
  #     start timeout is killed at 90s and the extra budget never exists. The
  #     probe and the timeout are one change, not two.
  #
  # (2) The dependency direction. Upstream puts `flaresolverr.service` in
  #     prowlarr-indexer-proxies' `requires`. With `requires` + `after`, a
  #     single failed FlareSolverr start makes systemd CANCEL the queued
  #     indexer-proxies job with result 'dependency' — and that is a cancelled
  #     *job*, not a failed service, so its own `Restart = on-failure` never
  #     fires. FlareSolverr's restart then succeeds and nothing re-queues the
  #     dependent: Prowlarr silently comes up with no proxy configured, and
  #     stays that way until someone restarts the unit by hand.
  #
  #     `wants` is the correct relation and costs nothing, because the
  #     indexer-proxies script never talks to FlareSolverr at all — every
  #     request it makes goes to Prowlarr's own API, and it writes the proxy
  #     record with `?forceSave=true`, which tells Prowlarr to skip validating
  #     (i.e. contacting) the proxy on save. `after` is left as upstream set
  #     it, so ordering is unchanged; only the failure propagation differs.
  systemd.services.flaresolverr.serviceConfig.ExecStartPost = lib.mkForce (
    pkgs.writeShellScript "wait-for-flaresolverr" ''
      for i in $(seq 1 180); do
        if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString config.nixflix.flaresolverr.port}/ >/dev/null 2>&1; then
          exit 0
        fi
        sleep 1
      done
      echo "FlareSolverr did not become ready within 180s" >&2
      exit 1
    ''
  );

  # The other half of (1) — see the ⚠ above. 240s rather than exactly 180s so
  # the probe's own failure path is what reports a slow start, with its
  # message, rather than systemd killing the unit mid-poll with a generic
  # timeout. Upstream leaves this unset, so this is a plain set, not a force.
  systemd.services.flaresolverr.serviceConfig.TimeoutStartSec = 240;

  systemd.services.prowlarr-indexer-proxies = {
    requires = lib.mkForce [
      "prowlarr-config.service"
      "prowlarr-tags.service"
    ];
    wants = [ "flaresolverr.service" ];
  };

  # ── navidrome-setup: make it survive a slow first start ───────────────────
  # This oneshot creates Navidrome's first admin user, and upstream gives it
  # no Restart at all — so if its 60s readiness wait ever times out, the unit
  # fails and the admin account is simply never created. Nothing retries it;
  # you would find out at the login screen, and the fix would be a manual
  # `systemctl start navidrome-setup`.
  #
  # Navidrome is a Go binary that serves /ping almost immediately, so 60s
  # should be ample even here — this is cheap insurance against the one boot
  # where the array mount, the *arr databases and Chromium are all competing
  # for this 2012 CPU at once. Restart is safe on a RemainAfterExit oneshot:
  # the script is idempotent (it checks whether the user already exists), and
  # a genuinely broken config just retries slowly and visibly rather than
  # failing once and going quiet.
  systemd.services.navidrome-setup = {
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 30;
    };

    # Bounded, or the "visibly" above is false. NixOS defaults are burst 5 over
    # 10s; at RestartSec = 30 the attempts are 90s apart, so that limiter never
    # trips and the unit retries forever — and a unit perpetually cycling
    # through `activating` never lands in `failed`, so it never appears in
    # `systemctl --failed`. That is LESS visible than failing once. Five tries
    # over half an hour is enough to ride out a slow boot, then it gives up
    # somewhere a person can see it.
    startLimitIntervalSec = 1800;
    startLimitBurst = 5;
  };

  # ── ProtonVPN NAT-PMP → qBittorrent listen port ───────────────────────────
  # Why this exists: nixflix's `vpn.openVPNPorts` declares a STATIC forwarded
  # port, which is how AirVPN and IVPN work. ProtonVPN does not do static
  # forwarding at all — it hands out a port over NAT-PMP that changes on every
  # reconnect and expires unless the lease is renewed about once a minute. So
  # there is nothing to write into `openVPNPorts`, and without this loop
  # qBittorrent is unconnectable: downloads still work over outbound
  # connections, but no peer can initiate, which starves the swarm and makes
  # seeding (and private-tracker ratio) effectively impossible.
  #
  # This is deliberately host-local rather than a nixflix contribution: it is
  # specific to Proton's NAT-PMP behaviour, and upstream's model is the static
  # one. If the VPN provider ever changes to one with static forwarding, delete
  # this whole block and set `nixflix.vpn.openVPNPorts` instead.
  systemd.services.protonvpn-natpmp = {
    description = "Renew ProtonVPN NAT-PMP forward and publish it to qBittorrent";

    # Runs inside the same namespace as qBittorrent — both so natpmpc can
    # reach Proton's gateway, and so qBittorrent's WebUI (bound to the
    # namespace address, not loopback) is reachable at all.
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

      # Everything host-specific the script needs, so the script itself stays a
      # plain shell file with no Nix interpolation in it.
      Environment = [
        # NOT 127.0.0.1 — when confined, nixflix binds qBittorrent's WebUI to
        # the namespace address rather than loopback, so a localhost URL here
        # would connect-refuse forever and silently never publish a port.
        # `connectionAddress` is the module's own read-only derivation of that
        # value, so this follows automatically if the VPN is ever turned off
        # (it becomes 127.0.0.1) or the address changes.
        "QB_URL=http://${config.nixflix.torrentClients.qbittorrent.connectionAddress}:${toString config.nixflix.torrentClients.qbittorrent.webuiPort}"
        "QB_USER=admin"
        "GATEWAY=${gateway}"
      ];

      # writeShellApplication rather than an inline `script`: the body lives in
      # hosts/galactica/protonvpn-natpmp.sh, which means shellcheck runs over it
      # at build time and an editor treats it as shell rather than a Nix string.
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "protonvpn-natpmp";
          # No gnused/gnugrep: the port is parsed with bash's own regex now,
          # and the script never grepped.
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
  # The gap this closes: `wg.service` is a `Type=oneshot` with
  # RemainAfterExit, so it builds the namespace, exits, and never looks at the
  # tunnel again. If Proton goes down *after* boot, systemd keeps reporting it
  # `active (exited)`, qBittorrent keeps running, and its packets are simply
  # black-holed by the namespace's wg0 default route. Nothing is logged as an
  # error and nothing fails — the failure is invisible until someone notices
  # downloads stopped. (An outage at boot IS loud: wg-up pings the endpoint
  # five times, exits non-zero, and `BindsTo = wg.service` then keeps
  # qBittorrent and the sidecar from starting at all.)
  #
  # Handshake age, not reachability, is the signal. Proton's gateway is not
  # guaranteed to answer ICMP, so a failed ping proves nothing; what a live
  # tunnel cannot fake is a recent WireGuard handshake. The ping is here only
  # to *generate* the outbound packet that makes WireGuard rekey — its exit
  # status is deliberately ignored.
  systemd.services.protonvpn-healthcheck = {
    description = "Check the ProtonVPN tunnel is still carrying traffic";

    # Not confined: `wg show` is a netlink query needing CAP_NET_ADMIN, which
    # a DynamicUser inside the namespace does not have. Running as root on the
    # host and reaching in with `ip netns exec` is simpler than granting caps.
    # Ordered after wg.service but deliberately NOT bound to it. `BindsTo` +
    # `after` would make a failed wg.service *cancel* this job with result
    # 'dependency' — a cancelled job, not a failed unit, so it would never
    # appear in `systemctl --failed`. That is the same trap the FlareSolverr
    # comment above documents. Left unbound, a missing namespace fails the
    # check loudly instead, which is the whole point of having it.
    after = [ "wg.service" ];

    serviceConfig = {
      Type = "oneshot";

      # Thresholds and names the script reads, kept here so the script itself
      # is plain shell with no Nix interpolation.
      #
      # MAX_AGE: WireGuard rekeys after 120s of traffic and a session expires
      # at 180s, so a healthy tunnel — kept warm by the script's own ping even
      # with no torrents running — never reads much past 180s. 240 is that
      # ceiling plus margin, putting detection about four minutes behind an
      # outage.
      Environment = [
        "NETNS=${netns}"
        "WG_IFACE=wg0"
        "GATEWAY=${gateway}"
        "MAX_AGE=240"
      ];

      # Externalised for the same reason as the sidecar above: shellcheck runs
      # over hosts/galactica/protonvpn-healthcheck.sh at build time, and the
      # eight-case test harness can exercise the file directly.
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "protonvpn-healthcheck";
          # No gnugrep: the namespace test reads /run/netns directly. coreutils
          # stays for `sleep` — `date` is gone in favour of $EPOCHSECONDS.
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

    # ⟨Follow-up: route this to ntfy.⟩ Same reasoning as the identical note in
    # modules/nixos/smart.nix, and deliberately the same answer: the fleet's
    # ntfy runs on hopper, nut.nix posts to 127.0.0.1:2586 because it runs on
    # that host, and the cross-host URL galactica would need has not been
    # verified from here. A guessed endpoint means alerts that fail silently,
    # which is worse than alerts that visibly do not exist yet. Until then the
    # signal is a failed unit: it shows in `systemctl --failed` for as long as
    # the outage lasts, and clears itself on the first run that passes.
  };

  systemd.timers.protonvpn-healthcheck = {
    description = "Periodic ProtonVPN tunnel health check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 3 minutes after boot: past the tunnel coming up, and past the first
      # handshake the sidecar's own natpmpc call provokes.
      OnBootSec = "3min";
      OnUnitActiveSec = "60s";
      AccuracySec = "10s";
      Unit = "protonvpn-healthcheck.service";
    };
  };

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # ⚠ OWNER STEPS before this activates — every secret below must exist or
  # activation fails. `sops secrets/galactica.yaml`, then `nrs`. The full run
  # book (including the qBittorrent PBKDF2 hash and the `zfs create` calls) is
  # MANUAL-STEPS.md §12.
  #
  # These merge with the secrets already declared in configuration.nix; the
  # `nixflix/` prefix keeps the stack's keys visually separate from the LUKS
  # and monitoring ones.
  sops.secrets = {
    # The wg-quick config from Proton's portal, pasted whole as a multi-line
    # YAML value. Read by vpn-confinement as root at namespace setup.
    "nixflix/protonWgConf" = { };

    # Service API keys — generated once each with `openssl rand -hex 16`, then
    # pushed into each service's database by nixflix's config services.
    "nixflix/prowlarrApiKey" = { };
    "nixflix/sonarrApiKey" = { };
    "nixflix/sonarrAnimeApiKey" = { };
    "nixflix/radarrApiKey" = { };
    "nixflix/lidarrApiKey" = { };
    "nixflix/sabnzbdApiKey" = { };
    "nixflix/sabnzbdNzbKey" = { };

    # Navidrome's admin login. Applied at user creation only — see the option
    # comment above; rotating this value later does not change the password.
    "nixflix/navidromePassword" = { };

    # Shared *arr web UI password (username `admin` on all five — Prowlarr,
    # Sonarr, sonarr-anime, Radarr, Lidarr). One value rather than five:
    # single-user homelab, all of them equally trusted, and five
    # near-identical secrets is friction without a security gain.
    "nixflix/arrPassword" = { };

    # qBittorrent's API password, in plain text — consumed both by the *arrs
    # and by the NAT-PMP sidecar above. Must be the SAME password the
    # PBKDF2 hash in serverConfig was generated from, or the *arrs authenticate
    # against a hash that doesn't match and every grab fails.
    "nixflix/qbittorrentPassword" = { };
  };
}
