{ config, pkgs, lib, ... }:

# Bazarr — subtitle management for the *arr libraries.
#
# ⚠ TWO instances, not a preference: Bazarr speaks to exactly one Sonarr and
# one Radarr, and this host has a first-class `sonarr-anime`. The alternatives
# weighed (Bazarr+, Subliminal) and why they lost are in DECISIONS.md §9.

let
  nixflix = config.nixflix;

  mediaGroup = nixflix.globals.libraryOwner.group;

  # NOT the module's /var/lib default: this dataDir is a real database (per
  # episode subtitle state and history), so it belongs on the special vdev's
  # mirror like every other appdata — DECISIONS.md §7. Not under nixflix's
  # stateDir either, since nixflix does not manage Bazarr.
  dataDir = "/tank/appdata/bazarr";
  animeDataDir = "/tank/appdata/bazarr-anime";

  # Bazarr's default, and the next port for the twin. Both clear of the rest
  # of the stack (8989/8990/7878/8686/9696/8080/4533/8191, and 80/443).
  port = 6767;
  animePort = 6768;

  # Derived, not restated. A root folder added in an *arr's UI but not in
  # `mediaDirs` is unwritable to that *arr and to Bazarr alike — one fix, one
  # place, which is the point.
  mainPaths = nixflix.sonarr.mediaDirs ++ nixflix.radarr.mediaDirs;
  animePaths = nixflix.sonarr-anime.mediaDirs;

  # The nixpkgs module ships none. Conservative on purpose — Bazarr is a large
  # Python app that shells out to ffmpeg and unar. No MemoryDenyWriteExecute:
  # CPython and its native extensions do not survive it.
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

    # ⚠ Load-bearing. Subtitles land beside the video in a library the *arrs
    # rename around; at the default 0022 a later rename cannot take them along.
    UMask = "0002";
  };
in
{
  # ── Primary instance: Sonarr (tv) + Radarr (movies) ───────────────────────
  services.bazarr = {
    enable = true;
    inherit dataDir;
    listenPort = port;

    # PRIMARY group, not supplementary: what Bazarr writes is then owned by
    # `media` with nothing having to fix it up afterwards.
    group = mediaGroup;

    # Reached through Traefik only.
    openFirewall = false;
  };

  systemd.services.bazarr = {
    # `wants`, not `requires` — see unpackerr.nix.
    after = [ "sonarr.service" "radarr.service" ];
    wants = [ "sonarr.service" "radarr.service" ];

    serviceConfig = hardening // {
      ReadWritePaths = [ dataDir ] ++ mainPaths;
    };
  };

  # ── Anime twin ────────────────────────────────────────────────────────────
  # The nixpkgs module transcribed for a second instance, since it is a
  # singleton. SIGINT, exit status 156 and `--no-update True` are mirrored from
  # it verbatim so the two cannot quietly diverge. Same user (identical rights,
  # so a second account isolates nothing); separate dataDirs, which is the
  # boundary that matters.
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
  # Registered rather than listed in traefik-galactica.nix, which can only
  # derive nixflix services. Keeps each port written exactly once.
  homelab.arrExtraUpstreams = {
    bazarr = "http://127.0.0.1:${toString port}";
    bazarr-anime = "http://127.0.0.1:${toString animePort}";
  };
}
