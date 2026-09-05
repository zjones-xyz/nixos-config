{ config, pkgs, lib, ... }:

# Unpackerr — extract RAR'd downloads so the *arrs can import them.
#
# ⚠ TORRENTS only. SABnzbd unpacks its own archives, so pointing this at the
# usenet path would have two things racing to delete the same files.
# Host-local because nixpkgs has no `services.unpackerr`. DECISIONS.md §9.

let
  nixflix = config.nixflix;

  # Read from each service's own options, so a port change cannot leave
  # Unpackerr talking to nothing.
  arrUrl = name: "http://${nixflix.${name}.connectionAddress}:${toString nixflix.${name}.config.hostConfig.port}";

  # Matched by path prefix, so only the download root is needed.
  torrentPath = nixflix.torrentClients.qbittorrent.downloadsDir;
in
{
  # Not DynamicUser: the config holds four API keys, and a fixed owner lets
  # sops render it 0400 to exactly one account.
  users.users.unpackerr = {
    isSystemUser = true;
    group = "unpackerr";
    extraGroups = [ config.nixflix.globals.libraryOwner.group ];
  };
  users.groups.unpackerr = { };

  # ── Config ────────────────────────────────────────────────────────────────
  # Rendered by sops rather than written to the store: it carries the API keys.
  sops.templates."unpackerr.toml" = {
    owner = "unpackerr";
    mode = "0400";
    content = ''
      # All five are Unpackerr's own defaults, written out to pin them against
      # an upstream change and to make the cadence readable. DECISIONS.md §9.
      # `parallel = 1` also happens to be right here: extraction is I/O-bound
      # on a 2012 Xeon, so concurrent RARs finish later, not sooner.
      interval = "2m"
      start_delay = "1m"
      retry_delay = "5m"
      max_retries = 3
      parallel = 1

      # ⚠ NOT Unpackerr's defaults (0644/0755). The download tree is
      # group-owned by `media`; output that loses that fails the *arr import,
      # which presents as an *arr that can see the file and still refuses it.
      file_mode = "0664"
      dir_mode = "0775"

      [[sonarr]]
        url = "${arrUrl "sonarr"}"
        api_key = "${config.sops.placeholder."nixflix/sonarrApiKey"}"
        paths = ['${torrentPath}']
        protocols = "torrent"

      [[sonarr]]
        url = "${arrUrl "sonarr-anime"}"
        api_key = "${config.sops.placeholder."nixflix/sonarrAnimeApiKey"}"
        paths = ['${torrentPath}']
        protocols = "torrent"

      [[radarr]]
        url = "${arrUrl "radarr"}"
        api_key = "${config.sops.placeholder."nixflix/radarrApiKey"}"
        paths = ['${torrentPath}']
        protocols = "torrent"

      [[lidarr]]
        url = "${arrUrl "lidarr"}"
        api_key = "${config.sops.placeholder."nixflix/lidarrApiKey"}"
        paths = ['${torrentPath}']
        protocols = "torrent"
    '';
  };

  systemd.services.unpackerr = {
    description = "Extract RAR'd torrent downloads for the *arrs";

    # `wants`, not `requires` — a `requires` cancels this unit's start job
    # outright, where a slow *arr only costs a poll. Same as FlareSolverr's.
    after = [
      "network-online.target"
      "sonarr.service"
      "sonarr-anime.service"
      "radarr.service"
      "lidarr.service"
      "qbittorrent.service"
    ];
    wants = [
      "network-online.target"
      "sonarr.service"
      "sonarr-anime.service"
      "radarr.service"
      "lidarr.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "unpackerr";
      Group = "unpackerr";
      Restart = "on-failure";
      RestartSec = 30;

      ExecStart = "${lib.getExe pkgs.unpackerr} --config ${config.sops.templates."unpackerr.toml".path}";

      # The download tree only — never the library, which is the *arrs' write.
      ReadWritePaths = [ torrentPath ];

      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
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
    };
  };
}
