{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — anime *arr instances.
# ─────────────────────────────────────────────────────────────────────────────
# A second Sonarr and second Radarr, separate from the main pair in media.nix,
# each pointed at its own `library/anime` subtree. Firm requirement, not a
# nice-to-have: anime's TVDB/absolute-episode-numbering handling is
# unreliable enough on the main Sonarr's quality/naming profiles that it
# wants its own instance with anime-tuned TRaSH profiles, same reasoning
# every other homelab arr-stack splits anime out for.
#
# nixarr is single-instance per service (source-verified against the
# `nixarr.nixosModules.default` module tree — `nixarr.sonarr`/`nixarr.radarr`
# and the plain nixpkgs `services.sonarr`/`services.radarr` underneath them
# both hardcode one systemd unit name), so this doesn't go through either —
# see lib/mk-arr-instance.nix for why and how.
#
# Considered and deferred: Shoko (AniDB-based identification/library
# organizer, `services.shoko` — packaged in this nixpkgs pin). Its payoff
# needs a Jellyfin plugin that isn't in nixpkgs and Jellyfin lives on
# memory-alpha, so it's a separate cross-host piece, not scoped here. These
# two instances solve the search-and-grab half of the anime problem on their
# own regardless of whether Shoko is ever added on top.

let
  mkArrInstance = import ./lib/mk-arr-instance.nix { inherit config lib pkgs; };

  animeLibraryDir = "${config.nixarr.mediaDir}/library/anime";
in
lib.mkMerge [
  (mkArrInstance {
    instanceName = "sonarr-anime";
    appName = "sonarr";
    package = pkgs.sonarr;
    port = 8990; # main Sonarr (media.nix) is 8989
    dataDir = "${config.nixarr.stateDir}/sonarr-anime";
  })
  (mkArrInstance {
    instanceName = "radarr-anime";
    appName = "radarr";
    package = pkgs.radarr;
    port = 7879; # main Radarr (media.nix) is 7878
    dataDir = "${config.nixarr.stateDir}/radarr-anime";
  })
  {
    systemd.tmpfiles.rules = [
      "d '${animeLibraryDir}' 2775 ${config.util-nixarr.globals.libraryOwner.user} ${config.util-nixarr.globals.libraryOwner.group} - -"
    ];
  }
]
