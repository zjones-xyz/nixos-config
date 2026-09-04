{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — declarative media stack (nixarr).
# ─────────────────────────────────────────────────────────────────────────────
# nixarr's *arr / library-manager / download stack, pointed at the `tank` ZFS
# array's media datasets, with both download clients (torrent + usenet)
# confined to a ProtonVPN WireGuard netns. The pieces that need a credential
# the owner hasn't generated yet (the VPN wgConf) are gated behind the
# `vpnReady` flag so this evaluates — and activates — cleanly *now*, before
# that credential exists. Everything the owner still has to supply is called
# out inline.
#
# Jellyfin and Seerr are deliberately NOT here — both stay on memory-alpha
# (galactica can't hardware-transcode; project decision, 2026-09-03), Jellyfin
# consuming this host's library over NFS and Seerr talking to that remote
# Jellyfin. See the block below for the NFS dependency this creates.
#
# The `nixarr.*` options come from `nixarr.nixosModules.default`, wired into
# this host in flake.nix (which also bundles Maroka-chan/VPN-Confinement for
# the netns). Import order: this file is listed in configuration.nix's
# `imports`.
#
# Ingress is deliberately NOT here: the *arr web UIs are plain systemd
# services on localhost, and the fleet's public ingress is a tsdproxy
# List-provider entry that lives in the separate `homelab_stacks` (Docker)
# repo, pointed at these localhost ports. So no Tailscale/tsdproxy/Traefik and
# no `openFirewall` below — reaching these from off-box is homelab_stacks' job,
# out of scope for this repo.

let
  # secrets/galactica.yaml already exists in the repo (it holds the array LUKS
  # keys) — so `builtins.pathExists` on it is already true and can't stand in
  # for "the VPN credential is ready". The wgConf is a *key inside* that file
  # that the owner hasn't added yet, and nothing can pathExists a sops key at
  # eval time. So the download/VPN stack is gated on an explicit flag instead:
  # it stays off (eval-safe now, and activation-safe — no reference to a
  # missing sops key) until the owner adds the wgConf and flips this to true.
  #
  # ⚠ OWNER: set this to `true` ONLY after `vpn.wgConf` is in galactica.yaml
  # (see the sops block below). Turning it on runs Transmission confined to the
  # ProtonVPN netns; leaving it off runs the *arr apps with no download client
  # at all — never an unconfined torrent client.
  vpnReady = false;
in
{
  # ── VPN credential (ProtonVPN WireGuard) ───────────────────────────────────
  # nixarr confines the download client to a WireGuard netns via a standard
  # wg-quick config file (`nixarr.vpn.wgConf`). That file embeds a WireGuard
  # *private key* → it's a credential, so it's sops-managed rather than checked
  # in. Store it in galactica.yaml under `vpn/wgConf` as a multiline string
  # (`sops secrets/galactica.yaml`, then a `vpn:\n  wgConf: |` block); sops
  # renders it back to a file at activation and hands nixarr the path.
  #
  # ⚠ OWNER MUST GENERATE THIS: log into the ProtonVPN account (paid plan —
  # P2P needs it), download a WireGuard config for a **P2P-tagged** server
  # (plain servers drop torrent traffic), and paste its contents in. Add the
  # key, then flip `vpnReady` to true; until then the whole VPN + download
  # path stays disabled, so nothing ever runs *unconfined*.
  sops.secrets = lib.optionalAttrs vpnReady {
    "vpn/wgConf" = { };
  };

  nixarr = {
    enable = true;

    # ── Paths → the `tank` array ─────────────────────────────────────────────
    # mediaDir is nixarr's media root: it takes `media`-group ownership of the
    # tree and expects the shared library at `${mediaDir}/library` and the
    # download client's dir at `${mediaDir}/torrents`. `tank/media` was staged
    # empty specifically for this on 2026-09-02 (MANUAL-STEPS.md §9.1 — the
    # seven pre-existing media datasets were swept aside into
    # `tank/media_staging/*` first so nixarr would get a clean tree; those
    # collections re-enter via *arr imports, not a straight copy-back).
    mediaDir = "/tank/media";

    # State/config for every service. ⚠ UNCONFIRMED PATH: the 2026-09-02
    # dataset-tree build (MANUAL-STEPS.md §9) organizes datasets by content
    # with backup tier as an inherited `homelab:tier` ZFS user property — NOT
    # a tier-based path prefix (DECISIONS.md §"paired-appdata rule") — so this
    # is not simply `/tank/services/arr_config`. `tank/appdata` is the
    # small-file dataset forced onto the special vdev, which is where
    # SHARES.md's old `arr_config` classification (painful-to-rebuild, small)
    # points. Confirm the real path with `zfs list -r tank/appdata` on
    # galactica before first activation and adjust if it differs.
    stateDir = "/tank/appdata/arr_config";

    # Add the primary user to the `media` group so files under mediaDir are
    # readable/writable outside the service accounts (QoL for hand-sorting).
    mediaUsers = [ "z" ];

    # ── *arr services ─────────────────────────────────────────────────────────
    # Sonarr (TV), Radarr (film), Prowlarr (indexer aggregator), Bazarr
    # (subtitles). Sensible defaults for this stack.
    #
    # Readarr is deliberately ABSENT: its maintainers retired the project
    # (Jan 2026). Its successor for books/audiobooks is Shelfmark, enabled
    # below — that's the live replacement, not Readarr itself.
    sonarr.enable = true;
    radarr.enable = true;
    prowlarr.enable = true;
    bazarr.enable = true;

    # ── Jellyfin / Seerr — deliberately OFF on galactica ─────────────────────
    # Owner decision: both stay on memory-alpha (galactica's Xeon E3-1230 v2
    # can't transcode usefully; memory-alpha's Jellyfin already has an
    # existing users DB to preserve). memory-alpha's Jellyfin
    # (modules/nixos/jellyfin.nix) consumes this host's *arr-managed library
    # **over NFS** — the fsid-101 `jellyfin` and fsid-102 `arr_managed_data`
    # re-exports (MANUAL-STEPS.md §8, still outstanding as of this writing:
    # §9's item 4, "NFS re-exports"). Nothing downstream on memory-alpha has a
    # working library until that cutover lands. Seerr's connection to the
    # remote Jellyfin (URL + API key) and to these *arr instances (host +
    # API key) is set in Seerr's own UI on memory-alpha — not here.
    jellyfin.enable = false;
    seerr.enable = false;

    # ── Audiobookshelf ───────────────────────────────────────────────────────
    # Audiobook + podcast server. Native nixarr module → nixpkgs
    # `services.audiobookshelf` / `pkgs.audiobookshelf`. State/config lands
    # under stateDir like the *arr apps; the audiobook *media* lives on the
    # `tank/media/audiobooks` dataset (part of the 2026-09-02 tree), which you
    # point Audiobookshelf's library at in its web UI — nixarr exposes only
    # stateDir, not a library-path option. Not VPN-confined (user-facing
    # server; ingress via the homelab_stacks tsdproxy entry).
    audiobookshelf.enable = true;

    # ── Shelfmark (ebook / audiobook manager — the Readarr successor) ─────────
    # The *arr-family manager for books, replacing the retired Readarr. Native
    # nixarr module. nixarr fixes its library at
    # `${mediaDir}/library/{books,audiobooks}` (= /tank/media/library/books and
    # /tank/media/library/audiobooks); there's no per-library path override.
    #
    # ⚠ RECONCILE with the real dataset: `tank/books` is its own top-level
    # dataset (also staged empty 2026-09-02), not nested under
    # `tank/media/library`. Either set `tank/books`'s mountpoint to
    # `/tank/media/library/books`, or symlink. Not VPN-confined.
    shelfmark.enable = true;

    # ── TRaSH-guides sync: recyclarr, not configarr ──────────────────────────
    # Evaluated both. configarr has neither a package nor a NixOS module in
    # this flake's nixpkgs pin (26.05, rev 5880666) — adopting it would mean
    # either packaging a Node/TS tool from scratch or running it as an
    # unmanaged Docker container, breaking out of the declarative nixarr
    # stack this whole host is built around. recyclarr is packaged
    # (`pkgs.recyclarr`) with a native `services.recyclarr` module, and
    # nixarr's own module wires it up for free: it extracts the Sonarr/Radarr
    # API keys itself (into `${stateDir}/secrets/*.api-key`, injected as
    # RADARR_API_KEY / SONARR_API_KEY) — so no API key goes here. Revisit
    # configarr only if recyclarr's TRaSH-guide coverage or update cadence
    # turns out to be a real problem in practice.
    #
    # nixarr requires exactly one of `configFile` / `configuration`; this
    # supplies a MINIMAL `configuration` so it evaluates and runs.
    # ⚠ FLESH OUT: this scaffold only points recyclarr at the two instances
    # with no directives yet — a sync is a no-op until you add the real TRaSH
    # `quality_definition` / `custom_formats` / `quality_profiles` blocks (see
    # https://recyclarr.dev/wiki/yaml/config-reference/). base_url ports are
    # nixarr's Sonarr/Radarr defaults (8989 / 7878); confirm if changed.
    recyclarr = {
      enable = true;
      configuration = {
        sonarr.series = {
          base_url = "http://localhost:8989";
          api_key = "!env_var SONARR_API_KEY";
        };
        radarr.movies = {
          base_url = "http://localhost:7878";
          api_key = "!env_var RADARR_API_KEY";
        };
      };
    };

    # ── VPN (ProtonVPN WireGuard netns) ──────────────────────────────────────
    # Gated on `vpnReady`: the netns only comes up once the wgConf credential
    # is in place — and, combined with the download-client gating below,
    # guarantees no torrent traffic ever runs outside the tunnel.
    vpn = {
      enable = vpnReady;
      wgConf = lib.mkIf vpnReady config.sops.secrets."vpn/wgConf".path;
    };

    # ── Download client (Transmission), VPN-confined ─────────────────────────
    # Only enabled once the VPN is (vpnReady) — never an unconfined torrent
    # client. `vpn.enable = true` is unconditional here but only takes effect
    # when the client itself is enabled, i.e. exactly when the netns is up.
    #
    # ⚠ DOWNLOAD DIR IS A TODO: nixarr hardcodes the download dir to
    # `${mediaDir}/torrents` (= /tank/media/torrents) — it's not an option.
    # Decide the real inbox location (e.g. a dedicated dataset, kept on the
    # same filesystem as the library so imports stay atomic hardlinks) and
    # reconcile with nixarr's fixed layout.
    #
    # peerPort must be a concrete value: nixarr feeds it straight into the
    # VPN-Confinement netns port map, and its own default (null) is rejected
    # there as a non-port. 51413 is Transmission's default.
    # ⚠ With ProtonVPN, inbound peers only arrive on the *forwarded* port,
    # which Proton hands out dynamically (NAT-PMP) rather than letting you pick
    # — so treat this as a placeholder and reconcile with Proton port
    # forwarding (nixarr/VPN-Confinement port-forwarding) when going live.
    transmission = {
      enable = vpnReady;
      vpn.enable = true;
      peerPort = 51413;
    };

    # ── Usenet download client (SABnzbd), VPN-confined ───────────────────────
    # Same gating as the torrent client: only runs once `vpnReady`, always
    # inside the netns. Native nixarr module → `pkgs.sabnzbd`. Completed
    # downloads land in mediaDir; incomplete under `${mediaDir}/usenet` — same
    # download-dir TODO as the torrent side. No inbound/peer port (usenet is
    # outbound-only).
    #
    # ⚠ OWNER-SUPPLIED (UI-side, not declarative): a Usenet provider (news
    # server host/port/SSL + credentials) and NZB indexer access. SABnzbd does
    # nothing until at least one news server is configured.
    sabnzbd = {
      enable = vpnReady;
      vpn.enable = true;
    };
  };
}
