{ config, pkgs, lib, dr460nized-src, window-title-applet-src, ... }:

let
  # Sources are pinned flake inputs (see flake.nix), passed in via pegasus's
  # specialArgs. Garuda's actual current Dr460nized package (v4.7.1 as of the
  # pin) — native Plasma 6 panels, not the old unmaintained Latte Dock setup.
  dr460nizedSrc = dr460nized-src;

  # org.kde.windowtitle — pure QML, no compiled backend, unlike
  # org.kde.windowbuttons and luisbocanegra.panel.colorizer (both deferred,
  # see hosts/pegasus/DECISIONS.md — this is the "fast subset" build).
  windowTitleAppletSrc = window-title-applet-src;

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
    cp ${./dragonized/lookandfeel-defaults} \
      $out/share/plasma/look-and-feel/Dr460nized/contents/defaults
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
    chmod -R u+w $out/share/plasma/plasmoids/org.kde.windowtitle
    # Strip a dead QML import (org.kde.plasma.private.appmenu — the applet
    # never uses it, and nixpkgs' plasma-workspace doesn't build that plugin,
    # so leaving it hard-fails the applet at load).
    sed -i '/org\.kde\.plasma\.private\.appmenu/d' \
      $out/share/plasma/plasmoids/org.kde.windowtitle/contents/ui/main.qml
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

    # kglobalshortcutsrc is exempted from the wipe below — declarative
    # seeding gets fought by KDE's own default-reassignment logic at session
    # startup (DECISIONS.md). Shortcuts are configured once via System
    # Settings and preserved here instead; absent on first-ever login means
    # KDE defaults apply until configured.
    SHORTCUTS_BACKUP="$(mktemp)"
    if [ -f "$XDG_CONFIG_HOME/kglobalshortcutsrc" ]; then
      cp "$XDG_CONFIG_HOME/kglobalshortcutsrc" "$SHORTCUTS_BACKUP"
    fi

    rm -rf "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

    # NOT plasma-apply-lookandfeel here — it needs an already-running
    # compositor to talk to, and none exists at this point in the script.
    # Pre-seeding kdeglobals is KDE's own mechanism for auto-applying a
    # theme on a fresh profile's first login; Plasma reads it as it starts.
    cat > "$XDG_CONFIG_HOME/kdeglobals" <<'KDEGLOBALS'
    [KDE]
    LookAndFeelPackage=Dr460nized
    KDEGLOBALS

    # vicinae-toggle is a plain single-Exec desktop entry, NOT
    # plasma-manager's hotkeys.commands — that synthesizes a multi-action
    # entry KGlobalAccel doesn't resolve (nix-community/plasma-manager#571;
    # see home.nix).
    mkdir -p "$XDG_DATA_HOME/applications"
    cat > "$XDG_DATA_HOME/applications/vicinae-toggle.desktop" <<'VICINAETOGGLE'
    [Desktop Entry]
    Type=Application
    Name=Vicinae Toggle
    Exec=${pkgs.vicinae}/bin/vicinae toggle
    NoDisplay=true
    VICINAETOGGLE

    ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6

    # Restore kglobalshortcutsrc last, right before the session actually
    # starts — see the SHORTCUTS_BACKUP comment above for why this is
    # preserved rather than declaratively seeded.
    if [ -s "$SHORTCUTS_BACKUP" ]; then
      cp "$SHORTCUTS_BACKUP" "$XDG_CONFIG_HOME/kglobalshortcutsrc"
    fi
    rm -f "$SHORTCUTS_BACKUP"

    # Wait for the Wayland socket before starting the vicinae server: it's a
    # Qt/Wayland client, so starting it before the compositor crashes it —
    # and an XDG autostart entry doesn't fire in this session either, so
    # don't retry either dead end (details in git history).
    (
      for i in $(seq 1 150); do
        compgen -G "''${XDG_RUNTIME_DIR}/wayland-*" > /dev/null && break
        sleep 0.2
      done
      exec ${pkgs.vicinae}/bin/vicinae server --replace
    ) &
    disown

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
  # BeautyLine and Fira Sans are PKGBUILD dependencies the fast-subset
  # scoping skipped: without them Kickoff's category icons render as dots
  # and the panel clock (autoFontAndSize = false) renders tiny on a
  # mismatched fallback font.
  environment.systemPackages = [
    dr460nizedTheme
    windowTitleApplet
    pkgs.kdePackages.qtstyleplugin-kvantum
    pkgs.beauty-line-icon-theme

    # Window decoration — see lookandfeel-defaults for why this replaces the
    # unpackageable Sweet-Dark aurorae theme upstream actually wants.
    pkgs.klassy
  ];

  fonts.packages = [ pkgs.fira-sans ];

  services.displayManager.sessionPackages = [ dragonizedSessionFile ];
}
