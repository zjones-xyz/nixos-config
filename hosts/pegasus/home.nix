{ config, pkgs, lib, claudeDesktop, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  # Host-specific rebuild aliases (layered on top of the shared portable ones
  # from modules/home/common.nix's home.shellAliases).
  #
  # home.shellAliases, NOT programs.bash.shellAliases: the login shell is
  # bash, but modules/home/interactive-zsh.nix execs every interactive bash
  # session straight into zsh before it ever reaches a prompt (matches
  # Serenity's default shell) — so bash-specific aliases never actually took
  # effect interactively. This was dead code since the very first authoring
  # session; nobody had tested an interactive login until now. The
  # shell-agnostic option applies to whichever shell is actually running.
  programs.bash.enable = true;
  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#pegasus";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#pegasus";
    npull = "git -C ~/nixos-config pull";
  };

  # ── Desktop apps ────────────────────────────────────────────────────────────
  # allowUnfree is already set globally in modules/nixos/common.nix, which
  # pegasus imports — vscode/google-chrome/vivaldi/1Password/discord/spotify/
  # ticktick/obsidian/bambu-studio are all unfree and need it; firefox/
  # ferdium/openscad/orca-slicer/streamdeck-ui are free/open.
  #
  # Brain.fm was left out — no nixpkgs package, no native Linux client
  # anywhere (subscription web app only); usable via firefox/chrome.
  home.packages = with pkgs; [
    sl # for the inevitable `sl` typo
    vscode
    google-chrome
    firefox
    vivaldi
    _1password-gui
    _1password-cli
    claude-code
    discord
    ferdium
    bambu-studio
    orca-slicer
    openscad
    obsidian
    spotify
    ticktick
    prusa-slicer
    jellyfin-desktop
    vlc

    # itch.io's official client — handles login/library/downloads/updates.
    # lutris has no native itch.io integration (no account sync), so this is
    # the actual client, not a duplicate of lutris's job.
    itch

    # Qt6 build (not plain libreoffice) for native Plasma 6 theming/integration
    # rather than pulling in GTK.
    libreoffice-qt6

    # Elgato Stream Deck control — needs the udev rule in
    # hosts/pegasus/configuration.nix for non-root USB access.
    streamdeck-ui

    # Streaming/capture — added alongside streamdeck-ui, which is otherwise a
    # control surface with nothing to control.
    obs-studio

    # GPU monitoring — htop-equivalent for the 4070, useful for confirming
    # ollama.nix's gaming-drain oneshot is actually freeing VRAM/compute.
    nvtopPackages.nvidia

    # Archive handling — wasn't anywhere in the package set (system or home).
    unzip
    p7zip

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

    # GPU-accelerated terminal emulators.
    ghostty
    kitty

    # ── Found on Serenity's /Applications, not yet replicated (2026-07-12) ────
    calibre # ebook library management
    makemkv # disc ripping, pairs with the jellyfin/vlc media stack
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

    # Alfred-style launchers (Alfred replacement research, 2026-07-12) — both
    # installed to compare hands-on. See DECISIONS.md for the writeup: Albert
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
  ];

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
    # desktop entry below (see xdg.desktopEntries.vicinae-toggle for why:
    # unreliable auto-application, confirmed hands-on 2026-07-13 — it also
    # has the side effect of resetting *other* services' shortcuts, like
    # krunner above, back to their compiled-in defaults whenever ksycoca
    # gets rebuilt). Writing kglobalshortcutsrc explicitly is the one
    # mechanism proven reliable throughout this whole saga.
    shortcuts."services/vicinae-toggle.desktop" = {
      _launch = "Alt+Space";
    };
  };

  # Vicinae has no built-in global-shortcut support at all (confirmed via
  # its own docs/FAQ) — by design, you're expected to bind the DE's own
  # shortcut mechanism to its CLI toggle.
  #
  # NOT plasma-manager's programs.plasma.hotkeys.commands — confirmed real,
  # reproduced hands-on (2026-07-13): it synthesizes a hidden multi-action
  # desktop entry, and KGlobalAccel doesn't actually invoke the specific
  # named action tied to the shortcut — it launches the entry's main (empty)
  # Exec instead, producing exactly the "app flashes briefly in the
  # taskbar, keybind doesn't work" symptom from the open upstream issue
  # nix-community/plasma-manager#571. Confirmed via a clean A/B test:
  # binding the same command through System Settings' native "Add Custom
  # Shortcut" flow (Plasma 6.1+) worked with zero glitching.
  #
  # This is a plain, standalone, single-Exec desktop entry — same mechanism
  # real KDE apps use for their own default shortcuts — but the shortcut
  # itself is bound explicitly above via programs.plasma.shortcuts, not
  # X-KDE-Shortcuts here (see that comment for why).
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

  home.stateVersion = "26.05";
}
