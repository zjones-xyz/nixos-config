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
# The module set comes from zjones-xyz/nixflix-exp — upstream nixflix plus a
# nixos-26.05 pin and seven robustness fixes (flake.nix's input comment has
# the full story). Upstream tracks nixos-unstable; the fork's CI proves each
# revision against 26.05 before this host's lock is bumped to it.

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

    # Deliberately NOT enabled yet: `lidarr` (SHARES.md marks `music` 🛡
    # Protected — a curated, non-re-acquirable library, so pointing an
    # automation tool at it is its own decision, not a default), and
    # `sonarr-anime` / `recyclarr` (both easy adds once the base stack has
    # actually run). Enabling any of them is a few lines here plus its own
    # sops API key.

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
    };
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
      vpnNamespace = "wg";
    };

    after = [ "qbittorrent.service" ];
    wants = [ "qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [ libnatpmp curl coreutils gnused gnugrep ];

    serviceConfig = {
      # A supervised forever-loop, not a oneshot: the lease dies in ~60s and
      # the port changes across reconnects, so this must keep running.
      Restart = "always";
      RestartSec = 15;
      DynamicUser = true;
      LoadCredential = [
        "qbPassword:${config.sops.secrets."nixflix/qbittorrentPassword".path}"
      ];
    };

    script = ''
      set -uo pipefail

      # Proton's WireGuard gateway. Fixed across their infrastructure; if a
      # future config uses a different subnet this is the one value to change.
      GATEWAY=10.2.0.1

      # NOT 127.0.0.1 — when confined, nixflix binds qBittorrent's WebUI to
      # the namespace address (192.168.15.1) rather than loopback, so a
      # localhost URL here would connect-refuse forever and silently never
      # publish a port. `connectionAddress` is the module's own read-only
      # derivation of that value, so this follows automatically if the VPN is
      # ever turned off (it becomes 127.0.0.1) or the address changes.
      QB_URL="http://${config.nixflix.torrentClients.qbittorrent.connectionAddress}:${toString config.nixflix.torrentClients.qbittorrent.webuiPort}"
      QB_USER="admin"
      QB_PASS="$(cat "$CREDENTIALS_DIRECTORY/qbPassword")"

      published=""

      while :; do
        # Both protocols must be mapped and renewed; the TCP reply carries the
        # port we hand to qBittorrent. Proton grants the same number for both.
        natpmpc -a 1 0 udp 60 -g "$GATEWAY" >/dev/null 2>&1 || true

        if ! reply=$(natpmpc -a 1 0 tcp 60 -g "$GATEWAY" 2>&1); then
          echo "natpmpc failed (tunnel still coming up?); retrying" >&2
          sleep 10
          continue
        fi

        port=$(printf '%s\n' "$reply" \
          | sed -n 's/.*Mapped public port \([0-9][0-9]*\).*/\1/p' \
          | head -n1)

        if [ -z "$port" ]; then
          echo "no port in natpmpc reply; retrying" >&2
          sleep 10
          continue
        fi

        # Only talk to qBittorrent when the port actually changed — this loop
        # runs every 45s and the port is usually stable for days.
        if [ "$port" != "$published" ]; then
          jar=$(mktemp)
          if curl -sf -c "$jar" \
               --data-urlencode "username=$QB_USER" \
               --data-urlencode "password=$QB_PASS" \
               "$QB_URL/api/v2/auth/login" >/dev/null \
             && curl -sf -b "$jar" \
                  --data-urlencode "json={\"listen_port\":$port}" \
                  "$QB_URL/api/v2/app/setPreferences" >/dev/null; then
            echo "published forwarded port $port to qBittorrent"
            published="$port"
          else
            echo "failed to publish port $port to qBittorrent; will retry" >&2
          fi
          rm -f "$jar"
        fi

        # Lease is 60s; renew with headroom.
        sleep 45
      done
    '';
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
    "nixflix/radarrApiKey" = { };
    "nixflix/sabnzbdApiKey" = { };
    "nixflix/sabnzbdNzbKey" = { };

    # Shared *arr web UI password (username `admin` on all three). One value
    # rather than three: single-user homelab, all three equally trusted, and
    # three near-identical secrets is friction without a security gain.
    "nixflix/arrPassword" = { };

    # qBittorrent's API password, in plain text — consumed both by the *arrs
    # and by the NAT-PMP sidecar above. Must be the SAME password the
    # PBKDF2 hash in serverConfig was generated from, or the *arrs authenticate
    # against a hash that doesn't match and every grab fails.
    "nixflix/qbittorrentPassword" = { };
  };
}
