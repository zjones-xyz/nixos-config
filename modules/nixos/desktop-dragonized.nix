{ config, pkgs, lib, ... }:

let
  # Garuda's actual current Dr460nized package (v4.7.1 as of this pin) —
  # native Plasma 6 panels, not the old unmaintained Latte Dock setup. Pinned
  # to the exact commit the PKGBUILD (garuda-linux/pkgbuilds) built from.
  #
  # builtins.fetchGit + narHash rather than pkgs.fetchgit: fully pure/pinned
  # either way (no --impure needed, verified), but this authoring session's
  # proxy only reliably reaches github.com from the evaluator process
  # (builtins.fetchGit), not from inside pkgs.fetchgit's build sandbox,
  # which hit a TLS chain error there — see hosts/pegasus/DECISIONS.md.
  dr460nizedSrc = builtins.fetchGit {
    url = "https://gitlab.com/garuda-linux/themes-and-settings/settings/garuda-dr460nized.git";
    rev = "35eb3abbc534f4046257c43ad9e05a9c010235cf";
    narHash = "sha256-4kRU4h3WRuVjixhK5B/x19bIxtHc9vcfbv5QPjFMBfc=";
    shallow = true;
  };

  # org.kde.windowtitle — pure QML, no compiled backend, unlike
  # org.kde.windowbuttons and luisbocanegra.panel.colorizer (both deferred,
  # see hosts/pegasus/DECISIONS.md — this is the "fast subset" build).
  windowTitleAppletSrc = builtins.fetchGit {
    url = "https://github.com/dhruv8sh/plasma6-window-title-applet.git";
    rev = "a6eaf5086a473919ed2fffc5d3b8d98237c2dd41";
    narHash = "sha256-pFXVySorHq5EpgsBz01vZQ0sLAy2UrF4VADMjyz2YLs=";
    shallow = true;
  };

  # Static theme data (Look-and-Feel package, panel/dock layout templates,
  # both Plasma styles, Kvantum theme, both SDDM themes, the Malefor
  # wallpaper) — everything here is just files, no compilation. The three
  # layout.js files are swapped for patched copies (modules/nixos/dragonized/)
  # that drop references to the two deferred plasmoids and the Arch-only
  # pinned taskbar launchers, and point the wallpaper at the real Malefor
  # image via the stock plugin instead of the also-deferred a2n.blur.
  dr460nizedTheme = pkgs.runCommand "dr460nized-theme-data" { } ''
    mkdir -p $out/share
    cp -r ${dr460nizedSrc}/usr/share/plasma $out/share/plasma
    chmod -R u+w $out/share/plasma

    cp ${./dragonized/lookandfeel-layout.js} \
      $out/share/plasma/look-and-feel/Dr460nized/contents/layouts/org.kde.plasma.desktop-layout.js
    cp ${./dragonized/panel-layout.js} \
      $out/share/plasma/layout-templates/org.garuda.desktop.defaultPanel/contents/layout.js
    cp ${./dragonized/dock-layout.js} \
      $out/share/plasma/layout-templates/org.garuda.desktop.defaultDock/contents/layout.js

    mkdir -p $out/share/Kvantum
    cp -r ${dr460nizedSrc}/usr/share/Kvantum/Dr460nized $out/share/Kvantum/Dr460nized

    mkdir -p $out/share/sddm/themes
    cp -r ${dr460nizedSrc}/usr/share/sddm/themes/Dr460nized $out/share/sddm/themes/Dr460nized
    cp -r ${dr460nizedSrc}/usr/share/sddm/themes/Dr460nized-Sugar-Candy $out/share/sddm/themes/Dr460nized-Sugar-Candy

    mkdir -p $out/share/wallpapers
    cp -r ${dr460nizedSrc}/usr/share/wallpapers/Malefor $out/share/wallpapers/Malefor
  '';

  windowTitleApplet = pkgs.runCommand "plasma6-window-title-applet" { } ''
    mkdir -p $out/share/plasma/plasmoids/org.kde.windowtitle
    cp -r ${windowTitleAppletSrc}/contents $out/share/plasma/plasmoids/org.kde.windowtitle/contents
    cp ${windowTitleAppletSrc}/metadata.json $out/share/plasma/plasmoids/org.kde.windowtitle/metadata.json
  '';

  dragonizedStart = pkgs.writeShellScriptBin "startplasma-dragonized" ''
    set -e
    # Isolated profile dirs — never touches the daily-driver Plasma config
    # under the normal $HOME/.config. Wiped and recreated on every login so
    # this session always boots from a known, reproducible state rather than
    # accumulating drift.
    export XDG_CONFIG_HOME="$HOME/.config-dragonized"
    export XDG_DATA_HOME="$HOME/.local/share-dragonized"
    export XDG_CACHE_HOME="$HOME/.cache-dragonized"
    rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

    # NOT plasma-apply-lookandfeel here — it's a Qt tool that needs an
    # already-running Wayland compositor to talk to (it *applies* a change
    # to a live session), and at this point in the script there's no
    # compositor running yet. Confirmed the hard way (2026-07-11): running
    # it standalone over SSH with no display aborts identically to what
    # happened at the real login attempt — same root cause, just easier to
    # see outside the greeter. Pre-seeding kdeglobals instead is the
    # standard mechanism KDE itself uses to auto-apply a distro's default
    # theme on a fresh profile's first-ever login — no live session needed,
    # Plasma reads this as it starts up.
    cat > "$XDG_CONFIG_HOME/kdeglobals" <<'KDEGLOBALS'
    [KDE]
    LookAndFeelPackage=Dr460nized
    KDEGLOBALS

    exec ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland
  '';

  dragonizedSessionFile = (pkgs.writeTextDir "share/wayland-sessions/plasma-dragonized.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Plasma (Dragonized)
    Comment=Garuda Dr460nized on Plasma 6/Wayland, isolated profile — fast-subset build, see hosts/pegasus/DECISIONS.md
    Exec=${dragonizedStart}/bin/startplasma-dragonized
    DesktopNames=KDE
  '').overrideAttrs (old: {
    passthru = (old.passthru or { }) // { providedSessions = [ "plasma-dragonized" ]; };
  });
