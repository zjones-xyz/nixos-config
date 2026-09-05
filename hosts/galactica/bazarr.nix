{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Bazarr — subtitle management for the *arr libraries.
# ─────────────────────────────────────────────────────────────────────────────
# ⚠ TWO instances, and that is not a preference. Bazarr connects to exactly ONE
# Sonarr and ONE Radarr: its config schema has scalar `sonarr.ip` / `radarr.ip`
# keys, not indexed instances, and upstream has closed the multi-instance
# request as "won't happen" — the stated answer is to run a second Bazarr. This
# host has a first-class `sonarr-anime` (§12 "Anime"), so one instance would
# leave the whole anime library without subtitles.
#
# Alternatives were looked at first and none was reasonable here:
#
#   • Bazarr+ (LavX/bazarr) is a hard fork that DOES manage many Sonarr/Radarr
#     instances as one. It is a single-maintainer fork at ~90 stars, is not in
#     nixpkgs, and ships only as `ghcr.io/lavx/bazarr:latest` — a floating tag.
#     This is software that holds four *arr API keys and has write access to
#     the library; taking it on an unpinned image from one maintainer trades a
#     packaged, pinned, reproducible unit for a second UI's worth of
#     convenience. Not a trade this host's design makes.
#   • Subliminal (nixpkgs, 2.6.0) IS instance-agnostic — it walks media paths,
#     so one timer would cover tv, anime and movies alike. But it is a fetcher,
#     not a manager: no per-series language profiles, no upgrade/scoring loop,
#     no subtitle sync, and no notion of which episodes are still missing subs.
#     It fills part of the role, not the role.
#   • Jellyfin's OpenSubtitles plugin is playback-side, on demand, and lives on
#     memory-alpha — a different host and a different job.
#
# So: the maintained nixpkgs module for the primary instance, and a hand-rolled
# twin for anime, because `services.bazarr` is a singleton. If upstream ever
# gains multi-instance support, the twin is what gets deleted.

let
  nixflix = config.nixflix;

  mediaGroup = nixflix.globals.libraryOwner.group;

  # Beside the rest of galactica's appdata, on the special vdev's 3-way SSD
  # mirror — the same reasoning as nixflix's own stateDir (DECISIONS.md §7 /
  # §9–10). NOT /var/lib, the module's default, which is the single unmirrored
  # NVMe. Bazarr's dataDir is a real database, not a cache: it holds the
  # per-episode subtitle state and the history. `tank/appdata/<service>` is the
  # layout BACKUP-BORG.md already assumes, so it inherits that dataset's borg
  # property with nothing extra to declare here.
  #
  # Deliberately NOT under nixflix's stateDir: nixflix does not manage Bazarr,
  # and putting it there would suggest otherwise to the next reader.
  dataDir = "/tank/appdata/bazarr";
  animeDataDir = "/tank/appdata/bazarr-anime";

  # 6767 is Bazarr's default; the twin takes the next port. Both are clear of
  # everything else on this host (sonarr 8989, sonarr-anime 8990, radarr 7878,
  # lidarr 8686, prowlarr 9696, sabnzbd 8080, navidrome 4533, flaresolverr
  # 8191, traefik 80/443).
  port = 6767;
  animePort = 6768;

  # Derived from each *arr's own `mediaDirs` rather than restated, so a library
  # path can only be in one place. Consequence worth knowing: a root folder
  # added in an *arr's UI **and not** added to `mediaDirs` in nixflix.nix is
  # unwritable to that *arr AND to Bazarr, identically — the fix is the same
  # one line for both, which is why deriving beats a second hand-written list.
  mainPaths = nixflix.sonarr.mediaDirs ++ nixflix.radarr.mediaDirs;
  animePaths = nixflix.sonarr-anime.mediaDirs;

  # The nixpkgs module ships no hardening at all. Kept conservative on purpose:
  # Bazarr is a large Python app that shells out to ffmpeg and unar (both come
  # from the package's own wrapper PATH), so this is the set that constrains it
  # without touching how it works. No MemoryDenyWriteExecute — CPython and its
  # native extensions do not survive it.
  hardening = {
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    LockPersonality = true;

    # ⚠ Load-bearing, same lesson as unpackerr.nix. Bazarr writes .srt files
    # beside the video, and the library is group-owned by `media` so the *arrs
    # can rename, move and delete around them. Default 0022 would give those
    # subtitles 0644 and leave a later Sonarr rename unable to take them along.
    UMask = "0002";
  };
in
{
  # ── Primary instance: Sonarr (tv) + Radarr (movies) ───────────────────────
  services.bazarr = {
    enable = true;
    inherit dataDir;
    listenPort = port;

    # `media` as the PRIMARY group, not a supplementary one. Files Bazarr
    # creates then land group-owned by `media` without anything having to fix
    # them up afterwards; with UMask above that makes every subtitle
    # group-writable, which is what the *arrs need. The module creates the
    # `bazarr` user for us and points its home at dataDir; `media` already
    # exists because nixflix declares it.
    group = mediaGroup;

    # Left false: nothing reaches this except Traefik, on the host itself.
    openFirewall = false;
  };

  systemd.services.bazarr = {
    # `wants`, not `requires` — the same reasoning as unpackerr.nix and the
    # FlareSolverr correction. Bazarr retries its *arr connections on a loop,
    # so a slow Sonarr costs it a poll; a `requires` would cancel this unit's
    # start job outright and never re-queue it.
    after = [ "sonarr.service" "radarr.service" ];
    wants = [ "sonarr.service" "radarr.service" ];

    serviceConfig = hardening // {
      ReadWritePaths = [ dataDir ] ++ mainPaths;
    };
  };

  # ── Anime twin ────────────────────────────────────────────────────────────
  # A transcription of the nixpkgs module for a second instance, because that
  # module is a singleton. The three odd-looking settings — SIGINT, exit status
  # 156, `--no-update True` — are mirrored from it verbatim so both instances
  # behave identically rather than one of them quietly diverging.
  #
  # Same `bazarr` user as the primary: the two need exactly the same rights
  # (write across the library, an API key into the same stack), so a second
  # account would add a thing to keep in the `media` group and isolate nothing.
  # The dataDirs are separate, which is the boundary that actually matters —
  # each instance owns its own database.
  systemd.tmpfiles.settings."10-bazarr-anime".${animeDataDir}.d = {
    user = config.services.bazarr.user;
    group = mediaGroup;
    mode = "0700";
  };

  systemd.services.bazarr-anime = {
    description = "Bazarr (anime — sonarr-anime)";
    after = [ "network.target" "sonarr-anime.service" ];
    wants = [ "sonarr-anime.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ animeDataDir ];

    serviceConfig = hardening // {
      Type = "simple";
      User = config.services.bazarr.user;
      Group = mediaGroup;
      SyslogIdentifier = "bazarr-anime";
      ExecStart = pkgs.writeShellScript "start-bazarr-anime" ''
        ${lib.getExe config.services.bazarr.package} \
          --config '${animeDataDir}' \
          --port ${toString animePort} \
          --no-update True
      '';
      Restart = "on-failure";
      KillSignal = "SIGINT";
      SuccessExitStatus = "0 156";
      ReadWritePaths = [ animeDataDir ] ++ animePaths;
    };
  };

  # ── Routes ────────────────────────────────────────────────────────────────
  # Registered rather than added to traefik-galactica.nix's own list: Bazarr is
  # not a nixflix service, so the module cannot derive it the way it derives
  # the *arrs. This keeps each port written exactly once.
  homelab.arrExtraUpstreams = {
    bazarr = "http://127.0.0.1:${toString port}";
    bazarr-anime = "http://127.0.0.1:${toString animePort}";
  };
}
