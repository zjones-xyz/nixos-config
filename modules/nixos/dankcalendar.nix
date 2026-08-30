{ config, pkgs, lib, ... }:

let
  # dankcalendar ("dcal") — standalone calendar app from the same "Dank"
  # suite as DankMaterialShell (modules/nixos/desktop-niri.nix). Native
  # Local/Google/Microsoft/CalDAV/iCloud sync with a background daemon +
  # tray icon; NOT a backend for DMS's own calendar widget (that's still
  # khal, via programs.dank-material-shell.enableCalendarEvents) — this is
  # a genuinely separate app, chosen 2026-08-11 over sticking with
  # khal+vdirsyncer alone. See hosts/pegasus/DECISIONS.md.
  #
  # No NixOS packaging exists upstream (no flake, no nixpkgs entry — only
  # Flatpak/AUR/from-source at time of writing), so this is packaged from
  # scratch here, following the exact same shape as DMS's own package
  # build in DankMaterialShell's flake.nix (buildGoModule + a QML tree
  # baked in, wrapped with the Qt/QML plugin paths dank-qml-common's
  # shared widgets need).
  #
  # Pinned to master HEAD at authoring time (2026-08-11) — no tagged
  # release exists yet to pin to instead.
  dankcalendarRev = "a57a879061cd482c416d5ece44cb529249c37b06";
  dankcalendarSrc = pkgs.fetchFromGitHub {
    owner = "AvengeMedia";
    repo = "dankcalendar";
    rev = dankcalendarRev;
    hash = "sha256-aQOU08ECTd0savQD80AIGG9sqQ41zWHcWZeuUzz39ts=";
  };

  # dank-qml-common is a git submodule of dankcalendar (.gitmodules pins it
  # to "master", not a fixed rev) — resolved to the exact commit the
  # submodule pointer records at dankcalendarRev above, fetched
  # separately since fetchFromGitHub doesn't pull submodules and the
  # build needs its content merged into the embedded QML tree (see
  # preBuild below).
  dankQmlCommonSrc = pkgs.fetchFromGitHub {
    owner = "AvengeMedia";
    repo = "dank-qml-common";
    rev = "b50afcf549f7e9c8f07c85b7f3fbba867701650d";
    hash = "sha256-/rCqHgC39mHvBDxb/dZLWCQ3W4ev94y3/1KtCRSPDp8=";
  };

  # Same Qt/QML plugin set DMS's own flake.nix wraps itself with
  # (DankMaterialShell/flake.nix's `qmlPkgs`) — dank-qml-common's widgets
  # are shared between the two apps, so dcal needs the same modules
  # available at runtime when it invokes quickshell as a subprocess.
  qmlPkgs = with pkgs.kdePackages; [
    kirigami.unwrapped
    sonnet
    qtmultimedia
    qtimageformats
    kimageformats
  ];
  mkQmlImportPath = qmlPkgs':
    lib.concatStringsSep ":" (map (o: "${o}/${pkgs.qt6.qtbase.qtQmlPrefix}") qmlPkgs');
  mkQtPluginPath = qmlPkgs':
    lib.concatStringsSep ":" (map (o: "${o}/${pkgs.qt6.qtbase.qtPluginPrefix}") qmlPkgs');

  dcal = (pkgs.buildGoModule.override { go = pkgs.go_1_26; }) {
    pname = "dcal";
    # No tagged release; a plain unstable-style version string avoids
    # relying on `git describe`/`date`, neither of which work inside the
    # sandboxed build the way core/Makefile's live version detection does.
    version = "0-unstable-2026-08-11-${builtins.substring 0 8 dankcalendarRev}";
    src = "${dankcalendarSrc}/core";
    vendorHash = "sha256-m0blu+mzoY4HyIBmyPV8lUirWT9oVL+PxXBupvTEM8c=";

    # Replicates core/Makefile's `sync-shell` target: bakes the quickshell
    # UI tree into internal/shellembed/dist (go:embed target for the
    # `withshell` build tag — see core/internal/shellembed/embed_withshell.go),
    # with the DankCommon submodule symlink resolved to dank-qml-common's
    # real content (go:embed rejects symlinks, same reason the Makefile
    # dereferences it via `tar -h`; `cp -r` after removing the symlink
    # achieves the same result).
    preBuild = ''
      mkdir -p internal/shellembed/dist
      cp -r --no-preserve=mode ${dankcalendarSrc}/quickshell/. internal/shellembed/dist/
      rm -rf internal/shellembed/dist/DankCommon
      cp -r --no-preserve=mode ${dankQmlCommonSrc}/DankCommon internal/shellembed/dist/DankCommon
      rm -f internal/shellembed/dist/.qmlls.ini
      rm -rf internal/shellembed/dist/scripts internal/shellembed/dist/.claude
      rm -f internal/shellembed/dist/translations/extract_translations.py
    '';

    tags = [ "withshell" ];
    subPackages = [ "cmd/dcal" ];
    env.CGO_ENABLED = 0;

    ldflags = [
      "-s"
      "-w"
      "-X main.Version=0.0.0-unstable-${builtins.substring 0 8 dankcalendarRev}"
      "-X main.Commit=${builtins.substring 0 8 dankcalendarRev}"
    ];

    nativeBuildInputs = [ pkgs.makeWrapper pkgs.installShellFiles ];

    postInstall = ''
      installShellCompletion --cmd dcal \
        --bash <($out/bin/dcal completion bash) \
        --fish <($out/bin/dcal completion fish) \
        --zsh <($out/bin/dcal completion zsh)

      install -Dm644 ${dankcalendarSrc}/assets/com.danklinux.dankcalendar.desktop \
        $out/share/applications/com.danklinux.dankcalendar.desktop
      install -Dm644 ${dankcalendarSrc}/assets/com.danklinux.dankcalendar.svg \
        $out/share/icons/hicolor/scalable/apps/com.danklinux.dankcalendar.svg

      # dcal execs quickshell as a subprocess to actually render the
      # embedded UI (unpacked read-only to $XDG_RUNTIME_DIR at runtime,
      # per dankcalendar's own README) — quickshell itself is already on
      # PATH system-wide via the DMS module, but wrap it explicitly too
      # rather than depend on that, since a systemd --user service's PATH
      # isn't guaranteed to match an interactive shell's.
      wrapProgram $out/bin/dcal \
        --prefix PATH : "${pkgs.quickshell}/bin" \
        --prefix "NIXPKGS_QT6_QML_IMPORT_PATH" ":" "${mkQmlImportPath qmlPkgs}" \
        --prefix "QT_PLUGIN_PATH" ":" "${mkQtPluginPath qmlPkgs}"
    '';

    meta = {
      description = "Standalone calendar app (Local/Google/Microsoft/CalDAV/iCloud) from the Dank Linux suite";
      homepage = "https://github.com/AvengeMedia/dankcalendar";
      license = lib.licenses.mit;
      mainProgram = "dcal";
      platforms = lib.platforms.linux;
    };
  };
in
{
  environment.systemPackages = [ dcal ];

  # Mirrors dankcalendar's own assets/systemd/dcal.service (ExecStart
  # swapped for our built package's path). `--hidden` starts the tray
  # daemon without popping the calendar window open on login.
  systemd.user.services.dcal = {
    description = "Dank Calendar";
    documentation = [ "https://github.com/AvengeMedia/dankcalendar" ];
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${dcal}/bin/dcal run --session --hidden";
      Restart = "on-failure";
      RestartSec = 2;
      Slice = "app.slice";
    };
  };
}
