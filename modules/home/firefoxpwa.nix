{ config, pkgs, lib, pkgsApps, ... }:

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  # The default firefoxpwa profile, where the extension installs apps.
  userJs = "profiles/00000000000000000000000000/user.js";
  # Keep each app's own name and icon on its window, and the toolbar on the
  # system theme instead of the site's brand colour. Re-applied at every
  # launch (pegasus DECISIONS.md, "PWAs on PWAsForFirefox").
  prefs = ''
    user_pref("firefoxpwa.dynamicWindowTitle", false);
    user_pref("firefoxpwa.dynamicWindowIcon", false);
    user_pref("firefoxpwa.sitesSetThemeColor", false);
    user_pref("firefoxpwa.dynamicThemeColor", false);
  '';
in
{
  # ── PWAsForFirefox: native host for the extension, plus default prefs ──
  # Not Home Manager's programs.firefoxpwa: it owns config.json read-only,
  # which locks out installing from the extension. nixpkgs builds firefoxpwa
  # for Linux only, so on darwin it is a Homebrew formula
  # (modules/darwin/homebrew.nix) and this only links its manifest. Linux takes
  # the app lane: the release's 2.18.2 breaks against Firefox 158 (DECISIONS.md).
  config = lib.mkMerge [
    (lib.mkIf isLinux {
      home.packages = [ pkgsApps.firefoxpwa ];
      mozilla.firefoxNativeMessagingHosts = [ pkgsApps.firefoxpwa ];
      xdg.dataFile."firefoxpwa/${userJs}".text = prefs;
    })
    (lib.mkIf isDarwin {
      home.file."Library/Application Support/firefoxpwa/${userJs}".text = prefs;
      # User-level, so no sudo, unlike the formula's caveat.
      home.file."Library/Application Support/Mozilla/NativeMessagingHosts/firefoxpwa.json".source =
        config.lib.file.mkOutOfStoreSymlink "/opt/homebrew/opt/firefoxpwa/share/firefoxpwa.json";
    })
  ];
}
