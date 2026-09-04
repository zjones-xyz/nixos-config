# A second, independent instance of a *arr app.
# ─────────────────────────────────────────────────────────────────────────────
# nixarr's `nixarr.sonarr`/`nixarr.radarr` (and the plain nixpkgs
# `services.sonarr`/`services.radarr` modules underneath them) are
# single-instance by construction: one fixed systemd unit name, one fixed
# state dir default, one option namespace. There's no nixpkgs-native way to
# run a second Sonarr for anime alongside the main one. This hand-rolls the
# same shape nixpkgs' own servarr modules use — `<binary> -nobrowser
# -data=<dataDir>`, an isolated system user in the shared `media` group, port
# set via the servarr apps' own `<APPNAME>__SERVER__PORT` env-var convention
# (https://wiki.servarr.com/useful-tools#using-environment-variables-for-config,
# the same mechanism nixpkgs' settings-options.nix generates from) — just
# parameterized so it can be called more than once.
#
# Reuses nixarr's `media` group (gid 169, `config.util-nixarr.globals`) for
# library write access rather than inventing a separate scheme, so files this
# instance creates are readable/writable by the main *arr apps and Jellyfin's
# NFS client the same way. Deliberately NOT VPN-confined, matching the main
# sonarr/radarr instances in media.nix — only the download clients go through
# the netns; the *arr apps themselves talk to indexers directly.
{ config, lib, pkgs, ... }:
{ instanceName # e.g. "sonarr-anime" — becomes the systemd unit + system user name
, appName # e.g. "sonarr" — the servarr env-var prefix and binary/package name
, package
, port
, dataDir
}:
let
  globals = config.util-nixarr.globals;
in
{
  users.users.${instanceName} = {
    isSystemUser = true;
    group = globals.libraryOwner.group;
  };

  systemd.tmpfiles.rules = [
    "d '${dataDir}' 0700 ${instanceName} root - -"
  ];

  systemd.services.${instanceName} = {
    description = "${appName} (${instanceName})";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      "${lib.toUpper appName}__SERVER__PORT" = toString port;
    };
    serviceConfig = {
      Type = "simple";
      User = instanceName;
      Group = globals.libraryOwner.group;
      ExecStart = "${lib.getExe package} -nobrowser -data=${dataDir}";
      Restart = "on-failure";
      # Same reasoning as nixarr's own sonarr/radarr modules: group-writable
      # output so Jellyfin (over NFS) and the other *arr apps can touch it.
      UMask = "0002";
    };
  };
}
