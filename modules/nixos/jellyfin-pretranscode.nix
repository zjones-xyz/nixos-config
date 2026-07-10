{ config, pkgs, lib, ... }:

let
  cfg = config.services.jellyfin;

  pretranscodePlugin = pkgs.fetchurl {
    url = "https://github.com/SalMutt/jellyfin-pretranscode/releases/download/v1.0.0/Jellyfin.Plugin.PreTranscode.dll";
    sha256 = "sha256-0GrjZe/O+3Jw6w28G+3djj7hiIIVa6N5uzX7WCTAZO8=";
  };
in
{
  # Jellyfin Pre-Transcode plugin (community, unofficial):
  # https://github.com/SalMutt/jellyfin-pretranscode
  #
  # Pre-transcodes the next episode in the background once the current one
  # hits the credits, so "play next episode automatically" starts instantly
  # instead of buffering. Requires Jellyfin 10.11+ — this fleet's nixpkgs pin
  # (nixos-26.05) builds Jellyfin 10.11.11.
  #
  # No nixpkgs infrastructure exists for declarative Jellyfin plugin
  # management, and this plugin ships no Nix packaging of its own — so it's
  # fetched by URL+hash and symlinked into place, matching the fetch-and-place
  # idiom already sketched (commented out) in jellyfin.nix for the NFS mount.

  systemd.tmpfiles.rules = [
    "d ${cfg.dataDir}/plugins/PreTranscode 0750 ${cfg.user} ${cfg.group} -"
    "L+ ${cfg.dataDir}/plugins/PreTranscode/Jellyfin.Plugin.PreTranscode.dll - - - - ${pretranscodePlugin}"
  ];
}