in
{
  # ── Dragonized, as a third selectable SDDM session ──────────────────────────
  # Fast-subset build (2026-07-11) of Garuda's Dr460nized theme, per
  # hosts/pegasus/DECISIONS.md. Deliberately a separate, isolated session
  # (own XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_CACHE_HOME) rather than changing
  # programs.plasma.workspace.lookAndFeel on the daily-driver Plasma
  # session — this can't affect that session no matter what, since they
  # don't share any config state.
  #
  # Confirmed working end-to-end 2026-07-11: X-Plasma-Shell: "plasma-garuda"
  # in Garuda's layout templates does NOT block loadTemplate() — panels,
  # dock, wallpaper, and Kickoff all loaded correctly on first real login,
  # after fixing the plasma-apply-lookandfeel crash (see git history). Two
  # cosmetic gaps found on that login, both from PKGBUILD dependencies the
  # fast-subset scoping skipped (theme data + one plasmoid only): Kickoff's
  # category icons need the BeautyLine icon theme (font/icon-theme-dependent
  # names, not bundled with any app), and the panel clock (configured with
  # autoFontAndSize = false) needs Fira Sans specifically or it renders
  # tiny using a mismatched fallback. Both added below.
  environment.systemPackages = [
    dr460nizedTheme
    windowTitleApplet
    pkgs.kdePackages.qtstyleplugin-kvantum
    pkgs.beauty-line-icon-theme
  ];

  fonts.packages = [ pkgs.fira-sans ];

  services.displayManager.sessionPackages = [ dragonizedSessionFile ];
}
