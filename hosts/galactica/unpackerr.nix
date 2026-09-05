{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Unpackerr — extract RAR'd downloads so the *arrs can import them.
# ─────────────────────────────────────────────────────────────────────────────
# ⚠ This exists for TORRENTS, not usenet. SABnzbd already unpacks archives
# itself as part of post-processing, so pointing Unpackerr at the usenet path
# would have two things racing to extract and delete the same files.
# qBittorrent does no unpacking at all, and a large share of scene torrents
# still arrive as a .rar set — which the *arrs cannot import, so the item sits
# in the queue as "Found archive file, might need to be extracted" forever.
#
# nixflix has no module for this and nixpkgs ships the package but no
# `services.unpackerr`, so the unit is host-local. It is the fifth local
# addition on top of upstream; flake.nix's input comment tracks that debt.

let
  nixflix = config.nixflix;

  # Same derivation as the Traefik module's upstreams: read the address and
  # port from each service's own evaluated options rather than restating them,
  # so a port change cannot leave Unpackerr talking to nothing.
  arrUrl = name: "http://${nixflix.${name}.connectionAddress}:${toString nixflix.${name}.config.hostConfig.port}";

  # Unpackerr matches queue items by path prefix, so it only needs the torrent
  # download root — every category directory lives under it.
  torrentPath = nixflix.torrentClients.qbittorrent.downloadsDir;
in
{
  # A dedicated user rather than DynamicUser: the config file below holds four
  # *arr API keys, and a fixed owner lets sops render it 0400 to exactly one
  # account. `media` is the shared group every nixflix service already uses —
  # Unpackerr needs to read the archives qBittorrent wrote and delete the
  # extracted files afterwards, both of which are group-write on 0775 dirs.
  users.users.unpackerr = {
    isSystemUser = true;
    group = "unpackerr";
    extraGroups = [ config.nixflix.globals.libraryOwner.group ];
  };
  users.groups.unpackerr = { };

  # ── Config ────────────────────────────────────────────────────────────────
  # Rendered by sops rather than written to the store, because it carries the
  # API keys. Same approach as traefik.env; the difference is that Unpackerr
  # wants a whole TOML file rather than an EnvironmentFile, which sops
  # templates handle just as well.
  sops.templates."unpackerr.toml" = {
    owner = "unpackerr";
    mode = "0400";
    content = ''
      # All five are Unpackerr's own defaults, written out rather than left
      # implicit — pinned, so an upstream default change cannot alter this
      # host's behaviour through a routine `nix flake update`, and visible, so
      # the timing is answerable without reading upstream's docs.
      #
      # What they mean: poll all four *arr queues every 2m; require an item to
      # sit in the queue 1m looking complete before touching it, so the
      # download client has finished moving files; on a failed extraction wait
      # 5m and try at most 3 times before giving up on that item. Worst case
      # from "torrent finishes" to "extraction starts" is therefore ~3m.
      #
      # `parallel = 1` is the one worth keeping at the default deliberately:
      # extraction here is I/O-bound on a 2012 Xeon with spinning disks, so two
      # concurrent multi-gigabyte RARs on the same array finish later than one
      # after the other and compete with whatever is importing.
      interval = "2m"
      start_delay = "1m"
      retry_delay = "5m"
      max_retries = 3
      parallel = 1

      # ⚠ Load-bearing, and NOT Unpackerr's defaults (0644/0755). Everything
      # under the download tree is group-owned by `media` so the *arrs can
      # hardlink, move and delete each other's files. Extracted output has to
      # keep that or the import fails on permissions — which presents as an
      # *arr that can see the file and still refuses it.
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

    # `wants`, not `requires`, throughout — the same reasoning as the
    # FlareSolverr correction in nixflix.nix. Unpackerr polls and retries by
    # design, so an *arr that is slow to start costs it one interval; a
    # `requires` would instead cancel this unit's start job outright and never
    # re-queue it.
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

      # It only ever touches the download tree — never the library, which is
      # the *arrs' to write. Extraction happens beside the archive.
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
