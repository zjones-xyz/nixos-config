{ config, pkgs, lib, claudeDesktop, orcaSlicerNewer, bambuStudioNewer, ... }:

{
  imports = [
    ../../modules/home/common.nix
    ./niri-settings.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.sessionVariables = {
    SOPS_AGE_KEY_FILE = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  };

  # Host-specific aliases, layered on modules/home/common.nix's shared set.
  # home.shellAliases, NOT programs.bash.shellAliases — interactive-zsh.nix
  # execs every interactive bash into zsh, so bash-specific aliases never fire.
  programs.bash.enable = true;
  #
  # ⚠ The ipmi-tower-*/unlock-* recovery aliases are deliberately duplicated
  # with hosts/serenity/home.nix (different repo paths anyway), so neither
  # admin box being down blocks recovering the others — hosts/galactica/
  # PLATFORM.md §2 has the rationale and the raw BMC address fallback.
  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#pegasus";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#pegasus";
    npull = "~/nixos-config/scripts/npull.sh";
    ipmi-tower = ''~/nixos-config/scripts/ipmi-remote.sh run towerbmc.internal "op://System Keys/tower ipmi/password"'';
    ipmi-tower-open-tty = ''~/nixos-config/scripts/ipmi-remote.sh console towerbmc.internal "op://System Keys/tower ipmi/password"'';
    ipmi-tower-set-bios-next-boot = ''~/nixos-config/scripts/ipmi-remote.sh bios-next-boot towerbmc.internal "op://System Keys/tower ipmi/password"'';
    # "tower", not "galactica" — these aliases are about the physical box, and
    # the fleet name / service name are deliberately decoupled (galactica's
    # DECISIONS.md §2).
    unlock-tower = ''~/nixos-config/scripts/luks-unlock-remote.sh tower.internal "op://System Keys/tower luks/password"'';
    unlock-memory-alpha = ''~/nixos-config/scripts/luks-unlock-remote.sh memory-alpha.internal "op://System Keys/memory-alpha luks/password"'';
    dms-settings-snapshot = "~/nixos-config/scripts/dms-settings.sh snapshot";
    dms-settings-restore = "~/nixos-config/scripts/dms-settings.sh restore";
    dms-settings-diff = "~/nixos-config/scripts/dms-settings.sh diff";
  };

  # ── Desktop apps ────────────────────────────────────────────────────────────
  # allowUnfree is already set globally in modules/nixos/common.nix, which
  # pegasus imports — vscode/google-chrome/vivaldi/1Password/discord/spotify/
  # ticktick/obsidian/bambu-studio are all unfree and need it; firefox/
  # ferdium/signal-desktop/openscad/orca-slicer/streamdeck-ui are free/open.
  #
  # Brain.fm was left out — no nixpkgs package, no native Linux client
  # anywhere (subscription web app only); usable via firefox/chrome.
  home.packages = with pkgs; [
    sl # for the inevitable `sl` typo
    vscode
    google-chrome
    firefox
    vivaldi
    claude-code

    discord
    ferdium
    signal-desktop
    slack
    openscad
    obsidian
    spotify
    ticktick
    prusa-slicer
    jellyfin-desktop
    vlc

    thunderbird
    protonmail-bridge-gui

    # file managers
    nemo
    nautilus
    thunar

    # itch.io's official client — handles login/library/downloads/updates.
    # lutris has no native itch.io integration (no account sync), so this is
    # the actual client, not a duplicate of lutris's job.
    itch

    # Qt6 build (not plain libreoffice) for native Plasma 6 theming/integration
    # rather than pulling in GTK.
    libreoffice-qt6
    gnumeric

    # Elgato Stream Deck control — needs the udev rule in
    # hosts/pegasus/configuration.nix for non-root USB access.
    streamdeck-ui

    # Streaming/capture — added alongside streamdeck-ui, which is otherwise a
    # control surface with nothing to control.
    obs-studio

    # GPU monitoring — htop-equivalent for the 4070, useful for confirming
    # ollama.nix's gaming-drain oneshot is actually freeing VRAM/compute.
    nvtopPackages.nvidia

    # Monitor control over DDC/CI (brightness, input source, etc. from the
    # CLI, no on-screen-display fumbling). Needs the hardware.i2c.enable
    # wiring in hosts/pegasus/configuration.nix and the NVIDIA software-I2C
    # registry fix in modules/nixos/nvidia.nix — see those for why.
    ddcutil

    # IPMI/BMC out-of-band management client — ipmi-sensors, ipmipower,
    # ipmiconsole (SOL), bmc-info. Same toolset as on serenity. Pegasus is a
    # consumer desktop board with no BMC, so this is the LAN client for
    # reaching other machines' BMCs, not local hardware monitoring; the
    # local-access tools would additionally need /dev/ipmi0, which means the
    # ipmi kernel modules and root (or a udev rule) — deliberately not wired
    # up here since there's nothing on this box to talk to.
    #
    # On both this machine and serenity deliberately, so neither one being
    # down blocks recovering the other — which is the case that matters, since
    # the thing being recovered is Tower's LUKS prompt over serial-over-LAN.
    # See hosts/galactica/PLATFORM.md §2 for the invocations and the
    # FreeIPMI-not-ipmitool rationale.
    freeipmi

    expect

    # Desktop GUI for Borg.
    vorta

    # Archive handling — wasn't anywhere in the package set (system or home).
    unzip
    p7zip

    # RAR extraction — NOT covered by p7zip above (nixpkgs strips its RAR
    # codec, so `7z x foo.rar` fails confusingly) nor by bsdtar (no RAR5).
    # Also what makes RAR appear in Ark, whose cli plugin shells out to the
    # `unrar` binary on $PATH. Unfree, extract-only by license.
    unrar

    # Winetricks operations scoped to a specific Proton prefix — common
    # companion to protonup-qt/lutris for troubleshooting individual games.
    protontricks

    # Epic/GOG/Amazon Prime Gaming — same rationale as itch above: lutris has
    # no native store integration for these either.
    heroic

    # Parametric GUI CAD, pairs with openscad (script-only) in the 3D-printing
    # pipeline.
    freecad

    # General-Wine-prefix tooling (not Steam/Proton — protontricks above
    # covers that). Needed for the Lutris-managed Fusion 360 install: yad
    # resolves some known installer issues, winetricks handles dependency
    # setup outside a Proton prefix.
    winetricks
    yad

    # GPU-accelerated terminal emulators. kitty itself is declared via
    # programs.kitty below now (not here) — see that block for why.
    ghostty

    # Doxie Q2 (DX320) scan management — the scanner itself needs no driver
    # (mounts as plain USB mass storage; Wi-Fi direct-to-cloud setup is the
    # one piece still gated behind the proprietary Mac/Windows app). naps2
    # covers the rest of what Doxie's own desktop app would otherwise do:
    # organizing/renaming/combining scans into PDFs.
    naps2

    # PDF reading — Okular (full-featured: annotation, forms, signing) already
    # rides in for free via services.desktopManager.plasma6.enable in
    # modules/nixos/desktop-plasma.nix (confirmed against nixpkgs' plasma6.nix
    # module: it's in plasma6's default optionalPackages set, and this repo
    # never sets environment.plasma6.excludePackages). Zathura is the
    # deliberate lightweight/keyboard-driven alternative for quick reads under
    # niri — not a duplicate, a different tool for a different moment.
    zathura

    # wl-paste, for the swappy screenshot-annotation bind below — niri's own
    # wiki examples use wl-clipboard the same way (piping wl-paste into
    # another program). See programs.swappy below and the Mod+Shift+S bind in
    # niri-settings.nix.
    wl-clipboard

    # ── Replicated from Serenity's /Applications ──────────────────────────────
    calibre # ebook library management
    # makemkv parked: upstream's download origin is unreachable, which fails
    # the source fetch and blocks nrs. Re-add once it fetches again.
    filebot # media file renaming/organizing, same media stack
    arduino-ide
    proton-vpn # renamed from protonvpn-gui upstream
    protonmail-desktop
    dropbox
    zoom-us # NOT `zoom` — that's an unrelated Z-code/interactive-fiction player
    prismlauncher # Minecraft — better-maintained than the bare official launcher on Linux
    zeal # offline API docs, the real Linux equivalent of Dash
    speedtest-cli
    jetbrains-toolbox
    teams-for-linux # Microsoft dropped their own Linux client; this is the maintained community one
    android-file-transfer
    affine

    # Local LLM inference GUI — pairs with the RTX 4070 and the existing
    # ollama.nix setup for a GUI-driven alternative to the CLI.
    lmstudio

    # ykman CLI — Yubico dropped the GUI (yubikey-manager-qt) upstream in
    # favor of this; pairs with the PAM/udev setup in modules/nixos/yubikey.nix.
    yubikey-manager

    # Logitech webcam control. cameractrls has a genuine Logitech extension
    # (BRIO field-of-view, LED mode/frequency, relative pan/tilt, PTZ
    # presets) — the real equivalent of Logi Tune/Logitech Capture's settings
    # panel, not just a generic V4L2 GUI. v4l-utils underneath it for
    # v4l2-ctl (scripting/one-off tweaks). webcamoid for background-blur/
    # virtual-background effects on video calls outside OBS.
    cameractrls-gtk4
    v4l-utils
    webcamoid

    # Alfred-style launchers — both installed to compare hands-on. See
    # DECISIONS.md for the writeup: Albert
    # relicensed to proprietary freeware at v0.21.0 (disputed legitimacy,
    # hence nixpkgs' license = unfree), Vicinae is GPL-3.0 and runs actual
    # Raycast extensions natively.
    albert
    vicinae
  ] ++ [
    # Claude Desktop — not in nixpkgs (Anthropic's official Linux beta only
    # shipped 2026-06-30, too recent). claudeDesktop comes from the
    # claude-desktop-debian flake input via home-manager.extraSpecialArgs in
    # flake.nix — the FHS-wrapped variant, needed for MCP servers to work
    # (they shell out to npx/uvx/etc. expecting a standard FHS layout).
    claudeDesktop
    # 02.05.00.67, with the real upstream withNvidiaGLWorkaround applied —
    # fixes the blank Prepare/Preview build plate on this host's NVIDIA GPU.
    # From the separate nixpkgs-bambu-studio input (see flake.nix); this
    # flake's main nixpkgs pin predates both that version bump and the fix.
    bambuStudioNewer
    # 2.3.2 — this flake's main nixpkgs pin predates nixpkgs' 2.3.1 -> 2.3.2
    # bump, so this comes from the separate nixpkgs-orca-slicer input
    # instead (see flake.nix). Confirmed viewport already renders fine on
    # this host's NVIDIA setup at 2.3.1, so no GL workaround needed here
    # unlike bambuStudioNewer above.
    orcaSlicerNewer
  ];

  # ── kitty: launch zsh directly, not the login shell ─────────────────────────
  # Login shell stays bash (predictable non-interactive `ssh z@host cmd`
  # semantics — interactive-zsh.nix) and interactive bash execs into zsh
  # anyway; pointing kitty at zsh directly just skips that hop.
  programs.kitty = {
    enable = true;
    settings.shell = "${pkgs.zsh}/bin/zsh";
  };

  # ── Screenshot annotation (swappy) ──────────────────────────────────────────
  # niri's own Print/Ctrl+Print/Alt+Print binds (niri-settings.nix) already do
  # the actual *capturing* — niri implements screenshot capture itself at the
  # compositor level (confirmed against niri's own wiki, Configuration:-Key-
  # Bindings.md: "The screenshot is both stored to the clipboard and saved to
  # disk"), so no grim/slurp is needed here, unlike on sway/Hyprland. swappy
  # only adds a markup step on top: Mod+Shift+S (niri-settings.nix) pipes
  # whatever niri just put on the clipboard into swappy for annotation
  # (arrows/boxes/text/blur); swappy's own Ctrl+S then saves the edited copy
  # to save_dir below, separately from niri's own screenshot-path.
  programs.swappy = {
    enable = true;
    settings.Default = {
      save_dir = "$HOME/Pictures/Screenshots";
      save_filename_format = "swappy-%Y%m%d-%H%M%S.png";
    };
  };

  # ── Declarative Plasma 6 (plasma-manager) ───────────────────────────────────
  # plasma-manager's HM module is wired in via home-manager.sharedModules in
  # flake.nix. This is a minimal starting point — Plasma writes a lot of state,
  # so grow this incrementally (export current settings with `plasma-manager`'s
  # rc2nix). See hosts/pegasus/DECISIONS.md.
  programs.plasma = {
    enable = true;
    workspace.lookAndFeel = "org.kde.breezedark.desktop";

    # Freed up for Albert/Vicinae (2026-07-12) — both installed above.
    krunner.shortcuts = {
      launch = "none";
      runCommandOnClipboard = "none";
    };

    # Kickoff's "Activate Application Launcher" action — registered as a
    # plain KGlobalAccel shortcut on the plasmashell component (confirmed via
    # plasma-workspace's shellcorona.cpp: default binds both Meta and
    # Alt+F1), not a KWin-level "modifier-only" mechanism. Clearing this
    # frees the bare Meta key for Vicinae below.
    shortcuts."plasmashell" = {
      "activate application launcher" = "none";
    };

    # vicinae-toggle's binding, explicit — NOT via X-KDE-Shortcuts on the
    # desktop entry below: that auto-application is unreliable AND resets
    # other services' shortcuts whenever ksycoca rebuilds. Writing
    # kglobalshortcutsrc explicitly is the one mechanism proven reliable.
    shortcuts."services/vicinae-toggle.desktop" = {
      _launch = "Alt+Space";
    };
  };

  # Vicinae has no built-in global-shortcut support by design — the DE's own
  # shortcut mechanism binds its CLI toggle. A plain single-Exec desktop
  # entry, deliberately NOT plasma-manager's hotkeys.commands (broken:
  # nix-community/plasma-manager#571 — see DECISIONS.md); the shortcut is
  # bound explicitly above via programs.plasma.shortcuts.
  xdg.desktopEntries.vicinae-toggle = {
    name = "Vicinae Toggle";
    type = "Application";
    exec = "${pkgs.vicinae}/bin/vicinae toggle";
    noDisplay = true;
  };

  # ksycoca needs to know about the new/changed desktop entry above (and any
  # other desktop-entry-based shortcut) before KGlobalAccel can resolve it —
  # rebuild on every activation rather than requiring a full logout each
  # time this changes.
  home.activation.rebuildKSycoca = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6 $VERBOSE_ARG
  '';

  # ── DankMaterialShell settings: seed-only-if-missing ────────────────────────
  # DMS's own settings.json and plugin_settings.json are deliberately NOT
  # Home-Manager-managed (no home.file/xdg.configFile, in-store or
  # mkOutOfStoreSymlink alike) — DMS saves both via an atomic
  # write-temp-then-rename, which severs any symlink at that path on the
  # very first GUI change instead of writing through it. See
  # scripts/dms-settings.sh and DECISIONS.md for the full reasoning.
  #
  # This just seeds a fresh host — one with no live file yet — from the
  # repo's checkpoints (hosts/pegasus/dms-settings.json and
  # dms-plugin-settings.json, created by `dms-settings-snapshot`), so a
  # rebuild-from-scratch starts from the last-known-good config instead of
  # DMS's own defaults. Each check is independent and never touches an
  # existing live file, so it can't clobber an in-progress GUI experiment —
  # that traffic only ever flows explicitly, via dms-settings-snapshot/
  # -restore/-diff above.
  home.activation.seedDmsSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    DMS_DIR="$HOME/.config/DankMaterialShell"
    # session.json lives under XDG_STATE_HOME, not XDG_CONFIG_HOME — see
    # scripts/dms-settings.sh for what it holds and why it is checkpointed.
    DMS_STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/DankMaterialShell"
    CHECKPOINTS="$HOME/nixos-config/hosts/pegasus"

    if [ ! -e "$DMS_DIR/settings.json" ] && [ -e "$CHECKPOINTS/dms-settings.json" ]; then
      $DRY_RUN_CMD mkdir -p "$DMS_DIR"
      $DRY_RUN_CMD cp "$CHECKPOINTS/dms-settings.json" "$DMS_DIR/settings.json"
    fi

    if [ ! -e "$DMS_DIR/plugin_settings.json" ] && [ -e "$CHECKPOINTS/dms-plugin-settings.json" ]; then
      $DRY_RUN_CMD mkdir -p "$DMS_DIR"
      $DRY_RUN_CMD cp "$CHECKPOINTS/dms-plugin-settings.json" "$DMS_DIR/plugin_settings.json"
    fi

    if [ ! -e "$DMS_STATE_DIR/session.json" ] && [ -e "$CHECKPOINTS/dms-session.json" ]; then
      $DRY_RUN_CMD mkdir -p "$DMS_STATE_DIR"
      $DRY_RUN_CMD cp "$CHECKPOINTS/dms-session.json" "$DMS_STATE_DIR/session.json"
    fi
  '';

  home.stateVersion = "26.05";
}
